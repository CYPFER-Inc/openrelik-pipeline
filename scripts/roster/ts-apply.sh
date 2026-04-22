#!/usr/bin/env bash
# =============================================================================
# ts-apply.sh — reconcile Timesketch user state with a local roster file.
#
# Roster format (one entry per line, # for comments):
#   email=role        # role ∈ {admin, investigator, reader}
#
# CYPFER → TS role mapping (TS's user model is binary-admin like OR):
#   admin                  → tsctl make-admin
#   investigator, reader   → tsctl revoke-admin
#
# Invariants after a successful run:
#   1. Every roster user exists in TS (pre-created with --password so OIDC
#      login on first visit updates the existing record rather than JIT-
#      creating a parallel one). LOCAL_AUTH_ALLOWED_USERS is patched to
#      ['admin'] elsewhere in install.sh, so OIDC users can't use the
#      random password for local login anyway.
#   2. Every roster user has the TS admin flag matching its role.
#   3. Every roster user is active (enable-user — recover from prior revoke).
#   4. @-shaped users NOT in the roster are admin-stripped + disabled
#      (soft revoke; DB record kept for audit). The local `admin` service
#      account has no @ and is left alone.
#   5. No restart needed — TS picks up changes live.
#
# Idempotent. Safe to run repeatedly.
#
# USAGE:
#   bash ts-apply.sh [<roster>] [upsert|delete] [<target-email>]
# =============================================================================
set -euo pipefail

ROSTER=""
ACTION="apply"
TARGET_EMAIL=""

while [ $# -gt 0 ]; do
    case "$1" in
        *)
            if   [ -z "$ROSTER" ];        then ROSTER="$1"
            elif [ "$ACTION" = "apply" ] && [ -n "$1" ]; then ACTION="$1"
            elif [ -z "$TARGET_EMAIL" ];  then TARGET_EMAIL="$1"
            fi
            shift ;;
    esac
done
ROSTER="${ROSTER:-/opt/openrelik-pipeline/rosters/ts.env}"

log() { printf '[ts-apply] %s\n' "$*" >&2; }
die() { printf '[ts-apply] ERROR: %s\n' "$*" >&2; exit 1; }

[ -r "$ROSTER" ] || die "roster not readable: $ROSTER"
docker ps --format '{{.Names}}' | grep -q '^timesketch-web$' \
    || die "timesketch-web container not running"

# ---------------------------------------------------------------------------
# 1. Parse roster → two arrays aligned by index.
# ---------------------------------------------------------------------------
declare -a EMAILS=() ROLES=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    email="${line%%=*}"
    role="${line#*=}"
    [ "$email" = "$line" ] && role="reader"
    email="$(echo "$email" | xargs)"
    role="$(echo "$role" | xargs)"

    case "$role" in
        admin|investigator|reader) ;;
        *) die "invalid role '$role' for $email (valid: admin, investigator, reader)" ;;
    esac
    EMAILS+=("$email")
    ROLES+=("$role")
done < "$ROSTER"
log "roster: ${#EMAILS[@]} entries"

# ---------------------------------------------------------------------------
# 2. Snapshot existing TS users. `list-users` prints "email" for regular
#    users and "email (admin)" for admins — split on first whitespace to
#    extract the username, then filter for '@' to isolate OIDC-shaped
#    accounts (leaves the local `admin` alone).
# ---------------------------------------------------------------------------
mapfile -t TS_USERS < <(
    docker exec timesketch-web tsctl list-users 2>/dev/null \
        | awk '{print $1}' | grep -E '@' | sort -u
)

ts_user_exists() {
    for u in "${TS_USERS[@]}"; do [ "$u" = "$1" ] && return 0; done
    return 1
}

roster_has() {
    for e in "${EMAILS[@]}"; do [ "$e" = "$1" ] && return 0; done
    return 1
}

# ---------------------------------------------------------------------------
# 3. Reconcile TS user records.
# ---------------------------------------------------------------------------
ts_exec() { docker exec timesketch-web tsctl "$@" >/dev/null 2>&1; }

for i in "${!EMAILS[@]}"; do
    email="${EMAILS[$i]}"
    role="${ROLES[$i]}"

    if ! ts_user_exists "$email"; then
        # Random password — OIDC users can't use local auth anyway. Avoid
        # calling this on existing users (it'd reset their password on every
        # apply).
        ts_exec create-user "$email" --password "$(openssl rand -base64 24)" \
            || die "create-user failed: $email"
        log "  $email: created"
    fi

    # Ensure active (undo prior disable-user if the user is back on the roster)
    ts_exec enable-user "$email" || true

    if [ "$role" = "admin" ]; then
        ts_exec make-admin "$email" || die "make-admin failed: $email"
    else
        ts_exec revoke-admin "$email" || die "revoke-admin failed: $email"
    fi
    log "  $email: role=$role applied"
done

# ---------------------------------------------------------------------------
# 3b. Grant every roster user access to every sketch.
#
# TS sketches (and all the saved searches / tags / aggregations attached to
# them) are strictly ACL-scoped: a user only sees a sketch in "My Sketches"
# if they have an entry in sketch_accesscontrolentry. Being a TS admin does
# NOT surface other users' sketches in the default view — they appear only
# under "Shared with me" if an ACL entry exists.
#
# configure.py creates the default "CYPFER Case-{id}" sketch as the admin
# service account. Without this step, every SSO analyst signs in to an
# empty dashboard even though the sketch is sitting there with 23 saved
# searches, 36 tags, and 8 aggregations already configured.
#
# `tsctl grant-user USERNAME --sketch_id N` is idempotent (no duplicate
# sketch_accesscontrolentry rows on re-run) and grants read + write + delete.
# No matching `tsctl revoke-user` exists, so on soft-revoke we rely on
# disable-user (step 4) to block login — the stale ACL rows are harmless
# while the user is disabled.
# ---------------------------------------------------------------------------
mapfile -t SKETCH_IDS < <(
    docker exec postgres psql -U timesketch -d timesketch -At -c \
        "SELECT id FROM sketch ORDER BY id;" 2>/dev/null
)

if [ "${#SKETCH_IDS[@]}" -eq 0 ]; then
    log "  no sketches yet — skipping ACL grants"
else
    for i in "${!EMAILS[@]}"; do
        email="${EMAILS[$i]}"
        for sid in "${SKETCH_IDS[@]}"; do
            # grant-user can't revoke admin flags or affect login — safe to
            # run without a role gate. Swallow failures (sketch deleted mid-
            # run, user vanished) so one bad row doesn't abort the loop.
            ts_exec grant-user "$email" --sketch_id "$sid" || true
        done
        log "  $email: granted access to ${#SKETCH_IDS[@]} sketch(es)"
    done
fi

# ---------------------------------------------------------------------------
# 4. Soft-revoke any @-shaped TS user whose email isn't in the roster.
#    Admin flag cleared + disable-user; DB record stays.
#
#    Gated on ACTION != "upsert" so that a serial `vote grant` sequence
#    doesn't disable existing users during the partial-roster states
#    between calls. install.sh's install-time run leaves ACTION unset
#    (default "apply") and still sweeps; `vote revoke` passes "delete"
#    and still sweeps.
# ---------------------------------------------------------------------------
if [ "$ACTION" != "upsert" ]; then
    for u in "${TS_USERS[@]}"; do
        if ! roster_has "$u"; then
            ts_exec revoke-admin "$u" || true
            ts_exec disable-user "$u" || true
            log "  $u: not in roster — disabled (soft revoke)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 5. Explicit revoke target — defensive; step 4 usually already caught it.
# ---------------------------------------------------------------------------
if [ "$ACTION" = "delete" ] && [ -n "$TARGET_EMAIL" ]; then
    if ts_user_exists "$TARGET_EMAIL"; then
        ts_exec revoke-admin "$TARGET_EMAIL" || true
        ts_exec disable-user "$TARGET_EMAIL" || true
        log "  $TARGET_EMAIL: explicit revoke applied"
    fi
fi

log "done."

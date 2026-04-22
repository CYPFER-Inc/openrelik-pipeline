#!/usr/bin/env bash
# =============================================================================
# or-apply.sh — reconcile OpenRelik user state with a local roster file.
#
# Roster format (one entry per line, # for comments):
#   email=role        # role ∈ {admin, investigator, reader}
#
# CYPFER → OR role mapping:
#   admin                  → OR admin flag ON
#   investigator, reader   → OR admin flag OFF
#
# Invariants after a successful run:
#   1. settings.toml [auth.oidc].allowlist contains exactly the roster emails.
#   2. Every roster user exists in OR (created with --nopassword --authmethod oidc).
#   3. Every roster user has the admin flag matching its role.
#   4. Users NOT in the roster are demoted (admin flag OFF) and removed from
#      the allowlist. DB records are kept for audit (soft revoke).
#
# Idempotent. Safe to run repeatedly.
#
# USAGE:
#   bash or-apply.sh [<roster-file>] [apply|upsert|delete] [<target-email>]
#
#   action:
#     apply   (default, for install-time full reconcile) — reconciles state
#             against the roster AND sweeps: users in OR but not in the roster
#             are admin-stripped + removed from the allowlist (soft revoke).
#     upsert  (used by `vote grant`) — applies the roster but DOES NOT sweep.
#             Prevents a serial `vote grant` sequence from soft-revoking
#             existing users during the partial-roster states between calls.
#     delete  (used by `vote revoke`) — same as apply; sweep runs.
# =============================================================================
set -euo pipefail

ROSTER="${1:-/opt/openrelik-pipeline/rosters/or.env}"
ACTION="${2:-apply}"
TARGET_EMAIL="${3:-}"
OR_SETTINGS="/opt/openrelik/config/settings.toml"
OR_COMPOSE_DIR="/opt/openrelik"

log() { printf '[or-apply] %s\n' "$*" >&2; }
die() { printf '[or-apply] ERROR: %s\n' "$*" >&2; exit 1; }

[ -r "$ROSTER" ] || die "roster not readable: $ROSTER"
[ -f "$OR_SETTINGS" ] || die "settings.toml missing: $OR_SETTINGS"
docker ps --format '{{.Names}}' | grep -q '^openrelik-server$' \
    || die "openrelik-server container not running"

# ---------------------------------------------------------------------------
# 1. Parse roster → two arrays: EMAILS[], ROLES[] (aligned by index)
# ---------------------------------------------------------------------------
declare -a EMAILS=() ROLES=()
while IFS= read -r line; do
    # strip inline comments + whitespace
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    email="${line%%=*}"
    role="${line#*=}"
    # bare email (no =) defaults to reader
    if [ "$email" = "$line" ]; then
        role="reader"
    fi
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
# 2. Patch [auth.oidc].allowlist in settings.toml
# ---------------------------------------------------------------------------
# On upsert, compute the allowlist as the UNION of the current allowlist and
# the roster emails — so a `vote grant` mid-sequence doesn't shrink the
# allowlist to the partial roster. On apply (install-time full reconcile)
# and delete (explicit revoke), regenerate from roster so shrinkage works
# the way those flows expect.
declare -a ALLOWLIST_EMAILS=("${EMAILS[@]}")
if [ "$ACTION" = "upsert" ]; then
    # Extract current allowlist emails from settings.toml, only from the
    # [auth.oidc] section. awk scopes to the section, grep -oE extracts
    # every quoted email.
    mapfile -t CURRENT_ALLOWLIST < <(
        awk '
            /^\[auth\.oidc\]/ { in_oidc = 1; next }
            /^\[/ && !/^\[auth\.oidc\]/ { in_oidc = 0 }
            in_oidc && /^[[:space:]]*allowlist[[:space:]]*=/ { print }
        ' "$OR_SETTINGS" | grep -oE '"[^"]+"' | tr -d '"'
    )
    for e in "${CURRENT_ALLOWLIST[@]}"; do
        in_roster=0
        for r in "${EMAILS[@]}"; do
            [ "$r" = "$e" ] && { in_roster=1; break; }
        done
        [ "$in_roster" = "0" ] && ALLOWLIST_EMAILS+=("$e")
    done
fi

# Build the TOML array payload from ALLOWLIST_EMAILS (may be wider than
# roster on upsert; equals roster on apply/delete).
toml_list=""
for e in "${ALLOWLIST_EMAILS[@]}"; do
    toml_list+="\"${e}\", "
done
toml_list="${toml_list%, }"

# Replace the allowlist line inside the [auth.oidc] section only — don't touch
# [auth.google].allowlist. awk-based because sed's section-scoped replace is
# fiddly.
tmpf=$(mktemp)
awk -v newlist="allowlist = [${toml_list}]" '
    BEGIN { in_oidc = 0 }
    /^\[auth\.oidc\]/ { in_oidc = 1; print; next }
    /^\[/ && !/^\[auth\.oidc\]/ { in_oidc = 0 }
    in_oidc && /^[[:space:]]*allowlist[[:space:]]*=/ { print newlist; next }
    { print }
' "$OR_SETTINGS" > "$tmpf"
mv "$tmpf" "$OR_SETTINGS"
chmod 644 "$OR_SETTINGS"
log "settings.toml allowlist updated"

# ---------------------------------------------------------------------------
# 3. Reconcile OR user records (create missing, set/clear admin flag)
# ---------------------------------------------------------------------------
# We query postgres directly rather than parsing `admin.py list-users` output:
# that command uses Rich tables which truncate long usernames with ellipsis,
# and `admin.py user-details <email>` returns exit 0 even when the user
# doesn't exist (error is printed to stdout). psql gives us exact matches.
or_user_exists() {
    local count
    count=$(docker exec openrelik-postgres psql -U openrelik -d openrelik -t -c \
        "SELECT COUNT(*) FROM \"user\" WHERE username = '$1';" 2>/dev/null \
        | tr -d ' ')
    [ "$count" = "1" ]
}

or_create_user() {
    local email="$1" admin_flag="$2"  # $2 = "true" | "false"
    local extra=()
    [ "$admin_flag" = "true" ] && extra+=(--admin)
    docker exec openrelik-server python admin.py create-user "$email" \
        --email "$email" --nopassword --authmethod oidc "${extra[@]}" \
        >/dev/null 2>&1 \
        || die "admin.py create-user failed for $email"
}

or_set_admin() {
    local email="$1" admin_flag="$2"  # $2 = "true" | "false"
    local flag="--admin"
    [ "$admin_flag" = "false" ] && flag="--no-admin"
    docker exec openrelik-server python admin.py set-admin "$email" "$flag" \
        >/dev/null 2>&1 \
        || die "admin.py set-admin failed for $email"
}

for i in "${!EMAILS[@]}"; do
    email="${EMAILS[$i]}"
    role="${ROLES[$i]}"
    want_admin="false"
    [ "$role" = "admin" ] && want_admin="true"

    if or_user_exists "$email"; then
        or_set_admin "$email" "$want_admin"
        log "  $email: role=$role admin=$want_admin (updated)"
    else
        or_create_user "$email" "$want_admin"
        log "  $email: role=$role admin=$want_admin (created)"
    fi
done

# ---------------------------------------------------------------------------
# 4. Demote any OR users whose email isn't in the roster.
#    Query postgres for usernames containing '@' (email-shaped — filters out
#    the local `admin` service account). Roster is source of truth; anyone
#    OIDC-shaped in the DB but not in the roster was revoked.
#
#    Gated on ACTION != "upsert" so that a serial `vote grant` sequence
#    doesn't sweep existing users in the partial-roster states between
#    calls. install.sh's install-time full reconcile passes ACTION="apply"
#    (default); `vote revoke` passes ACTION="delete" and still sweeps.
# ---------------------------------------------------------------------------
if [ "$ACTION" != "upsert" ]; then
    mapfile -t OR_USERS < <(
        docker exec openrelik-postgres psql -U openrelik -d openrelik -t -A -c \
            "SELECT username FROM \"user\" WHERE username LIKE '%@%';" 2>/dev/null
    )

    roster_has() {
        local needle="$1"
        for e in "${EMAILS[@]}"; do [ "$e" = "$needle" ] && return 0; done
        return 1
    }

    for u in "${OR_USERS[@]}"; do
        if ! roster_has "$u"; then
            or_set_admin "$u" "false"
            log "  $u: not in roster — demoted (kept in DB for audit)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 5. Reload OR to pick up the settings.toml allowlist change.
# ---------------------------------------------------------------------------
(cd "$OR_COMPOSE_DIR" && docker compose restart openrelik-server >/dev/null 2>&1) \
    || die "failed to restart openrelik-server"

log "openrelik-server restarted"
log "done."

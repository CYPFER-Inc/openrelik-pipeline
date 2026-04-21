#!/usr/bin/env bash
# =============================================================================
# or-apply.sh — reconcile OpenRelik user state with a local roster file.
#
# Roster format (one entry per line, # for comments):
#   email=role        # role ∈ {admin, analyst, reader}
#
# CYPFER → OR role mapping:
#   admin            → OR admin flag ON
#   analyst, reader  → OR admin flag OFF
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
#   bash or-apply.sh [<roster-file>]
#   default: /opt/openrelik-pipeline/rosters/or.env
# =============================================================================
set -euo pipefail

ROSTER="${1:-/opt/openrelik-pipeline/rosters/or.env}"
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
        admin|analyst|reader) ;;
        *) die "invalid role '$role' for $email (valid: admin, analyst, reader)" ;;
    esac

    EMAILS+=("$email")
    ROLES+=("$role")
done < "$ROSTER"

log "roster: ${#EMAILS[@]} entries"

# ---------------------------------------------------------------------------
# 2. Patch [auth.oidc].allowlist in settings.toml
# ---------------------------------------------------------------------------
# Build the TOML array payload.
toml_list=""
for e in "${EMAILS[@]}"; do
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
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5. Reload OR to pick up the settings.toml allowlist change.
# ---------------------------------------------------------------------------
(cd "$OR_COMPOSE_DIR" && docker compose restart openrelik-server >/dev/null 2>&1) \
    || die "failed to restart openrelik-server"

log "openrelik-server restarted"
log "done."

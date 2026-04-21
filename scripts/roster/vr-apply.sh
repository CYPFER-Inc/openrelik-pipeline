#!/usr/bin/env bash
# =============================================================================
# vr-apply.sh — reconcile Velociraptor user state with a local roster file.
#
# Roster format (one entry per line, # for comments):
#   email=role        # role ∈ {admin, investigator, reader}
#
# CYPFER → VR role mapping:
#   admin         → administrator
#   investigator  → investigator     (VR's native DFIR-operator role;
#                                      can launch hunts, approve queries,
#                                      collect artifacts)
#   reader        → reader
#
# VR's CLI surface is thinner than OR's:
#   * `user add --role <r> <username>` is idempotent — creates missing users,
#     updates the role of existing ones. No separate set-role.
#   * There is NO `user delete`, NO `user list`. That means:
#       - We cannot enumerate every VR user and auto-demote "anyone not in
#         the roster" the way or-apply.sh does via postgres. Revocations must
#         be explicit (via the ACTION/TARGET_EMAIL args).
#       - Revoke is soft-only: downgrade to `reader`. The DB record stays —
#         there is no clean way to remove it.
#   * VR's in-memory user cache only reloads on VR restart. Additions-while-
#     running take effect in the datastore but VR's session/auth layer doesn't
#     see them until the container bounces. We restart at the end unless
#     called with --no-restart (used by install.sh which invokes us pre-exec).
#
# USAGE:
#   bash vr-apply.sh [<roster>] [upsert|delete] [<target-email>] [--no-restart]
# =============================================================================
set -euo pipefail

ROSTER=""
ACTION="apply"
TARGET_EMAIL=""
RESTART=1

# Positional args + flag
while [ $# -gt 0 ]; do
    case "$1" in
        --no-restart) RESTART=0; shift ;;
        *)
            if   [ -z "$ROSTER" ];       then ROSTER="$1"
            elif [ "$ACTION" = "apply" ] && [ -n "$1" ]; then ACTION="$1"
            elif [ -z "$TARGET_EMAIL" ]; then TARGET_EMAIL="$1"
            fi
            shift ;;
    esac
done
ROSTER="${ROSTER:-/opt/openrelik-pipeline/rosters/vr.env}"

log() { printf '[vr-apply] %s\n' "$*" >&2; }
die() { printf '[vr-apply] ERROR: %s\n' "$*" >&2; exit 1; }

[ -r "$ROSTER" ] || die "roster not readable: $ROSTER"
docker ps --format '{{.Names}}' | grep -q '^velociraptor$' \
    || die "velociraptor container not running"

cypfer_to_vr() {
    case "$1" in
        admin)        printf 'administrator' ;;
        investigator) printf 'investigator' ;;
        reader)       printf 'reader' ;;
        *) return 1 ;;
    esac
}

vr_user_add() {
    local email="$1" vr_role="$2"
    # --no-warn suppresses the server-automation URL banner that VR prints on
    # every CLI invocation; we want clean logs.
    docker exec velociraptor /opt/velociraptor \
        --config /opt/server.config.yaml user add "$email" --role "$vr_role" \
        >/dev/null 2>&1 \
        || die "velociraptor user add failed: $email"
}

# ---------------------------------------------------------------------------
# 1. Reconcile the roster — idempotent upsert of each entry.
# ---------------------------------------------------------------------------
count=0
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    email="${line%%=*}"
    role="${line#*=}"
    # bare email (no '=') defaults to reader
    [ "$email" = "$line" ] && role="reader"
    email="$(echo "$email" | xargs)"
    role="$(echo "$role" | xargs)"

    vr_role=$(cypfer_to_vr "$role") \
        || die "invalid role '$role' for $email (valid: admin, investigator, reader)"
    vr_user_add "$email" "$vr_role"
    log "  $email: cypfer=$role vr=$vr_role"
    count=$((count + 1))
done < "$ROSTER"
log "roster applied: $count entries"

# ---------------------------------------------------------------------------
# 2. Explicit soft-revoke — caller (vote revoke) supplies the target email
#    which has already been removed from the roster. VR has no delete
#    primitive, so the strongest revoke is demotion to `reader`.
# ---------------------------------------------------------------------------
if [ "$ACTION" = "delete" ] && [ -n "$TARGET_EMAIL" ]; then
    vr_user_add "$TARGET_EMAIL" "reader"
    log "  $TARGET_EMAIL: soft-revoked (role → reader; VR has no delete CLI)"
fi

# ---------------------------------------------------------------------------
# 3. Cache-refresh restart. Skipped when --no-restart is passed (install.sh
#    runs us pre-exec-frontend via the entrypoint, no restart needed).
# ---------------------------------------------------------------------------
if [ "$RESTART" = "1" ]; then
    docker restart velociraptor >/dev/null 2>&1 \
        || die "velociraptor restart failed"
    log "velociraptor restarted (user-cache refresh)"
else
    log "skipping restart (--no-restart)"
fi

log "done."

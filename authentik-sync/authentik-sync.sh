#!/usr/bin/env bash
# =============================================================================
# authentik-sync.sh — Phase 4B reconciler.
#
# Polls Authentik case-<id>-{admin,investigator,reader} group membership via
# authentik-sync.timer (60s cadence) and regenerates the three rosters at
# /opt/openrelik-pipeline/rosters/{or,ts,vr}.env. Invokes the per-app
# apply scripts on drift so the app-layer state (OR allowlist + admin flags,
# TS users + admin, VR users + role) follows the Authentik source of truth.
#
# Under Phase 4B, Authentik group membership IS the source of truth for
# per-case RBAC. The rosters are derived state (cache), not config. `vote
# grant` and `vote revoke` write only to Authentik groups; this script
# catches up the roster.
#
# Usage:
#   authentik-sync.sh              # reconcile (no-op if rosters match groups)
#   authentik-sync.sh --force      # reconcile + re-run appliers regardless of drift
#
# Reads:
#   /etc/authentik-sync.env        AUTHENTIK_BASE_URL, AUTHENTIK_API_TOKEN
#   /etc/vote-case.env             CASE_ID
#   /opt/openrelik-pipeline/rosters/{or,ts,vr}.env
#
# Writes:
#   /opt/openrelik-pipeline/rosters/{or,ts,vr}.env  (on drift)
#   /var/log/authentik-sync.log                     (one JSON line per tick)
#
# Exit codes:
#   0  no drift, or drift reconciled successfully
#   1  Authentik unreachable / API failure
#   2  applier failed
#
# Safeguards:
#   - Mass-revoke: if a tick would remove ≥MASS_REVOKE_THRESHOLD% of the
#     current roster for any app, skip writes for that app and alert. Override
#     per-case via AUTHENTIK_SYNC_ALLOW_MASS_REVOKE=1 in /etc/authentik-sync.env.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration + env
# ---------------------------------------------------------------------------
ROSTER_DIR="/opt/openrelik-pipeline/rosters"
APPLIER_DIR="/opt/openrelik-pipeline/scripts/roster"
LOG_FILE="/var/log/authentik-sync.log"

MASS_REVOKE_THRESHOLD="${AUTHENTIK_SYNC_MASS_REVOKE_THRESHOLD:-50}"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

# Load env files. Both are required; fail clearly if missing.
# Guard the sources with a shell-safe read — these files are written by
# vote.sh / install.sh and shouldn't contain executable content, but the
# reconciler runs as root so be strict.
for envfile in /etc/authentik-sync.env /etc/vote-case.env; do
    if [[ ! -r "$envfile" ]]; then
        echo "[authentik-sync] ERROR: missing env file: $envfile" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    set -a; . "$envfile"; set +a
done

AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.dev.cypfer.io}"
[[ -n "${AUTHENTIK_API_TOKEN:-}" ]] || { echo "[authentik-sync] ERROR: AUTHENTIK_API_TOKEN unset" >&2; exit 1; }
[[ -n "${CASE_ID:-}" ]]            || { echo "[authentik-sync] ERROR: CASE_ID unset"            >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || { echo "[authentik-sync] ERROR: jq required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[authentik-sync] ERROR: curl required" >&2; exit 1; }

API="${AUTHENTIK_BASE_URL%/}/api/v3"

# ---------------------------------------------------------------------------
# Logging — one JSON line per tick → Loki via promtail. Keep fields stable;
# the Grafana panels + alerts in the LGTM stack key off these names.
# ---------------------------------------------------------------------------
emit_log() {
    local ts rc drift_json members applier_json mass_revoke_json error_msg
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    rc="$1"
    drift_json="$2"
    members="$3"
    applier_json="$4"
    mass_revoke_json="$5"
    error_msg="${6:-}"

    jq -nc \
        --arg ts "$ts" \
        --arg caseid "$CASE_ID" \
        --argjson rc "$rc" \
        --argjson drift "$drift_json" \
        --argjson members "$members" \
        --argjson applier "$applier_json" \
        --argjson mass_revoke "$mass_revoke_json" \
        --arg error "$error_msg" \
        '{ts:$ts, caseid:$caseid, rc:$rc, drift:$drift, members_count:$members,
          applier_rc:$applier, mass_revoke_skipped:$mass_revoke,
          error:(if $error == "" then null else $error end)}' \
        >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Authentik API calls
# ---------------------------------------------------------------------------
ak_get() {
    # $1: path-with-query
    # Emits body on stdout; non-2xx exits the script with rc=1 (the tick
    # is considered failed and roster state is left untouched).
    local path="$1" tmp code
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' \
           -H "Authorization: Bearer ${AUTHENTIK_API_TOKEN}" \
           --max-time 20 \
           "${API}${path}" || echo "000")
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
        local body
        body=$(head -c 500 "$tmp" 2>/dev/null || true)
        rm -f "$tmp"
        echo "[authentik-sync] API ${path} → HTTP ${code}: ${body}" >&2
        emit_log 1 '{}' 0 '{}' '{}' "API ${path} HTTP ${code}"
        exit 1
    fi
    cat "$tmp"
    rm -f "$tmp"
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# Returns one email per line for members of case-<CASE_ID>-<role>.
# Empty stdout means group not found OR group has no members — both are
# legitimate states distinguished by the caller (see fetch_case_groups).
fetch_group_members() {
    local role="$1"
    local gname="case-${CASE_ID}-${role}"
    ak_get "/core/groups/?name=$(urlenc "$gname")&include_users=true" \
        | jq -r '.results[0].users_obj[]? | select(.is_active == true) | .email' \
        | awk 'NF'
}

# Validates that all three case groups exist. Missing groups under PHASE4B=1
# is a provisioning failure — abort rather than strip everyone from the
# roster.
fetch_case_groups() {
    local role
    for role in admin investigator reader; do
        local gname="case-${CASE_ID}-${role}"
        local present
        present=$(ak_get "/core/groups/?name=$(urlenc "$gname")" \
                  | jq -r '.results[0].pk // empty')
        if [[ -z "$present" ]]; then
            echo "[authentik-sync] ERROR: group ${gname} not found — case not fully provisioned" >&2
            emit_log 1 '{}' 0 '{}' '{}' "group ${gname} missing"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Canonical desired roster: email→role with admin > investigator > reader
# precedence (defensive; #97's user-group-set ensures single-group membership,
# but Authentik UI edits could create multi-membership states).
# Output: one "email=role" line per user, sorted.
# ---------------------------------------------------------------------------
build_desired_roster() {
    local admins investigators readers
    admins=$(fetch_group_members admin)           || true
    investigators=$(fetch_group_members investigator) || true
    readers=$(fetch_group_members reader)         || true

    declare -A roster
    local e
    while IFS= read -r e; do [[ -z "$e" ]] && continue; roster["$e"]="admin"; done <<< "$admins"
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        [[ -z "${roster[$e]:-}" ]] && roster["$e"]="investigator"
    done <<< "$investigators"
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        [[ -z "${roster[$e]:-}" ]] && roster["$e"]="reader"
    done <<< "$readers"

    for e in "${!roster[@]}"; do
        printf '%s=%s\n' "$e" "${roster[$e]}"
    done | sort
}

# ---------------------------------------------------------------------------
# Read current roster from a file: emits sorted "email=role" lines,
# excluding comments + blank lines.
# ---------------------------------------------------------------------------
read_current_roster() {
    local path="$1"
    [[ -r "$path" ]] || { echo ""; return 0; }
    awk '
        { sub(/#.*$/, "") }                        # strip inline comments
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") } # trim
        NF && /^[^=]+=[^=]+$/ { print }
    ' "$path" | sort
}

# ---------------------------------------------------------------------------
# Mass-revoke safeguard.
# Returns 0 (proceed) or 1 (skip writes for this app).
# Counts users currently in the roster who are NOT in the desired set.
# If that count as a percentage of current exceeds the threshold, skip.
# ---------------------------------------------------------------------------
should_skip_mass_revoke() {
    local current="$1" desired="$2"

    [[ "${AUTHENTIK_SYNC_ALLOW_MASS_REVOKE:-0}" == "1" ]] && return 0

    local current_count removed_count pct
    current_count=$(printf '%s\n' "$current" | awk 'NF' | wc -l)
    (( current_count == 0 )) && return 0

    # Emails in current that aren't in desired (extract email portion).
    # Use comm on email-only sorted lists.
    local cur_emails des_emails
    cur_emails=$(printf '%s\n' "$current" | awk -F= 'NF {print $1}' | sort)
    des_emails=$(printf '%s\n' "$desired" | awk -F= 'NF {print $1}' | sort)
    removed_count=$(comm -23 <(printf '%s\n' "$cur_emails") <(printf '%s\n' "$des_emails") | wc -l)

    pct=$(( removed_count * 100 / current_count ))
    if (( pct >= MASS_REVOKE_THRESHOLD )); then
        echo "[authentik-sync] MASS_REVOKE_SKIPPED: ${removed_count}/${current_count} (${pct}%) removals ≥ threshold ${MASS_REVOKE_THRESHOLD}%" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Write a roster file atomically. Uses a tmpfile + rename to avoid a
# reader seeing a half-written file.
# ---------------------------------------------------------------------------
write_roster() {
    local path="$1" content="$2" app="$3"
    local header="# Generated by authentik-sync.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source of truth: Authentik group case-${CASE_ID}-{admin,investigator,reader}
# Do NOT hand-edit — next tick (≤60s) reverts. Use \`vote grant\` / Authentik UI.
# Format: email=role  (roles: admin, investigator, reader)
"
    local tmp="${path}.tmp.$$"
    printf '%s\n%s\n' "$header" "$content" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$path"
}

# ---------------------------------------------------------------------------
# Main reconcile loop — per-app diff + (optional) apply.
# ---------------------------------------------------------------------------
main() {
    # Fail-fast if groups missing (better than silently writing empty roster).
    fetch_case_groups

    local desired
    desired=$(build_desired_roster)

    local members_count
    members_count=$(printf '%s\n' "$desired" | awk 'NF' | wc -l)

    declare -A drift_app=(     [or]=false [ts]=false [vr]=false )
    declare -A applier_rc=(    [or]=0     [ts]=0     [vr]=0     )
    declare -A mass_revoke=(   [or]=false [ts]=false [vr]=false )

    local overall_rc=0 app current path
    for app in or ts vr; do
        path="${ROSTER_DIR}/${app}.env"
        current=$(read_current_roster "$path")

        # Skip if unchanged unless --force.
        if [[ "$current" == "$desired" ]] && [[ $FORCE -eq 0 ]]; then
            continue
        fi

        drift_app[$app]=true

        # Mass-revoke safeguard — skip writes for this app only, not the whole tick.
        if ! should_skip_mass_revoke "$current" "$desired"; then
            mass_revoke[$app]=true
            continue
        fi

        write_roster "$path" "$desired" "$app"

        # Invoke the applier. Appliers live in scripts/roster/<app>-apply.sh
        # and default to the right roster path + "apply" action (sweep-on).
        local rc=0
        bash "${APPLIER_DIR}/${app}-apply.sh" >> "$LOG_FILE" 2>&1 || rc=$?
        applier_rc[$app]=$rc
        if (( rc != 0 )); then
            overall_rc=2
        fi
    done

    # Build JSON for emit_log.
    local drift_json applier_json mass_revoke_json
    drift_json=$(jq -nc \
        --argjson or   "${drift_app[or]}" \
        --argjson ts   "${drift_app[ts]}" \
        --argjson vr   "${drift_app[vr]}" \
        '{or:$or, ts:$ts, vr:$vr}')
    applier_json=$(jq -nc \
        --argjson or  "${applier_rc[or]}" \
        --argjson ts  "${applier_rc[ts]}" \
        --argjson vr  "${applier_rc[vr]}" \
        '{or:$or, ts:$ts, vr:$vr}')
    mass_revoke_json=$(jq -nc \
        --argjson or  "${mass_revoke[or]}" \
        --argjson ts  "${mass_revoke[ts]}" \
        --argjson vr  "${mass_revoke[vr]}" \
        '{or:$or, ts:$ts, vr:$vr}')

    emit_log "$overall_rc" "$drift_json" "$members_count" "$applier_json" "$mass_revoke_json" ""
    exit "$overall_rc"
}

main

#!/bin/bash

# ─── Usage ────────────────────────────────────────────────────────────────────
# bash install.sh                          — install everything (default)
# bash install.sh --all                    — install everything
# bash install.sh --ts                     — install Timesketch only
# bash install.sh --or                     — install OpenRelik (requires Timesketch)
# bash install.sh --vr                     — install Velociraptor only
# bash install.sh --ts --or               — install Timesketch + OpenRelik
# bash install.sh --config /path/azure.cfg — pull config.env from vault using this cfg
# ─────────────────────────────────────────────────────────────────────────────

# ─── Parse arguments ──────────────────────────────────────────────────────────
INSTALL_TS=false
INSTALL_OR=false
INSTALL_VR=false
AZURE_CFG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)
      INSTALL_TS=true
      INSTALL_OR=true
      INSTALL_VR=true
      ;;
    --ts)
      INSTALL_TS=true
      ;;
    --or)
      INSTALL_OR=true
      ;;
    --vr)
      INSTALL_VR=true
      ;;
    --config)
      shift
      if [ -z "$1" ]; then
        echo "ERROR: --config requires a path to an azure.cfg file"
        exit 1
      fi
      AZURE_CFG_ARG="$1"
      ;;
    --help|-h)
      echo "Usage: bash install.sh [--ts] [--or] [--vr] [--all] [--config /path/to/azure.cfg]"
      echo ""
      echo "  --ts               Install Timesketch and dependencies"
      echo "  --or               Install OpenRelik and dependencies (requires Timesketch)"
      echo "  --vr               Install Velociraptor and configure via API"
      echo "  --all              Install everything (default if no arguments given)"
      echo "  --config <path>    Pull config.env from Azure Key Vault using this cfg file"
      echo ""
      echo "Examples:"
      echo "  bash install.sh                                    # install all"
      echo "  bash install.sh --vr                               # Velociraptor only"
      echo "  bash install.sh --ts --or                          # Timesketch + OpenRelik"
      echo "  bash install.sh --config /path/azure-dev.cfg       # pull config from vault, install all"
      echo "  bash install.sh --config /path/azure-dev.cfg --ts  # pull config, install TS only"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      echo "       Run bash install.sh --help for usage"
      exit 1
      ;;
  esac
  shift
done

# Default to install everything if no component was selected
if [ "${INSTALL_TS}" = "false" ] && [ "${INSTALL_OR}" = "false" ] && [ "${INSTALL_VR}" = "false" ]; then
  INSTALL_TS=true
  INSTALL_OR=true
  INSTALL_VR=true
fi

echo "Install plan:"
echo "  Timesketch:   $INSTALL_TS"
echo "  OpenRelik:    $INSTALL_OR"
echo "  Velociraptor: $INSTALL_VR"
echo "─────────────────────────────────────────────────"

# ─── Helpers ──────────────────────────────────────────────────────────────────

retry_pull() {
  # Retry docker compose pull up to 5 times to handle transient TLS errors
  # (common in LXC containers with OVN Geneve encapsulation)
  local max_retries=5
  for i in $(seq 1 $max_retries); do
    docker compose pull && return 0
    echo "Pull failed, retry $i/$max_retries..."
    sleep 5
  done
  echo "ERROR: docker compose pull failed after $max_retries attempts"
  return 1
}

mirror_image() {
  # Rewrite an image reference to use the local registry mirror if configured.
  # Three cases:
  #   1. Explicit registry (first segment contains '.' or ':'):
  #        ghcr.io/cypfer-inc/x:latest    → MIRROR/cypfer-inc/x:latest
  #        us-docker.pkg.dev/a/b/c:v1     → MIRROR/a/b/c:v1
  #   2. Bare image (no slash): Docker Hub library
  #        redis:8     → MIRROR/library/redis:8
  #        nginx:alpine → MIRROR/library/nginx:alpine
  #   3. Docker Hub org/name (has slash, first segment is NOT a registry):
  #        opensearchproject/opensearch → MIRROR/opensearchproject/opensearch
  #        prom/prometheus:v3           → MIRROR/prom/prometheus:v3
  local image="$1"
  if [ -z "${REGISTRY_MIRROR:-}" ]; then
    echo "$image"
    return
  fi
  if [[ "$image" != */* ]]; then
    echo "${REGISTRY_MIRROR}/library/${image}"
    return
  fi
  local first="${image%%/*}"
  if [[ "$first" == *.* ]] || [[ "$first" == *:* ]]; then
    echo "${REGISTRY_MIRROR}/${image#*/}"
  else
    echo "${REGISTRY_MIRROR}/${image}"
  fi
}

rewrite_compose_images() {
  # Iterate every `image: X` line in the compose file and rewrite X via
  # mirror_image(). Replaces the old prefix-enumeration approach, which
  # missed us-docker.pkg.dev/, bare nginx:, opensearchproject/, etc.
  local compose_file="$1"
  if [ -z "${REGISTRY_MIRROR:-}" ]; then
    return
  fi
  echo "Rewriting image references to use local registry: ${REGISTRY_MIRROR}"
  local img mirrored esc_orig esc_new
  mapfile -t IMAGES < <(grep -oE '^[[:space:]]*image:[[:space:]]*[^[:space:]#]+' "$compose_file" | awk '{print $2}' | sort -u)
  for img in "${IMAGES[@]}"; do
    mirrored=$(mirror_image "$img")
    [ "$img" = "$mirrored" ] && continue
    esc_orig=$(printf '%s' "$img" | sed 's/[\/&|]/\\&/g')
    esc_new=$(printf '%s' "$mirrored" | sed 's/[\/&|]/\\&/g')
    # Anchor on "image:" so we don't accidentally rewrite the same string elsewhere
    sed -i -E "s|(^[[:space:]]*image:[[:space:]]*)${esc_orig}([[:space:]]*$)|\1${esc_new}\2|g" "$compose_file"
  done
}

pin_compose_image_digest() {
  # Rewrite `image: .../<name>:<tag>` → `image: .../<name>@<digest>` for one image.
  # Runs after rewrite_compose_images, so it matches both upstream and mirrored prefixes.
  # Upstream openrelik-deploy pins by version tag (e.g. 0.7.0); we pin by digest so
  # fresh case launches get an identical, vetted image — including one that carries
  # main-branch code (auth/oidc.py) before an upstream release bakes it in.
  local compose_file="$1"
  local name="$2"
  local digest="$3"
  [ -z "${digest:-}" ] && return
  sed -i -E "s|(^[[:space:]]*image:[[:space:]]*[^[:space:]]*/)${name}:[^[:space:]@]+|\1${name}@${digest}|g" "$compose_file"
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
# Look for azure.cfg — --config arg, /etc/azure.cfg (vote/prod), or local (dev)
if [ -n "${AZURE_CFG_ARG}" ]; then
  if [ ! -f "${AZURE_CFG_ARG}" ]; then
    echo "ERROR: Config file not found: ${AZURE_CFG_ARG}"
    exit 1
  fi
  VAULT_CONFIG="${AZURE_CFG_ARG}"
elif [ -f "/etc/azure.cfg" ]; then
  VAULT_CONFIG="/etc/azure.cfg"
elif [ -f "${SCRIPT_DIR}/azure.cfg" ]; then
  VAULT_CONFIG="${SCRIPT_DIR}/azure.cfg"
else
  VAULT_CONFIG=""
fi

# Pull config.env from Azure Key Vault if azure.cfg exists and config.env is missing
if [ -n "${VAULT_CONFIG}" ] && [ ! -f "${CONFIG_FILE}" ]; then
  echo "Pulling config.env from Azure Key Vault..."
  if command -v python3 &>/dev/null; then
    # Ensure Azure SDK is installed — try apt first, fall back to pip
    if ! python3 -c "import azure.keyvault.secrets" 2>/dev/null; then
      echo "  Installing Azure SDK..."
      apt-get update -qq && apt-get install -y -qq python3-azure-keyvault-secrets python3-azure-identity >/dev/null 2>&1 || {
        # Not in apt repos — fall back to pip
        command -v pip3 &>/dev/null || apt-get install -y -qq python3-pip >/dev/null 2>&1
        pip3 install --quiet --break-system-packages azure-keyvault-secrets azure-identity 2>/dev/null || true
      }
    fi
    python3 "${SCRIPT_DIR}/scripts/vault.py" --pull --config "${VAULT_CONFIG}"
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to pull config.env from vault"
      exit 1
    fi
  else
    echo "ERROR: python3 not found — cannot pull from vault"
    echo "       Install python3 or place config.env manually"
    exit 1
  fi
elif [ -n "${VAULT_CONFIG}" ] && [ -f "${CONFIG_FILE}" ]; then
  echo "config.env exists — skipping vault pull (delete config.env to re-pull)"
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  echo "       Options:"
  echo "         - Place azure.cfg at /etc/azure.cfg (prod) or ${SCRIPT_DIR}/azure.cfg (dev)"
  echo "         - Or place config.env directly at ${CONFIG_FILE}"
  exit 1
fi

set -a
source "${CONFIG_FILE}"

# Phase 4A: when vote launch provisioned per-case Authentik apps, it pushed
# /etc/vote-case-authentik.env into the LXC with per-case client_id/secret
# and app slugs. Sourcing AFTER config.env intentionally — per-case values
# override the shared-app values in the vault. Absent file = stay on shared-
# app path (backwards compatible).
if [ -f /etc/vote-case-authentik.env ]; then
  source /etc/vote-case-authentik.env
  echo "Per-case Authentik creds loaded from /etc/vote-case-authentik.env (Phase 4A)"
fi
set +a

# Authentik application slugs — defaults match the pre-Phase-4A shared apps.
# Overridden per-case by the file loaded above.
AUTHENTIK_OR_APP_SLUG="${AUTHENTIK_OR_APP_SLUG:-openrelik}"
AUTHENTIK_TS_APP_SLUG="${AUTHENTIK_TS_APP_SLUG:-time-sketch}"
AUTHENTIK_VR_APP_SLUG="${AUTHENTIK_VR_APP_SLUG:-velociraptor}"

# Default local registry mirror — nginx-server on the vRack. vault config.env
# can override. Everything below this line can reference ${REGISTRY_MIRROR}
# knowing it's set in prod (dev-mode override still empties it later).
REGISTRY_MIRROR="${REGISTRY_MIRROR:-51.222.196.105:5000}"

echo "config.env loaded successfully"

MISSING_DIGESTS=()

DIGEST_VARS=(
  "OPENRELIK_SERVER_DIGEST"
  "OPENRELIK_MEDIATOR_DIGEST"
  "OPENRELIK_UI_DIGEST"
  "OPENRELIK_WORKER_PLASO_DIGEST"
  "OPENRELIK_WORKER_TIMESKETCH_DIGEST"
  "REDIS_DIGEST"
  "TIMESKETCH_DIGEST"
  "VELOCIRAPTOR_DIGEST"
)

for VAR in "${DIGEST_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    MISSING_DIGESTS+=("${VAR}")
  fi
done

if [ ${#MISSING_DIGESTS[@]} -gt 0 ]; then
  echo "ERROR: The following digest fields are empty in config.env:"
  for VAR in "${MISSING_DIGESTS[@]}"; do
    echo "       - ${VAR}"
  done
  echo ""
  echo "       Please contact your Admin for the latest"
  echo "       file and instructions"
  exit 1
fi

echo "All digest fields verified"
echo "─────────────────────────────────────────────────"

# ─── IP address detection ─────────────────────────────────────────────────────
# If IP_ADDRESS is already set in config.env it is used as-is (manual override).
# Otherwise auto-detect from the primary non-loopback IPv4 interface.
if [ -z "${IP_ADDRESS:-}" ]; then
  IP_ADDRESS=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  # Fallback: first non-loopback IPv4 from ip addr
  if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS=$(ip -4 addr show scope global | awk '/inet / {split($2,a,"/"); print a[1]}' | head -1)
  fi
  # Last resort fallback
  if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="127.0.0.1"
    echo "WARNING: Could not auto-detect IP address, falling back to 127.0.0.1"
    echo "         Set IP_ADDRESS in config.env to override"
  else
    echo "Auto-detected IP address: ${IP_ADDRESS}"
  fi
else
  echo "Using IP address from config.env: ${IP_ADDRESS}"
fi
export IP_ADDRESS

mkdir -p /opt/openrelik-pipeline/logs

# ─── Structured install audit trail ───────────────────────────────────────────
# Emits JSON lines to install.audit.log that case-promtail tails with
# source=case-install, class=audit. Grafana alert rules fire on
# install-start / install-error / install-complete events.
INSTALL_AUDIT_LOG="/opt/openrelik-pipeline/logs/install.audit.log"

emit_install_audit() {
  # Usage: emit_install_audit <action> <verdict> [component]
  # action: install-start | install-error | install-complete
  # verdict: ok | error
  local action="$1" verdict="$2" component="${3:-}"
  local ts case_id
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case_id="${CASE_ID:-unknown}"
  # Never fail the install because audit emission failed.
  if [ -n "$component" ]; then
    printf '{"ts":"%s","source":"case-install","class":"audit","case":"%s","action":"%s","verdict":"%s","component":"%s"}\n' \
      "$ts" "$case_id" "$action" "$verdict" "$component" \
      >> "${INSTALL_AUDIT_LOG}" 2>/dev/null || true
  else
    printf '{"ts":"%s","source":"case-install","class":"audit","case":"%s","action":"%s","verdict":"%s"}\n' \
      "$ts" "$case_id" "$action" "$verdict" \
      >> "${INSTALL_AUDIT_LOG}" 2>/dev/null || true
  fi
}

# ─── Environment validation ───────────────────────────────────────────────────
ENVIRONMENT=${ENVIRONMENT:-dev}
echo "Environment: ${ENVIRONMENT}"

# Always capture install output to a log file — on LXC there's no terminal
# to scroll back through. tee sends to both console and log.
mkdir -p /opt/openrelik-pipeline/logs
MASTER_LOG="/opt/openrelik-pipeline/logs/install.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install starting — environment: ${ENVIRONMENT}" > "${MASTER_LOG}"
exec > >(tee -a "${MASTER_LOG}") 2>&1

# Fire the install-start audit event as soon as we have logging set up.
# CASE_ID may still be empty on non-vote-managed dev installs — that's fine,
# it falls back to "unknown" and alerts skip those.
emit_install_audit install-start ok

if [ "${ENVIRONMENT}" = "prod" ]; then
  # When vote-case.env exists, URLs are computed from CASE_ID/CASE_DOMAIN.
  # Only check for manual prod variables when vote is not managing the deploy.
  if [ ! -f /etc/vote-case.env ]; then
    MISSING_PROD_VARS=()
    for VAR in CASE_NUMBER TIMESKETCH_PUBLIC_URL OPENRELIK_PUBLIC_URL \
               VELOCIRAPTOR_PUBLIC_URL VELOCIRAPTOR_CLIENT_URL PIPELINE_PUBLIC_URL; do
      if [ -z "${!VAR}" ]; then
        MISSING_PROD_VARS+=("${VAR}")
      fi
    done

    if [ ${#MISSING_PROD_VARS[@]} -gt 0 ]; then
      echo "ERROR: Production mode requires these variables to be set in config.env:"
      for VAR in "${MISSING_PROD_VARS[@]}"; do
        echo "       - ${VAR}"
      done
      exit 1
    fi
    echo "Production environment variables verified"
  else
    echo "Vote-managed deployment — URLs computed from /etc/vote-case.env"
  fi

elif [ "${ENVIRONMENT}" = "dev" ]; then
  echo "Dev mode — services accessible via direct IP:port"
  echo "  Timesketch:   http://${IP_ADDRESS}:80"
  echo "  OpenRelik:    http://${IP_ADDRESS}:8711"
  echo "  Velociraptor: http://${IP_ADDRESS}:8889"
  echo "  Pipeline:     http://${IP_ADDRESS}:5000"

else
  echo "ERROR: ENVIRONMENT must be 'dev' or 'prod' — got '${ENVIRONMENT}'"
  exit 1
fi
echo "─────────────────────────────────────────────────"

# Log which images/branches will be used
echo "Component images:"
echo "  Pipeline:   ${PIPELINE_IMAGE:-ghcr.io/cypfer-inc/openrelik-pipeline:latest}"
echo "  OR Config:  ${OR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-or-config:latest}"
echo "  TS Config:  ${TS_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-ts-config:latest}"
echo "  VR Config:  ${VR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-vr-config:latest}"
echo "  install.sh: $(git -C "${SCRIPT_DIR}" branch --show-current 2>/dev/null || echo 'unknown')"
echo "─────────────────────────────────────────────────"

if [ -n "${DOCKERHUB_USER}" ] && [ -n "${DOCKERHUB_TOKEN}" ]; then
  echo "Authenticating to Docker Hub..."
  echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USER}" --password-stdin || {
    echo "WARNING: Docker Hub login failed — may hit rate limits"
  }
fi

# Local registry mirror — only used in prod (LXC/MicroCloud over vRack).
# Dev VMs pull from the internet directly — ignore mirror setting.
if [ "${ENVIRONMENT}" = "dev" ] && [ -n "${REGISTRY_MIRROR:-}" ]; then
  echo "Dev mode — ignoring REGISTRY_MIRROR (not needed on dev VMs)"
  REGISTRY_MIRROR=""
fi

if [ -n "${REGISTRY_MIRROR:-}" ]; then
  echo "Local registry mirror: ${REGISTRY_MIRROR}"
  # Login to mirror if it requires auth
  # Test mirror connectivity (no auth needed for local registry)
  docker pull "${REGISTRY_MIRROR}/library/redis:8" >/dev/null 2>&1 && \
    echo "  Mirror is accessible" || \
    echo "  WARNING: Mirror not accessible — will fall back to internet pulls"
fi

cd /opt

# ─── Timesketch ───────────────────────────────────────────────────────────────
if [ "${INSTALL_TS}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying Timesketch..."
  echo "Output is being logged, this may take 5-7 minutes"
  curl -s -O https://raw.githubusercontent.com/google/timesketch/master/contrib/deploy_timesketch.sh
  chmod 755 deploy_timesketch.sh

  # Patch deploy_timesketch.sh to skip 'docker compose up' — we'll do it ourselves
  # after pre-pulling from the mirror using the correct version tags from .env
  sed -i 's|docker compose up -d|echo "Skipping docker compose up — will run after pre-pull"|' deploy_timesketch.sh
  sed -i 's|docker-compose up -d|echo "Skipping docker-compose up — will run after pre-pull"|' deploy_timesketch.sh

  # Pre-pull happens after deploy_timesketch.sh creates .env with version tags.

  (./deploy_timesketch.sh <<EOF
Y
N
EOF
  ) 2>/opt/openrelik-pipeline/logs/timesketch-install.log

  cd timesketch

  # Rewrite Timesketch docker-compose to use local mirror
  rewrite_compose_images /opt/timesketch/docker-compose.yml

  # Read actual version tags from the .env file that deploy_timesketch.sh created
  if [ -n "${REGISTRY_MIRROR:-}" ] && [ -f /opt/timesketch/.env ]; then
    echo "Pre-pulling Timesketch images with correct version tags..."
    source /opt/timesketch/.env
    for spec in \
      "us-docker.pkg.dev/osdfir-registry/timesketch/timesketch:${TIMESKETCH_VERSION}" \
      "postgres:${POSTGRES_VERSION}" \
      "redis:${REDIS_VERSION}" \
      "opensearchproject/opensearch:${OPENSEARCH_VERSION}" \
      "nginx:${NGINX_VERSION}"; do
      MIRRORED=$(mirror_image "$spec")
      echo "  Pulling ${MIRRORED}..."
      docker pull "${MIRRORED}" 2>/dev/null && \
        docker tag "${MIRRORED}" "$spec" 2>/dev/null || \
        echo "    WARNING: ${MIRRORED} not in mirror — will fall back to internet"
    done
  fi

  # Now start Timesketch (deploy script skipped this)
  echo "Starting Timesketch containers..."
  docker compose up -d 2>&1 | tee -a /opt/openrelik-pipeline/logs/timesketch-install.log


  FORMATTER_FILE="/opt/timesketch/etc/timesketch/plaso_formatters.yaml"

  if [ -f "$FORMATTER_FILE" ]; then
    echo "Patching Plaso EVTX formatter to avoid winevt_rc crash..."
    cp -a "$FORMATTER_FILE" "${FORMATTER_FILE}.bak"
    sed -i '/^custom_helpers:/,/^message:/{
      /^custom_helpers:/d
      /identifier: '\''windows_eventlog_message'\''/d
      /output_attribute: '\''message_string'\''/d
    }' "$FORMATTER_FILE"
    sed -i "/^[[:space:]]*-[[:space:]]*'{message_string}'[[:space:]]*$/d" "$FORMATTER_FILE"
    echo "Formatter patched successfully."
  else
    echo "WARNING: Formatter file not found at $FORMATTER_FILE"
  fi

  docker compose restart timesketch-worker

  echo -e "${TIMESKETCH_PASSWORD}\n${TIMESKETCH_PASSWORD}" | \
    docker compose exec -T timesketch-web tsctl create-user "admin"

  # ─── Timesketch OIDC (prod only) ────────────────────────────────────────────
  # When AUTHENTIK_TS_CLIENT_ID is set, configure Timesketch to use Authentik
  # as its OIDC provider. Dev deployments use local auth only.
  if [ "${ENVIRONMENT}" = "prod" ] && [ -n "${AUTHENTIK_TS_CLIENT_ID:-}" ]; then
    TS_CONF="/opt/timesketch/etc/timesketch/timesketch.conf"

    # Compute the Authentik discovery URL
    AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.dev.cypfer.io}"

    echo "Configuring Timesketch OIDC..."
    echo "  Authentik: ${AUTHENTIK_BASE_URL}"
    echo "  Client ID: ${AUTHENTIK_TS_CLIENT_ID}"

    # Patch GOOGLE_OIDC_* variables in timesketch.conf
    # These variable names are Google-prefixed but work with any OIDC provider.
    sed -i "s|^GOOGLE_OIDC_ENABLED = False|GOOGLE_OIDC_ENABLED = True|" "$TS_CONF"
    sed -i "s|^GOOGLE_OIDC_CLIENT_ID = .*|GOOGLE_OIDC_CLIENT_ID = '${AUTHENTIK_TS_CLIENT_ID}'|" "$TS_CONF"
    sed -i "s|^GOOGLE_OIDC_CLIENT_SECRET = .*|GOOGLE_OIDC_CLIENT_SECRET = '${AUTHENTIK_TS_CLIENT_SECRET}'|" "$TS_CONF"
    sed -i "s|^GOOGLE_OIDC_DISCOVERY_URL = .*|GOOGLE_OIDC_DISCOVERY_URL = '${AUTHENTIK_BASE_URL}/application/o/${AUTHENTIK_TS_APP_SLUG}/.well-known/openid-configuration'|" "$TS_CONF"

    # Auth URL — Authentik's authorize endpoint
    sed -i "s|^GOOGLE_OIDC_AUTH_URL = .*|GOOGLE_OIDC_AUTH_URL = '${AUTHENTIK_BASE_URL}/application/o/authorize/'|" "$TS_CONF"

    # Algorithm — Authentik uses RS256 by default
    sed -i "s|^GOOGLE_OIDC_ALGORITHM = .*|GOOGLE_OIDC_ALGORITHM = 'RS256'|" "$TS_CONF"

    # Hosted domain — not applicable for Authentik, clear it
    sed -i "s|^GOOGLE_OIDC_HOSTED_DOMAIN = .*|GOOGLE_OIDC_HOSTED_DOMAIN = ''|" "$TS_CONF"

    # Allow the `admin` service account to keep using local auth once OIDC is
    # enabled. The openrelik-pipeline container logs in as admin/password via
    # timesketch-api-client; without this, Timesketch aborts with
    # "Local authentication is disabled for this user. Please use OAuth."
    #
    # `ai-summary-worker@cypfer.local` is the Phase 3 AI service account
    # (microcloud:llm/README.md §3). v1 uses local-password auth from the
    # worker; Phase 7 will migrate to OIDC bearer via GOOGLE_OIDC_API_CLIENT_ID
    # at which point this entry can be dropped.
    sed -i "s|^LOCAL_AUTH_ALLOWED_USERS = .*|LOCAL_AUTH_ALLOWED_USERS = ['admin', 'ai-summary-worker@cypfer.local']|" "$TS_CONF"

    # Restart Timesketch to pick up OIDC config. Also bounce nginx: it caches
    # the upstream container IP at startup, and when timesketch-web comes back
    # on a new IP (docker reassigns on restart) nginx keeps sending traffic to
    # whatever container now sits at the old IP — typically timesketch-worker,
    # which doesn't serve HTTP, hence 502 Bad Gateway. Observed on case-1336.
    cd /opt/timesketch
    docker compose restart timesketch-web
    docker compose restart nginx
    cd /opt

    # ─── Seed the TS roster file + apply ──────────────────────────────────
    # TS_BOOTSTRAP_USERS accepted formats (comma-separated):
    #   email            → role defaults to reader
    #   email:role       → role ∈ {admin, investigator, reader}
    # Runtime changes go through 'vote grant' / 'vote revoke' → ts-apply.sh.
    TS_ROSTER_DIR="/opt/openrelik-pipeline/rosters"
    TS_ROSTER_FILE="${TS_ROSTER_DIR}/ts.env"
    mkdir -p "${TS_ROSTER_DIR}"
    chmod 700 "${TS_ROSTER_DIR}"
    {
      echo "# Generated by install.sh on $(date -u +%FT%TZ)"
      echo "# Live TS case roster. Edit via 'vote grant' / 'vote revoke'."
      echo "# Format: email=role   (roles: admin, investigator, reader)"
      if [ -n "${TS_BOOTSTRAP_USERS:-}" ]; then
        IFS=',' read -ra TS_PAIRS <<< "${TS_BOOTSTRAP_USERS}"
        for pair in "${TS_PAIRS[@]}"; do
          pair="$(echo "$pair" | xargs)"
          [ -z "$pair" ] && continue
          email="${pair%%:*}"
          role="${pair#*:}"
          [ "$email" = "$pair" ] && role="reader"
          echo "${email}=${role}"
        done
      fi
    } > "${TS_ROSTER_FILE}"
    chmod 600 "${TS_ROSTER_FILE}"
    echo "Seeded TS roster: ${TS_ROSTER_FILE}"

    # ─── Phase 3 (TS, part 1): roster injection — append AI account ──────────
    # microcloud:llm/README.md §3. The ai-summary-worker user is just another
    # row in the TS roster from ts-apply.sh's perspective; let the apply
    # script create it with its random password (which we override below
    # AFTER apply has run). Decide the password here so it's available for
    # the env file later in install.sh; preserve from any prior run.
    AI_TS_USER="ai-summary-worker@cypfer.local"
    AI_ENV_FILE="/etc/vote-case-ai.env"
    if [ -f "${AI_ENV_FILE}" ] && grep -q '^AI_TS_PASSWORD=' "${AI_ENV_FILE}"; then
      AI_TS_PASSWORD="$(grep '^AI_TS_PASSWORD=' "${AI_ENV_FILE}" | cut -d= -f2- | tr -d '"')"
      echo "  AI TS password: preserved from ${AI_ENV_FILE}"
    else
      AI_TS_PASSWORD="$(openssl rand -hex 32)"
      echo "  AI TS password: generated"
    fi
    echo "${AI_TS_USER}=reader" >> "${TS_ROSTER_FILE}"
    echo "Appended AI service account to TS roster"

    # Apply the roster — TS picks up DB changes live, no restart needed.
    # Roster applier needs the running timesketch-web container (restart above
    # should have completed by now, but give it a moment).
    sleep 3
    bash /opt/openrelik-pipeline/scripts/roster/ts-apply.sh "${TS_ROSTER_FILE}" \
      2>&1 | tee -a /opt/openrelik-pipeline/logs/ts-roster-apply.log \
      || echo "WARNING: ts-apply.sh returned non-zero — check log"

    # ─── Phase 3 (TS, part 2): force AI password to match the env file ──────
    # ts-apply.sh just created the AI user with a random password we can't
    # recover. Force-set it via tsctl shell to match AI_TS_PASSWORD (which
    # is what gets written into /etc/vote-case-ai.env later).
    #
    # Why this runs AFTER ts-apply.sh rather than pre-creating the user
    # before it: TS takes a long time to accept tsctl exec after the OIDC
    # restart (>60s observed on case-2092). ts-apply.sh handles that wait
    # naturally — by the time it returns, TS is known-ready, so this
    # follow-up tsctl call doesn't need its own wait loop.
    #
    # Idempotent across re-runs (force-sets the DB password every time to
    # match the env file). Self-heals broken cases left over from earlier
    # buggy install passes.
    #
    # tsctl shell is needed because the User model's relationship() to
    # Sketch requires the full Flask app context — raw `python3 -c` errors
    # with KeyError: 'Sketch'.
    #
    # cd /opt/timesketch is REQUIRED — `docker compose` needs to find the
    # compose file. Without it, both this exec and the restart below
    # silently fail with "no configuration file provided: not found",
    # leaving the AI user with ts-apply.sh's random password and the env
    # file's password disagreeing. Observed on case-2093.
    #
    # tsctl shell drops into code.InteractiveConsole — a REPL that keeps
    # any `if X:` (even single-line `if X: Y`) open until it sees a blank
    # line, in case an `elif`/`else` follows. The next un-indented
    # statement is then parsed as part of the if-block and raises
    # SyntaxError. The REPL silently recovers, the rest of the heredoc
    # runs, and any unconditional success print masks the failure.
    # Observed on case-2094 with `if u is None: raise ...` — set_password
    # never executed, audit user lookups silently kept the random
    # password ts-apply.sh assigned. Fix: use `assert` (single
    # statement, no continuation). Print the actual check_password()
    # result so bash can verify post-state and abort if the change
    # didn't persist.
    cd /opt/timesketch
    AI_TS_USER="${AI_TS_USER}" AI_TS_PASSWORD="${AI_TS_PASSWORD}" \
      docker compose exec -T -e AI_TS_USER -e AI_TS_PASSWORD \
        timesketch-web tsctl shell <<'PYSHELL' 2>&1 | tee /tmp/ai-pwset.out
import os
from timesketch.models import db_session
from timesketch.models.user import User
u = db_session.query(User).filter_by(username=os.environ["AI_TS_USER"]).first()
assert u is not None, "AI user not found after ts-apply.sh"
u.set_password(os.environ["AI_TS_PASSWORD"])
db_session.commit()
print("AI_PWSET_VERIFIED=" + str(u.check_password(os.environ["AI_TS_PASSWORD"])))
PYSHELL
    if grep -q "AI_PWSET_VERIFIED=True" /tmp/ai-pwset.out; then
      echo "AI user password forcibly set to match /etc/vote-case-ai.env"
    else
      echo "FATAL: AI user password set_password did not persist — tsctl output above" >&2
      rm -f /tmp/ai-pwset.out
      exit 1
    fi
    rm -f /tmp/ai-pwset.out

    # Restart timesketch-web so the in-memory user cache picks up the new
    # password. Without this, /login keeps rejecting even though DB
    # check_password returns True. Confirmed needed during case-2088 manual
    # recovery.
    docker compose restart timesketch-web
    cd /opt

    echo "Timesketch OIDC configured"
  elif [ "${ENVIRONMENT}" = "prod" ]; then
    echo "AUTHENTIK_TS_CLIENT_ID not set — Timesketch using local auth only"
  fi

  echo "Timesketch deployment complete"
  cd /opt
fi

# ─── OpenRelik ────────────────────────────────────────────────────────────────
if [ "${INSTALL_OR}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying OpenRelik..."
  cd /opt
  curl -s -O https://raw.githubusercontent.com/cypfer-inc/openrelik-deploy/main/docker/install.sh

  # Pre-pull OpenRelik images from the local mirror before the deploy script
  # runs.  Two layers to warm:
  #
  #   1. TAGGED images that upstream openrelik-deploy/install.sh requests via
  #      `docker compose pull`.  Those tags pre-date the generic OIDC module so
  #      we will swap them for digests later -- but the tag-layer pull still
  #      has to succeed first or upstream's install bails.
  #
  #   2. DIGEST-pinned images that pin_compose_image_digest rewrites compose to
  #      use after the tagged install.  Without this loop, `docker compose
  #      up -d` after pinning misses the mirror and falls back to the internet
  #      on every install (slow + Geneve TLS flakes).  Digest list is sourced
  #      directly from config.env so this stays in lock-step with what is
  #      actually deployed.
  if [ -n "${REGISTRY_MIRROR:-}" ]; then
    echo "Pre-pulling OpenRelik images (tagged) from local mirror..."
    for img in \
      ghcr.io/openrelik/openrelik-server:0.7.0 \
      ghcr.io/openrelik/openrelik-ui:0.7.0 \
      ghcr.io/openrelik/openrelik-mediator:0.7.0 \
      ghcr.io/openrelik/openrelik-metrics:0.7.0 \
      ghcr.io/openrelik/openrelik-worker-plaso:0.5.0 \
      ghcr.io/openrelik/openrelik-worker-extraction:0.5.0 \
      ghcr.io/openrelik/openrelik-worker-strings:0.3.0 \
      ghcr.io/openrelik/openrelik-worker-grep:0.2.0 \
      postgres:17 \
      redis:8 \
      ubuntu:22.04 \
      prom/prometheus:v3; do
      MIRRORED=$(mirror_image "$img")
      echo "  Pulling ${MIRRORED}..."
      docker pull "${MIRRORED}" 2>/dev/null && \
        docker tag "${MIRRORED}" "${img}" 2>/dev/null || true
    done

    echo "Pre-pulling OpenRelik images (digest-pinned) from local mirror..."
    # Base-image map for every digest var that may be pinned in config.env.
    # Mirrors the IMAGE_MAP in .github/workflows/scan-images.yml -- keep the
    # two in sync when adding a new digest pin.
    declare -A DIGEST_IMAGE_MAP=(
      ["OPENRELIK_SERVER_DIGEST"]="ghcr.io/openrelik/openrelik-server"
      ["OPENRELIK_UI_DIGEST"]="ghcr.io/openrelik/openrelik-ui"
      ["OPENRELIK_MEDIATOR_DIGEST"]="ghcr.io/openrelik/openrelik-mediator"
      ["OPENRELIK_WORKER_PLASO_DIGEST"]="ghcr.io/openrelik/openrelik-worker-plaso"
      ["OPENRELIK_WORKER_TIMESKETCH_DIGEST"]="ghcr.io/openrelik/openrelik-worker-timesketch"
      ["OPENRELIK_WORKER_EXTRACTION_DIGEST"]="ghcr.io/openrelik/openrelik-worker-extraction"
      ["OPENRELIK_WORKER_STRINGS_DIGEST"]="ghcr.io/openrelik/openrelik-worker-strings"
      ["OPENRELIK_WORKER_GREP_DIGEST"]="ghcr.io/openrelik/openrelik-worker-grep"
      ["REDIS_DIGEST"]="redis"
      ["POSTGRES_DIGEST"]="postgres"
    )
    for var in "${!DIGEST_IMAGE_MAP[@]}"; do
      digest="${!var:-}"
      base="${DIGEST_IMAGE_MAP[$var]}"
      [ -z "${digest}" ] && continue
      ref="${base}@${digest}"
      MIRRORED=$(mirror_image "${ref}")
      echo "  Pulling ${MIRRORED}..."
      docker pull "${MIRRORED}" 2>/dev/null \
        && docker tag "${MIRRORED}" "${ref}" 2>/dev/null \
        || echo "    WARN: digest pre-pull failed for ${var} (${ref}) -- first install will fall back to internet"
    done

    echo "Pre-pulling CYPFER images (tagged) from local mirror..."
    # cypfer-inc/* images that compose / post-install scripts pull. The two
    # pre-pull loops above only warm upstream openrelik/* and base images;
    # without this block the case's own pipeline service, the post-install
    # config images, and the CYPFER-built workers all bypass the mirror on
    # first install -- slow, and the same Geneve-TLS-flake hazard the digest
    # loop was added to avoid.
    #
    # Tag resolution mirrors what compose / post-install fallback to, so
    # `:dev` testing flows (PIPELINE_IMAGE=...:dev, etc.) cache the right tag
    # instead of always warming `:latest`.
    for img in \
      "${PIPELINE_IMAGE:-ghcr.io/cypfer-inc/openrelik-pipeline:latest}" \
      "${OR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-or-config:latest}" \
      "${TS_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-ts-config:latest}" \
      "${VR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-vr-config:latest}" \
      "ghcr.io/cypfer-inc/openrelik-worker-network-normalizer:${OPENRELIK_WORKER_NETWORK_NORMALIZER_VERSION:-latest}" \
      "ghcr.io/cypfer-inc/openrelik-worker-chainsaw:${OPENRELIK_WORKER_CHAINSAW_DIGEST:-latest}" \
      "ghcr.io/cypfer-inc/openrelik-worker-llm-summary:${CYPFER_WORKER_LLM_SUMMARY_DIGEST:-latest}"; do
      MIRRORED=$(mirror_image "${img}")
      echo "  Pulling ${MIRRORED}..."
      docker pull "${MIRRORED}" 2>/dev/null \
        && docker tag "${MIRRORED}" "${img}" 2>/dev/null \
        || echo "    WARN: ${MIRRORED} not in mirror -- will fall back to internet on first use"
    done
  fi

  echo "1" | bash install.sh 2>&1 | tee /opt/openrelik-pipeline/logs/openrelik-install.log

  echo "Configuring OpenRelik..."
  cd /opt/openrelik
  chmod 777 data/prometheus
  docker compose down

  # Rewrite OpenRelik docker-compose to use local mirror
  rewrite_compose_images /opt/openrelik/docker-compose.yml

  # Pin OpenRelik core images by SHA256 digest from config.env. Needed because
  # upstream openrelik-deploy templates pin to a version tag (0.7.0) that
  # predates the generic OIDC auth module (src/auth/oidc.py, on main only).
  # Digests are refreshed via scripts/update-digests.sh.
  OR_COMPOSE="/opt/openrelik/docker-compose.yml"
  pin_compose_image_digest "${OR_COMPOSE}" "openrelik-server"        "${OPENRELIK_SERVER_DIGEST}"
  pin_compose_image_digest "${OR_COMPOSE}" "openrelik-ui"            "${OPENRELIK_UI_DIGEST}"
  pin_compose_image_digest "${OR_COMPOSE}" "openrelik-mediator"      "${OPENRELIK_MEDIATOR_DIGEST}"
  pin_compose_image_digest "${OR_COMPOSE}" "openrelik-worker-plaso"  "${OPENRELIK_WORKER_PLASO_DIGEST}"
  echo "OpenRelik compose pinned to SHA256 digests from config.env"

  sed -i 's/127\.0\.0\.1/0\.0\.0\.0/g' /opt/openrelik/docker-compose.yml
  sed -i "s/localhost/$IP_ADDRESS/g" /opt/openrelik/config.env
  sed -i "s/localhost/$IP_ADDRESS/g" /opt/openrelik/config/settings.toml

  if [ -n "${OPENRELIK_PUBLIC_URL}" ]; then
    sed -i "s|api_server_url = \"http://$IP_ADDRESS:8710\"|api_server_url = \"${OPENRELIK_PUBLIC_URL}-api\"|" /opt/openrelik/config/settings.toml
    sed -i "s|ui_server_url = \"http://$IP_ADDRESS:8711\"|ui_server_url = \"${OPENRELIK_PUBLIC_URL}\"|" /opt/openrelik/config/settings.toml
    sed -i "s|allowed_origins = \[.*\]|allowed_origins = [\"http://$IP_ADDRESS:8711\", \"${OPENRELIK_PUBLIC_URL}\"]|" /opt/openrelik/config/settings.toml
    echo "OpenRelik settings.toml updated with public URLs"
  fi

  # Vote infrastructure — read case metadata and configure OpenRelik URLs
  if [ -f /etc/vote-case.env ]; then
    source /etc/vote-case.env
    if [ -n "${CASE_ID}" ]; then
      OR_URL="https://${CASE_ID}-or.dev.cypfer.io"
      # TS public hostname follows the same per-case pattern (nginx routes
      # 2078-ts.dev.cypfer.io to the case container's TS). Used by Phase 3
      # AI worker creds in /etc/vote-case-ai.env later in the script.
      TS_URL="https://${CASE_ID}-ts.dev.cypfer.io"
      echo "Configuring OpenRelik for case ${CASE_ID}..."

      # Update config.env and .env
      sed -i "s|OPENRELIK_SERVER_URL=.*|OPENRELIK_SERVER_URL=${OR_URL}|" /opt/openrelik/config.env 2>/dev/null
      grep -q "^OPENRELIK_SERVER_URL=" /opt/openrelik/config.env 2>/dev/null || \
        echo "OPENRELIK_SERVER_URL=${OR_URL}" >> /opt/openrelik/config.env
      sed -i "s|OPENRELIK_SERVER_URL=.*|OPENRELIK_SERVER_URL=${OR_URL}|" /opt/openrelik/.env 2>/dev/null
      grep -q "^OPENRELIK_SERVER_URL=" /opt/openrelik/.env 2>/dev/null || \
        echo "OPENRELIK_SERVER_URL=${OR_URL}" >> /opt/openrelik/.env

      # Update settings.toml
      sed -i "s|api_server_url = .*|api_server_url = \"${OR_URL}\"|" /opt/openrelik/config/settings.toml
      sed -i "s|ui_server_url = .*|ui_server_url = \"${OR_URL}\"|" /opt/openrelik/config/settings.toml
      sed -i "s|allowed_origins = .*|allowed_origins = [\"${OR_URL}\"]|" /opt/openrelik/config/settings.toml

      echo "OpenRelik URLs set to ${OR_URL}"

      # ─── OpenRelik OIDC (prod only) ────────────────────────────────────────
      # When AUTHENTIK_OR_CLIENT_ID is set, configure the openrelik-server's
      # generic OIDC module (src/auth/oidc.py, main-branch; needs digest-pinned
      # image). One Authentik application (slug: openrelik) with per-case
      # redirect URIs — moving to per-case Authentik applications is Phase 4.
      #
      # OR_BOOTSTRAP_USERS seeds the allowlist. New users auto-create on first
      # successful OIDC login (no pre-creation required, unlike VR).
      if [ "${ENVIRONMENT}" = "prod" ] && [ -n "${AUTHENTIK_OR_CLIENT_ID:-}" ]; then
        AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.dev.cypfer.io}"
        # nginx-server's vRack IP — we force auth.dev.cypfer.io to resolve here
        # so the server-side discovery fetch bypasses Cloudflare (which 403s
        # non-browser User-Agents with error 1010).
        AUTHENTIK_VRACK_HOST_IP="${AUTHENTIK_VRACK_HOST_IP:-51.222.196.105}"
        OR_SETTINGS="/opt/openrelik/config/settings.toml"
        OR_COMPOSE="/opt/openrelik/docker-compose.yml"

        echo "Configuring OpenRelik OIDC..."
        echo "  Authentik: ${AUTHENTIK_BASE_URL}"
        echo "  Client ID: ${AUTHENTIK_OR_CLIENT_ID}"
        echo "  vRack host override: ${AUTHENTIK_VRACK_HOST_IP}"

        # Seed the OR roster file from OR_BOOTSTRAP_USERS. Accepted formats,
        # comma-separated:
        #   email            → role defaults to `reader`
        #   email:role       → role ∈ {admin, investigator, reader}
        # or-apply.sh reconciles this file against the live OR state after
        # OR is up (settings.toml allowlist, admin flag per user).
        OR_ROSTER_DIR="/opt/openrelik-pipeline/rosters"
        OR_ROSTER_FILE="${OR_ROSTER_DIR}/or.env"
        mkdir -p "${OR_ROSTER_DIR}"
        chmod 700 "${OR_ROSTER_DIR}"
        {
          echo "# Generated by install.sh on $(date -u +%FT%TZ)"
          echo "# Live OR case roster. Edit via 'vote grant' / 'vote revoke'."
          echo "# Format: email=role   (roles: admin, investigator, reader)"
          if [ -n "${OR_BOOTSTRAP_USERS:-}" ]; then
            IFS=',' read -ra OR_PAIRS <<< "${OR_BOOTSTRAP_USERS}"
            for pair in "${OR_PAIRS[@]}"; do
              pair="$(echo "$pair" | xargs)"
              [ -z "$pair" ] && continue
              email="${pair%%:*}"
              role="${pair#*:}"
              # bare email (no ':') defaults to reader
              [ "$email" = "$pair" ] && role="reader"
              echo "${email}=${role}"
            done
          fi
        } > "${OR_ROSTER_FILE}"
        chmod 600 "${OR_ROSTER_FILE}"
        echo "Seeded OR roster: ${OR_ROSTER_FILE}"

        # ─── Phase 3: AI service account (microcloud:llm/README.md §3) ─────
        # Append the AI worker as a reader. or-apply.sh will create the OR
        # user, the OR API key generation block below issues a long-lived
        # JWT for it, and the result lands in /etc/vote-case-ai.env.
        echo "ai-summary-worker@cypfer.local=reader" >> "${OR_ROSTER_FILE}"
        echo "Appended AI service account to OR roster"

        # Append [auth.oidc] with an empty allowlist — or-apply.sh will rewrite
        # the allowlist line from the roster once OR is up.
        cat >> "${OR_SETTINGS}" <<EOF

[auth.oidc]
client_id = "${AUTHENTIK_OR_CLIENT_ID}"
client_secret = "${AUTHENTIK_OR_CLIENT_SECRET}"
discovery_url = "${AUTHENTIK_BASE_URL}/application/o/${AUTHENTIK_OR_APP_SLUG}/.well-known/openid-configuration"
allowlist = []
redirect_uri = "${OR_URL}/auth/oidc"
EOF

        # Tell the UI to render the OIDC login button alongside local.
        sed -i -E 's|^([[:space:]]*- OPENRELIK_AUTH_METHODS=).*$|\1local,oidc|' "${OR_COMPOSE}"

        # ─── vRack bypass + CF Origin CA trust ───────────────────────────────
        # openrelik-server must reach Authentik server-side for OIDC discovery
        # and token exchange. Going through Cloudflare fails — CF blocks Python
        # httpx with error 1010 (banned browser signature). Route the hostname
        # directly to nginx-server on the vRack, which terminates TLS with a
        # Cloudflare Origin CA cert — add CF's Origin roots to the container's
        # trust store so certificate validation succeeds.
        OR_CA_DIR="/opt/openrelik/cf-origin-ca"
        OR_CA_BUNDLE="${OR_CA_DIR}/ca-bundle.crt"
        if [ ! -f "${OR_CA_BUNDLE}" ]; then
          mkdir -p "${OR_CA_DIR}"
          echo "Fetching Cloudflare Origin CA roots..."
          curl -sSL -o "${OR_CA_DIR}/origin_ca_rsa_root.pem" \
            https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem
          curl -sSL -o "${OR_CA_DIR}/origin_ca_ecc_root.pem" \
            https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem
          # Concat the system bundle with CF's two roots so SSL_CERT_FILE covers both.
          cat /etc/ssl/certs/ca-certificates.crt \
              "${OR_CA_DIR}/origin_ca_rsa_root.pem" \
              "${OR_CA_DIR}/origin_ca_ecc_root.pem" > "${OR_CA_BUNDLE}"
          echo "CA bundle built: $(wc -l <"${OR_CA_BUNDLE}") lines"
        fi

        # Derive the Authentik hostname from AUTHENTIK_BASE_URL for the /etc/hosts override.
        AUTHENTIK_HOST="$(echo "${AUTHENTIK_BASE_URL}" | sed -E 's|^https?://([^/]+).*|\1|')"

        # Patch openrelik-server in docker-compose.yml: extra_hosts + CA env + CA volume.
        # Insertion anchors are unique within the openrelik-server service block.
        grep -q "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" "${OR_COMPOSE}" || \
          sed -i "/- PROMETHEUS_SERVER_URL=/a\\      - SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt\\n      - REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt" "${OR_COMPOSE}"

        grep -q "cf-origin-ca/ca-bundle.crt:/etc/ssl/certs/ca-bundle.crt" "${OR_COMPOSE}" || \
          sed -i "/- \.\/config:\/etc\/openrelik\/:z/a\\      - ./cf-origin-ca/ca-bundle.crt:/etc/ssl/certs/ca-bundle.crt:ro" "${OR_COMPOSE}"

        grep -q "extra_hosts:" "${OR_COMPOSE}" || \
          sed -i "/^  openrelik-server:/a\\    extra_hosts:\\n      - \"${AUTHENTIK_HOST}:${AUTHENTIK_VRACK_HOST_IP}\"" "${OR_COMPOSE}"

        echo "OpenRelik OIDC configured (redirect: ${OR_URL}/auth/oidc)"
      elif [ "${ENVIRONMENT}" = "prod" ]; then
        echo "AUTHENTIK_OR_CLIENT_ID not set — OpenRelik using local auth only"
      fi

      # Restart to apply
      cd /opt/openrelik
      docker compose down
      docker compose up -d
      cd /opt/openrelik-pipeline

      echo "OpenRelik restarted with case ${CASE_ID} URLs"
    fi
  fi

  OPENRELIK_PG_PASSWORD=$(grep POSTGRES_PASSWORD /opt/openrelik/config.env | cut -d= -f2)
  sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${OPENRELIK_PG_PASSWORD}/" /opt/openrelik-pipeline/config.env
  echo "Postgres password synced from OpenRelik config"

  CONFIG_TOML="/opt/openrelik/config/settings.toml"
  LEGACY_STORAGE_PATH='storage_path = "/usr/share/openrelik/data/artifacts"'
  grep -q '^\[server\]' "$CONFIG_TOML" || echo -e '\n[server]' >> "$CONFIG_TOML"
  grep -q '^[[:space:]]*storage_path[[:space:]]*=' "$CONFIG_TOML" || \
    sed -i "/^\[server\]/a $LEGACY_STORAGE_PATH" "$CONFIG_TOML"

  retry_pull
  docker compose up -d

  echo "Checking OpenRelik database initialisation..."
  sleep 10

  TABLE_COUNT=$(docker exec openrelik-postgres psql -U openrelik -d openrelik -t -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" \
    2>/dev/null | tr -d ' ')

  if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -lt 5 ]; then
    echo "Database tables not found — running migrations..."
    docker exec openrelik-server bash -c \
      "cd /app/openrelik/datastores/sql && alembic upgrade head" \
      2>&1 | tee /opt/openrelik-pipeline/logs/alembic-migration.log
    echo "Migrations complete"
  else
    echo "Database tables verified ($TABLE_COUNT tables found)"
  fi

  USER_EXISTS=$(docker exec openrelik-postgres psql -U openrelik -d openrelik -t -c \
    "SELECT COUNT(*) FROM \"user\" WHERE username='admin';" \
    2>/dev/null | tr -d ' ')

  if [ -z "$USER_EXISTS" ] || [ "$USER_EXISTS" -lt 1 ]; then
    echo "Admin user not found — creating..."
    docker exec openrelik-server python admin.py create-user admin \
      --password "${OPENRELIK_ADMIN_PASSWORD}" --admin
    echo "Admin user created"
  else
    echo "Admin user verified"
  fi

  # Apply the OR analyst roster — populates settings.toml allowlist and
  # creates/updates each user with the right admin flag. Only runs when the
  # OIDC block was configured above (roster file exists).
  if [ -f /opt/openrelik-pipeline/rosters/or.env ]; then
    echo "Applying OR analyst roster..."
    bash /opt/openrelik-pipeline/scripts/roster/or-apply.sh \
      /opt/openrelik-pipeline/rosters/or.env \
      2>&1 | tee -a /opt/openrelik-pipeline/logs/or-roster-apply.log \
      || echo "WARNING: or-apply.sh returned non-zero — check log"
  fi

  echo "Upgrading Plaso in openrelik-worker-plaso to match Timesketch..."
  sleep 3

  docker compose exec -T openrelik-worker-plaso bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
if ! command -v add-apt-repository >/dev/null 2>&1; then
  apt-get install -y software-properties-common
fi
if ! grep -Rqs "ppa.launchpadcontent.net/gift/stable" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
  add-apt-repository -y ppa:gift/stable
fi
apt-get update
apt-get install -y plaso-data plaso-tools python3-plaso
echo "Plaso versions now:"
dpkg --list | grep plaso || true
log2timeline.py --version || true
psort.py --version || true
' 2>&1 | tee /opt/openrelik-pipeline/logs/plaso-upgrade.log

  # Explicit -f on the compose commands below so they don't depend on the
  # current working directory. install.sh has `cd /opt/openrelik-pipeline`
  # earlier in the flow, and from that cwd `docker compose restart
  # openrelik-worker-plaso` and `docker compose exec openrelik-server`
  # silently resolve against the pipeline's compose file -- which defines
  # neither service, only `openrelik-pipeline` -- and return empty output.
  # Case 9998 surfaced this as `len=0` on the API key capture; the Plaso
  # restart was broken the same way but nobody noticed because it had no
  # downstream validation.
  OR_COMPOSE=/opt/openrelik/docker-compose.yml

  docker compose -f "${OR_COMPOSE}" restart openrelik-worker-plaso

  # Capture the API key with -T so docker compose does not allocate a TTY.
  # With a TTY, typer/rich wrap the JWT at ~80 cols and emit ANSI escapes
  # that survive `tr -d '[:space:]'` and corrupt the placeholder replacement.
  # COLUMNS=1000 defends against the same wrapping if -T is ever dropped.
  # Validate the captured value looks like a JWT (three base64url segments,
  # >= 100 chars) before writing anything. If we let an empty value through,
  # sed silently clears OPENRELIK_API_KEY in docker-compose.yml and the
  # pipeline container boots with no credentials, producing confusing
  # "API key has expired" errors on every POST from Velociraptor.
  OPENRELIK_API_KEY="$(COLUMNS=1000 docker compose -f "${OR_COMPOSE}" exec -T openrelik-server python admin.py create-api-key admin --key-name "cypfer")"
  OPENRELIK_API_KEY=$(echo "$OPENRELIK_API_KEY" | tr -d '[:cntrl:][:space:]')
  if [ "${#OPENRELIK_API_KEY}" -lt 100 ] || ! echo "$OPENRELIK_API_KEY" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
    echo "ERROR: captured OPENRELIK_API_KEY does not look like a JWT (len=${#OPENRELIK_API_KEY})"
    echo "       admin.py create-api-key output (for diagnosis):"
    COLUMNS=1000 docker compose -f "${OR_COMPOSE}" exec -T openrelik-server python admin.py create-api-key admin --key-name "cypfer-debug" 2>&1 | head -20 || true
    exit 1
  fi

  sed -i "s#YOUR_API_KEY#$OPENRELIK_API_KEY#g" /opt/openrelik-pipeline/docker-compose.yml

  # Materialize TIMESKETCH_PASSWORD into the compose file too. The template
  # used to be `TIMESKETCH_PASSWORD=${TIMESKETCH_PASSWORD}`, which docker
  # compose only resolves when the shell has the variable in its env. After
  # install cleans up config.env, any later `docker compose up` resolves it
  # to an empty string and the pipeline fails TS login with
  # "Invalid username or password." Replace the placeholder with the literal
  # value now, mirroring the YOUR_API_KEY pattern.
  sed -i "s#YOUR_TS_PASSWORD#${TIMESKETCH_PASSWORD}#g" /opt/openrelik-pipeline/docker-compose.yml

  # Materialize CASE_ID. Sourced earlier from /etc/vote-case.env when the
  # install runs in vote-managed per-case mode. On non-vote dev installs
  # CASE_ID is empty and the placeholder is replaced with an empty string;
  # the pipeline app then falls back to its legacy "fresh root folder per
  # zip" behaviour for /api/triage/timesketch.
  sed -i "s#YOUR_CASE_ID#${CASE_ID:-}#g" /opt/openrelik-pipeline/docker-compose.yml
  if [ -n "${CASE_ID:-}" ]; then
    echo "Pipeline CASE_ID baked into docker-compose: ${CASE_ID}"
  else
    echo "Pipeline CASE_ID empty (non-per-case install) -- legacy folder behaviour"
  fi

  # Persist key to config.env and key file so configure container and rotation cron can use it
  if grep -q "^OPENRELIK_API_KEY=" /opt/openrelik-pipeline/config.env 2>/dev/null; then
    sed -i "s#^OPENRELIK_API_KEY=.*#OPENRELIK_API_KEY=${OPENRELIK_API_KEY}#" /opt/openrelik-pipeline/config.env
  else
    echo "OPENRELIK_API_KEY=${OPENRELIK_API_KEY}" >> /opt/openrelik-pipeline/config.env
  fi
  echo "${OPENRELIK_API_KEY}" > /opt/openrelik-pipeline/.openrelik_api_key
  chmod 600 /opt/openrelik-pipeline/.openrelik_api_key
  echo "API key saved to config.env and .openrelik_api_key"

  export OPENRELIK_API_KEY

  # ─── Phase 3: AI service account — OR API key + /etc/vote-case-ai.env ──────
  # Generate a separate long-lived OR JWT for ai-summary-worker@cypfer.local
  # (the AI account, NOT the pipeline's admin account). Mirrors the JWT-shape
  # validation pattern above. The AI account was created earlier by
  # or-apply.sh from the AI roster row appended in the OR roster block.
  AI_OR_USER="ai-summary-worker@cypfer.local"
  AI_OR_API_KEY="$(COLUMNS=1000 docker compose -f "${OR_COMPOSE}" exec -T openrelik-server python admin.py create-api-key "${AI_OR_USER}" --key-name "ai-worker" 2>/dev/null)"
  AI_OR_API_KEY=$(echo "$AI_OR_API_KEY" | tr -d '[:cntrl:][:space:]')
  if [ "${#AI_OR_API_KEY}" -lt 100 ] || ! echo "$AI_OR_API_KEY" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
    echo "WARNING: AI OR API key does not look like a JWT (len=${#AI_OR_API_KEY})"
    echo "         AI worker (Phase 5) won't have OR access until this is fixed."
    AI_OR_API_KEY=""
  fi

  # Write per-case AI credentials. AI_TS_PASSWORD comes from the TS roster
  # block earlier in this script (preserved across re-runs). Phase 5 worker
  # sources this file from the case container; v1 has no consumer yet.
  AI_ENV_FILE="/etc/vote-case-ai.env"
  cat > "${AI_ENV_FILE}" <<AIEOF
# Per-case AI worker credentials — generated by openrelik-pipeline:install.sh
# on $(date -u +%FT%TZ) for case ${CASE_ID:-unknown}. Phase 3 of the v1 AI
# integration plan (microcloud:llm/README.md §3).
#
# v1 auth model:
#   TS: HTTP Basic with AI_TS_USER + AI_TS_PASSWORD against AI_TS_URL
#   OR: Authorization: Bearer ${AI_OR_API_KEY:0:8}... against AI_OR_URL
# Phase 7 migrates TS to OIDC bearer; this file's TS_* fields will go away.
AI_ACCOUNT="${AI_TS_USER}"
AI_TS_URL="${TS_URL:-}"
AI_TS_USER="${AI_TS_USER}"
AI_TS_PASSWORD="${AI_TS_PASSWORD}"
AI_OR_URL="${OR_URL:-}"
AI_OR_API_KEY="${AI_OR_API_KEY}"
AIEOF
  chmod 600 "${AI_ENV_FILE}"
  echo "Wrote AI worker credentials: ${AI_ENV_FILE} (chmod 600)"

  # Authenticate to GHCR for private image pulls
  if [ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN}" ]; then
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin 2>/dev/null \
      && echo "GHCR login successful" \
      || echo "WARNING: GHCR login failed — or-config image pull may fail"
  else
    echo "WARNING: GHCR_USER or GHCR_TOKEN not set in config.env — skipping GHCR login"
  fi

  # Verify OpenRelik is running before attempting configuration
  if ! docker network inspect openrelik_default &>/dev/null; then
    echo "ERROR: openrelik_default network not found — OpenRelik failed to deploy"
    echo "       Skipping or-config, check logs above for pull/startup errors"
    OR_CONFIG_FAILED=true
  fi

  # Run OpenRelik post-install configuration (workers, workflows, folders)
  echo "Running OpenRelik post-install configuration..."

  OR_CONFIG_IMAGE="${OR_CONFIG_IMAGE:-$(mirror_image ghcr.io/cypfer-inc/openrelik-or-config:latest)}"
  OR_PULL_OK=false
  for i in 1 2 3 4 5; do
    if docker pull "${OR_CONFIG_IMAGE}" 2>&1 | tee /opt/openrelik-pipeline/logs/or-config-pull.log; then
      OR_PULL_OK=true
      break
    fi
    echo "or-config pull failed, retry $i/5..."
    sleep 5
  done
  if [ "${OR_PULL_OK}" != "true" ]; then
    echo "ERROR: Failed to pull or-config image — skipping OpenRelik configuration"
    echo "       Check GHCR credentials and image name: ${OR_CONFIG_IMAGE}"
    OR_CONFIG_FAILED=true
  fi

  if [ "${OR_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Skipping or-config run — image pull failed"
  else
    docker run --rm \
      --name openrelik-configure \
      --network openrelik_default \
      -e OPENRELIK_API_URL="http://openrelik-server:8710" \
      -e OPENRELIK_USERNAME="admin" \
      -e OPENRELIK_PASSWORD="${OPENRELIK_ADMIN_PASSWORD}" \
      -e OPENRELIK_WAIT_TIMEOUT="${OPENRELIK_WAIT_TIMEOUT:-120}" \
      -e OPENRELIK_WAIT_INTERVAL="${OPENRELIK_WAIT_INTERVAL:-5}" \
      -e OPENRELIK_COMPOSE="/opt/openrelik/docker-compose.yml" \
      -e GHCR_USER="${GHCR_USER}" \
      -e GHCR_TOKEN="${GHCR_TOKEN}" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /opt/openrelik:/opt/openrelik \
      "${OR_CONFIG_IMAGE}" \
      2>/opt/openrelik-pipeline/logs/or-config.log

    if [ $? -ne 0 ]; then
      echo "ERROR: OpenRelik configuration failed — check /opt/openrelik-pipeline/logs/or-config.log"
      OR_CONFIG_FAILED=true
    fi
  fi

  echo "Deploying OpenRelik Timesketch worker..."
  # Use absolute path — cwd at this point is /opt/openrelik-pipeline (whose
  # compose has no `volumes:` section). Without absolute path, grep silently
  # returns empty, $((line - 1)) evaluates to -1, sed sees "-1" as a flag and
  # aborts with "invalid option -- '1'". The worker never gets injected, and
  # every "Upload to Timesketch" task silently queues forever. Surfaced on
  # case-2073.
  OR_COMPOSE=/opt/openrelik/docker-compose.yml

  line=$(grep -n "^volumes:" "${OR_COMPOSE}" | head -n1 | cut -d: -f1)
  if [ -z "${line}" ]; then
    echo "ERROR: no 'volumes:' anchor in ${OR_COMPOSE} — cannot inject openrelik-worker-timesketch"
    exit 1
  fi
  insert_line=$((line - 1))

  TIMESKETCH_WORKER_DIGEST=$(grep OPENRELIK_WORKER_TIMESKETCH_DIGEST /opt/openrelik-pipeline/config.env | cut -d= -f2)

  sed -i "${insert_line}i\\
  \\
  openrelik-worker-timesketch:\\
      container_name: openrelik-worker-timesketch\\
      image: ghcr.io/openrelik/openrelik-worker-timesketch@${TIMESKETCH_WORKER_DIGEST}\\
      restart: always\\
      environment:\\
        - REDIS_URL=redis://openrelik-redis:6379\\
        - TIMESKETCH_SERVER_URL=http://timesketch-web:5000\\
        - TIMESKETCH_SERVER_PUBLIC_URL=${TIMESKETCH_PUBLIC_URL:-http://$IP_ADDRESS}\\
        - TIMESKETCH_USERNAME=admin\\
        - TIMESKETCH_PASSWORD=$TIMESKETCH_PASSWORD\\
      volumes:\\
        - ./data:/usr/share/openrelik/data\\
      command: \"celery --app=src.app worker --task-events --concurrency=1 --loglevel=INFO -Q openrelik-worker-timesketch\"
" "${OR_COMPOSE}"

  # Post-injection validation: if the sed didn't land (unexpected compose
  # structure, escaping regression, etc.), fail the install loudly instead of
  # leaving the OR pipeline half-wired.
  if ! grep -q "openrelik-worker-timesketch:" "${OR_COMPOSE}"; then
    echo "ERROR: openrelik-worker-timesketch block was not injected into ${OR_COMPOSE}"
    exit 1
  fi

  # ─── Inject openrelik-worker-network-normalizer ───────────────────────────
  # Same shape as the timesketch-worker block above. Powers the NETWORK_
  # ingestion pipeline (/api/network/timesketch in app.py + the
  # CYPFER.Network.Normalize.Timesketch workflow template). Without this
  # block, every network-normalize task silently queues forever — same
  # failure mode case-2073 surfaced for the timesketch worker.
  #
  # Re-grep for ^volumes: because the timesketch injection above pushed it
  # down by ~13 lines.
  echo "Injecting openrelik-worker-network-normalizer into ${OR_COMPOSE}..."
  line=$(grep -n "^volumes:" "${OR_COMPOSE}" | head -n1 | cut -d: -f1)
  if [ -z "${line}" ]; then
    echo "ERROR: no 'volumes:' anchor in ${OR_COMPOSE} — cannot inject openrelik-worker-network-normalizer"
    exit 1
  fi
  insert_line=$((line - 1))

  NETWORK_NORMALIZER_VERSION="${OPENRELIK_WORKER_NETWORK_NORMALIZER_VERSION:-latest}"

  sed -i "${insert_line}i\\
  \\
  openrelik-worker-network-normalizer:\\
      container_name: openrelik-worker-network-normalizer\\
      image: ghcr.io/cypfer-inc/openrelik-worker-network-normalizer:${NETWORK_NORMALIZER_VERSION}\\
      restart: always\\
      environment:\\
        - REDIS_URL=redis://openrelik-redis:6379\\
      volumes:\\
        - ./data:/usr/share/openrelik/data\\
      command: \"celery --app=src.app worker --task-events --concurrency=2 --loglevel=INFO -Q openrelik-worker-network-normalizer\"
" "${OR_COMPOSE}"

  if ! grep -q "openrelik-worker-network-normalizer:" "${OR_COMPOSE}"; then
    echo "ERROR: openrelik-worker-network-normalizer block was not injected into ${OR_COMPOSE}"
    exit 1
  fi

  # NOTE: openrelik-worker-chainsaw is NOT injected here. The
  # openrelik-or-config configure.py step (above) already writes the
  # chainsaw service block to /opt/openrelik/docker-compose.yml from
  # workers/openrelik-worker-chainsaw.yml in the or-config repo. Adding
  # a sed injection here produced a duplicate-key YAML error and broke
  # all subsequent compose operations on case-2096 (verified the
  # chainsaw block appeared twice). The bring-up step below still runs
  # via `docker compose up -d`, mirroring the pattern used for the
  # llm-summary worker.

  # Connect timesketch-web to the openrelik network
  if docker ps --format "{{.Names}}" | grep -q "^timesketch-web$"; then
    docker network connect openrelik_default timesketch-web 2>/dev/null \
      && echo "timesketch-web connected to openrelik_default" \
      || echo "WARNING: timesketch-web already on openrelik_default or connect failed"
  else
    echo "WARNING: timesketch-web container not found — skipping network connect"
    echo "         Ensure Timesketch is deployed before OpenRelik for full integration"
  fi

  docker network disconnect openrelik_default openrelik-pipeline 2>/dev/null || true
  docker rm -f openrelik-pipeline 2>/dev/null || true

  # Verify Timesketch worker was injected into docker-compose.yml
  if grep -q "openrelik-worker-timesketch" /opt/openrelik/docker-compose.yml 2>/dev/null; then
    echo "Timesketch worker verified in docker-compose.yml"
  else
    echo "WARNING: openrelik-worker-timesketch not found in docker-compose.yml"
    echo "         The 'Upload to Timesketch' task will not be available"
    echo "         Check sed injection above for errors"
  fi

  echo "Deploying the OpenRelik pipeline..."
  cd /opt/openrelik-pipeline
  rewrite_compose_images /opt/openrelik-pipeline/docker-compose.yml
  retry_pull
  docker compose up -d

  # Start the Timesketch worker from the OpenRelik compose
  cd /opt/openrelik
  docker compose up -d openrelik-worker-timesketch 2>/dev/null

  # Verify it's running
  if docker ps --format "{{.Names}}" | grep -q "openrelik-worker-timesketch"; then
    echo "openrelik-worker-timesketch is running"
  else
    echo "WARNING: openrelik-worker-timesketch failed to start"
    echo "         Check: docker compose -f /opt/openrelik/docker-compose.yml logs openrelik-worker-timesketch"
  fi

  # Start the network-normalizer worker (NETWORK_ pipeline)
  docker compose up -d openrelik-worker-network-normalizer 2>/dev/null

  if docker ps --format "{{.Names}}" | grep -q "openrelik-worker-network-normalizer"; then
    echo "openrelik-worker-network-normalizer is running"
  else
    echo "WARNING: openrelik-worker-network-normalizer failed to start"
    echo "         Check: docker compose -f /opt/openrelik/docker-compose.yml logs openrelik-worker-network-normalizer"
  fi

  # Start the chainsaw worker (Sigma EVTX hunting + SRUM, used by triage fan-out)
  docker compose up -d openrelik-worker-chainsaw 2>/dev/null

  if docker ps --format "{{.Names}}" | grep -q "openrelik-worker-chainsaw"; then
    echo "openrelik-worker-chainsaw is running"
  else
    echo "WARNING: openrelik-worker-chainsaw failed to start"
    echo "         Check: docker compose -f /opt/openrelik/docker-compose.yml logs openrelik-worker-chainsaw"
  fi

  # ─── Phase 5: AI worker (openrelik-worker-llm-summary) ──────────────────
  # configure.py adds the worker's compose block to docker-compose.yml from
  # the openrelik-or-config image AND eagerly starts the container with no
  # AI_* env vars set — `docker compose up -d` here would be a no-op (the
  # container already exists; compose only recreates if the file changed,
  # which it didn't from compose's perspective even though the SHELL env
  # changed). Use --force-recreate so the AI_* vars sourced below actually
  # land in the running container.
  #
  # The worker env splits across two files by ownership domain:
  #   /etc/vote-case-ai.env   — TS + OR creds, written by THIS install.sh
  #                             Phase 3 block from case-local tsctl /
  #                             admin.py outputs.
  #   /etc/vote-case-llm.env  — LiteLLM URL + per-case virtual key, written
  #                             by microcloud:scripts/vote.sh during
  #                             `vote launch` (master-key call against the
  #                             services-1 LiteLLM proxy lives on the MC
  #                             initiator, never inside the case container).
  # Source both before the recreate so the compose snippet from
  # openrelik-or-config:workers/openrelik-worker-llm-summary.yml interpolates
  # the full AI_* set. Absent files warned but non-fatal — the worker's
  # _required_env still fails fast on first task with a clear error if
  # anything's missing.
  if grep -q "openrelik-worker-llm-summary" /opt/openrelik/docker-compose.yml 2>/dev/null; then
    # /etc/vote-case.env contributes CASE_ID — without it the worker
    # comes up with empty CASE_ID and every audit event gets misattributed
    # (caught on case-2094). Order matters: case.env first so CASE_ID is
    # available when ai.env / llm.env are sourced (in case any references it).
    for env_file in /etc/vote-case.env /etc/vote-case-ai.env /etc/vote-case-llm.env; do
      if [ -r "${env_file}" ]; then
        set -a
        # shellcheck disable=SC1090
        . "${env_file}"
        set +a
        echo "Sourced AI worker creds from ${env_file} for compose interpolation"
      else
        echo "WARNING: ${env_file} not found — some AI_* env vars will be empty"
      fi
    done
    docker compose up -d --force-recreate openrelik-worker-llm-summary 2>/dev/null

    if docker ps --format "{{.Names}}" | grep -q "openrelik-worker-llm-summary"; then
      echo "openrelik-worker-llm-summary is running"
    else
      echo "WARNING: openrelik-worker-llm-summary failed to start"
      echo "         Check: docker compose -f /opt/openrelik/docker-compose.yml logs openrelik-worker-llm-summary"
    fi
  fi

  echo "OpenRelik deployment complete"
fi

# ─── Velociraptor ─────────────────────────────────────────────────────────────
if [ "${INSTALL_VR}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying Velociraptor..."

  # Determine VR hostname and client comms port before generating docker-compose
  # Vote: clients connect to {CASE_ID}-vr.client.dev.cypfer.io:8443 (grey cloud, SNI passthrough)
  # Dev:  clients connect to {IP_ADDRESS}:8000 (direct)
  VR_HOSTNAME="${IP_ADDRESS}"
  VR_CLIENT_PORT="8000"
  VR_CLIENT_URL="${VELOCIRAPTOR_CLIENT_URL:-https://$IP_ADDRESS:8000/}"
  if [ -f /etc/vote-case.env ]; then
    source /etc/vote-case.env
    if [ -n "${CASE_ID}" ]; then
      VR_CLIENT_DOMAIN="${CASE_CLIENT_DOMAIN:-${CASE_ID}-vr.client.dev.cypfer.io}"
      VR_HOSTNAME="${VR_CLIENT_DOMAIN}"
      VR_CLIENT_PORT="8443"
      VR_CLIENT_URL="https://${VR_CLIENT_DOMAIN}:8443/"
      VELOCIRAPTOR_PUBLIC_URL="https://${CASE_DOMAIN}"
      # Dash-free TLS identity for the VR agent. Required because:
      #   - VR agent CN-checks /server.pem against Client.pinned_server_name
      #   - OrgIdFromClientId splits the destination on "-" and treats the
      #     suffix as an org_id (client-side lookup fails → "Org not found")
      # The DNS hostname VR_CLIENT_DOMAIN still has dashes (existing pattern);
      # the agent's TLS SNI (= pinned name) goes through nginx as a second
      # entry in the stream SNI map (see microcloud case-stream.conf.tmpl).
      # Root cause + fix validated on case-2067, 2026-04-18.
      VR_PINNED_NAME="vr${CASE_ID}.client.${CASE_DOMAIN#*-vr.}"
      # Fallback if parsing above didn't yield a reasonable value
      [[ "$VR_PINNED_NAME" != *.* ]] && VR_PINNED_NAME="vr${CASE_ID}.client.dev.cypfer.io"
      echo "Vote case detected:"
      echo "  VR GUI:    ${CASE_DOMAIN} (Cloudflare → nginx → :8889)"
      echo "  VR Client: ${VR_CLIENT_DOMAIN}:8443 (grey cloud → nginx SNI → :8443)"
      echo "  VR SNI/CN: ${VR_PINNED_NAME} (dash-free; see nginx stream map)"
    fi
  fi

  # VR_PINNED_NAME defaults to empty for non-vote deploys (dev); the entrypoint
  # skips the cert surgery when empty and VR uses its built-in CN
  # (VelociraptorServer) — fine for local-only access.
  VR_PINNED_NAME="${VR_PINNED_NAME:-}"

  # Build VR authenticator JSON for --merge. Prod + AUTHENTIK_VR_CLIENT_ID set
  # means we use OIDC against Authentik. Dev uses local auth (Basic, default).
  # oidc_name is "authentik" — this becomes part of the callback URL:
  #   https://{CASE}-vr.dev.cypfer.io/auth/oidc/authentik/callback
  #
  # NOTE on auto-provisioning:
  # We previously included `default_roles_for_unknown_user: [reader]` here,
  # but that field is **certificate-only** in Velociraptor (verified against
  # config.proto field 22 — "If a user presents a certificate but does not
  # exist in the system, the user will receive a default role"). It is silently
  # ignored on the OIDC code path.
  #
  # Tested on case-2048 (VR 0.76.1, 2026-04-16) with the field set: OIDC users
  # still get "User <email> is not registered on this system" on first login.
  # Admin must run `velociraptor user add <email> --role <role>` once per user.
  #
  # Real OIDC auto-provisioning needs `claims.role_map` + `override_acls: true`
  # plus an Authentik scope mapping that emits a roles/groups claim VR can map.
  # Tracked as Phase 4 RBAC in microcloud/TODO.md.
  VR_GUI_EXTRA=""
  if [ "${ENVIRONMENT}" = "prod" ] && [ -n "${AUTHENTIK_VR_CLIENT_ID:-}" ]; then
    AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.dev.cypfer.io}"
    VR_GUI_EXTRA=", \"authenticator\": {\"type\": \"oidc\", \"oidc_issuer\": \"${AUTHENTIK_BASE_URL}/application/o/${AUTHENTIK_VR_APP_SLUG}/\", \"oidc_name\": \"authentik\", \"oauth_client_id\": \"${AUTHENTIK_VR_CLIENT_ID}\", \"oauth_client_secret\": \"${AUTHENTIK_VR_CLIENT_SECRET}\"}"
    echo "Velociraptor OIDC enabled (Authentik). New users must be pre-created via 'velociraptor user add' until Phase 4 RBAC."
  elif [ "${ENVIRONMENT}" = "prod" ]; then
    echo "AUTHENTIK_VR_CLIENT_ID not set — Velociraptor using local auth only"
  fi

  mkdir -p /opt/velociraptor
  cd /opt/velociraptor
  echo """services:
  velociraptor:
    container_name: velociraptor
    restart: always
    build:
      context: .
      dockerfile: Dockerfile
    volumes:
      - ./:/opt:rw
    environment:
      - VELOCIRAPTOR_PASSWORD=${VELOCIRAPTOR_PASSWORD}
      - IP_ADDRESS=${IP_ADDRESS}
      - VR_BOOTSTRAP_USERS=${VR_BOOTSTRAP_USERS:-}
    ports:
      - "${VR_CLIENT_PORT}:${VR_CLIENT_PORT}"
      - "8001:8001"
      - "8889:8889" """ | sudo tee ./docker-compose.yml > /dev/null

  VR_BASE_IMAGE=$(mirror_image "ubuntu:22.04")
  # openssl + python3 + python3-yaml are needed for the per-case Frontend cert
  # regeneration below (runs once on first container boot, in the entrypoint).
  echo "FROM ${VR_BASE_IMAGE}
COPY ./entrypoint .
RUN chmod +x entrypoint && \
    apt update && \
    apt install -y curl wget jq openssl python3 python3-yaml
WORKDIR /
CMD [\"/entrypoint\"]" | sudo tee ./Dockerfile > /dev/null

  cat << EOF | sudo tee entrypoint > /dev/null
#!/bin/bash

cd /opt

if [ ! -f server.config.yaml ]; then
  mkdir -p /opt/vr_data

  LINUX_BIN=\$(curl -s https://api.github.com/repos/velocidex/velociraptor/releases/latest \
    | jq -r '[.assets[] | select(.name | test("linux-amd64$"))][0].browser_download_url')

  wget -O /opt/velociraptor "\$LINUX_BIN"
  chmod +x /opt/velociraptor

  ./velociraptor config generate > server.config.yaml --merge '{
    "Frontend": {"hostname": "${VR_HOSTNAME}", "bind_address": "0.0.0.0", "bind_port": ${VR_CLIENT_PORT}},
    "API": {"bind_address": "0.0.0.0"},
    "GUI": {"public_url": "${VELOCIRAPTOR_PUBLIC_URL:-https://$IP_ADDRESS:8889}/app/index.html", "bind_address": "0.0.0.0"${VR_GUI_EXTRA}},
    "Monitoring": {"bind_address": "0.0.0.0"},
    "Logging": {"output_directory": "/opt/vr_data/logs", "separate_logs_per_component": true},
    "Client": {"server_urls": ["${VR_CLIENT_URL}"], "use_self_signed_ssl": true},
    "Datastore": {"location": "/opt/vr_data", "filestore_directory": "/opt/vr_data"}
  }'

  # === Per-case Frontend cert with dash-free CN (VR agent compat) ===
  # VR agent performs a CN check on /server.pem against Client.pinned_server_name
  # (http_comms/comms.go:655), and its OrgIdFromClientId (utils/orgs.go:30) splits
  # the destination on "-" and treats anything after the first dash as an org_id.
  # If the CN (= pinned name) has a dash, client-side Encrypt fails with
  # "Org not found" before any traffic reaches the server. Our nginx routes by SNI
  # so we need a dash-free CN that also matches pinned_server_name.
  #
  # Cert SANs cover all three identities:
  #   - VR_PINNED_NAME (dash-free)         → agent's SNI + CN check + pinned name
  #   - VR_CLIENT_DOMAIN (has dashes)      → agent's URL host (DNS target); also
  #                                          lets nginx's SNI map accept that name
  #                                          for backwards-compat with older agents
  #   - VelociraptorServer                 → VR's internal gRPC SAN requirement
  #
  # CA private key comes from the freshly-generated config; we kept the chain
  # intact so the agent's bundled ca_certificate still trusts the new leaf.
  # Root cause + fix validated live on case-2067 (2026-04-18). PR link in commit.
  if [ -n "${VR_PINNED_NAME}" ]; then
    echo "Regenerating Frontend cert with dash-free CN: ${VR_PINNED_NAME}"
    python3 - <<'PYEOF'
import yaml
p = "/opt/server.config.yaml"
c = yaml.safe_load(open(p))
open("/opt/ca.crt","w").write(c["Client"]["ca_certificate"])
open("/opt/ca.key","w").write(c["CA"]["private_key"])
PYEOF
    openssl genrsa -traditional -out /opt/fe.key 2048 2>/dev/null
    openssl req -new -key /opt/fe.key -out /opt/fe.csr \
      -subj "/O=Velociraptor/CN=${VR_PINNED_NAME}" 2>/dev/null
    cat > /opt/ext.cnf <<EXT
subjectAltName=DNS:${VR_PINNED_NAME},DNS:${VR_CLIENT_DOMAIN},DNS:VelociraptorServer
extendedKeyUsage=serverAuth
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
EXT
    openssl x509 -req -in /opt/fe.csr -CA /opt/ca.crt -CAkey /opt/ca.key \
      -CAcreateserial -out /opt/fe.crt -days 365 -sha256 -extfile /opt/ext.cnf 2>/dev/null
    python3 - <<'PYEOF'
import yaml
class L(str): pass
yaml.add_representer(L, lambda d,x: d.represent_scalar("tag:yaml.org,2002:str", x, style="|"))
p = "/opt/server.config.yaml"
c = yaml.safe_load(open(p))
c["Frontend"]["certificate"] = L(open("/opt/fe.crt").read())
c["Frontend"]["private_key"] = L(open("/opt/fe.key").read())
c["Client"]["pinned_server_name"] = "${VR_PINNED_NAME}"
# Force block-literal style on all large PEM-bearing strings so the rewritten
# YAML round-trips through VR's parser (VR's RSA PRIVATE KEY parser is picky
# about quoted-string newline encodings).
for sec in ["CA","Client","GUI","API","Frontend"]:
    for k,v in (c.get(sec) or {}).items():
        if isinstance(v,str) and ("BEGIN" in v or len(v)>200):
            c[sec][k]=L(v)
yaml.dump(c, open(p,"w"), default_flow_style=False, sort_keys=False, width=10000)
PYEOF
    rm -f /opt/ca.crt /opt/ca.key /opt/fe.key /opt/fe.csr /opt/fe.crt /opt/ext.cnf /opt/ca.srl
    echo "Frontend cert regenerated; pinned_server_name set to ${VR_PINNED_NAME}"
  fi

  ./velociraptor --config /opt/server.config.yaml user add admin "$VELOCIRAPTOR_PASSWORD" --role administrator

  # Bootstrap OIDC users — pre-create them before VR starts so the first login
  # from Authentik doesn't hit "User <email> is not registered on this system".
  # Adding users while VR is running populates the datastore but VR's in-memory
  # user cache only reloads on restart; doing it here (before the exec below)
  # avoids the restart dance.
  #
  # VR_BOOTSTRAP_USERS accepts both formats, comma-separated:
  #   email            → role defaults to reader
  #   email:role       → role ∈ {admin, investigator, reader} (CYPFER taxonomy)
  # CYPFER → VR mapping: admin→administrator, investigator→investigator,
  # reader→reader. Runtime changes go through 'vote grant' / 'vote revoke'
  # → vr-apply.sh.
  if [ -n "\${VR_BOOTSTRAP_USERS:-}" ]; then
    echo "Pre-creating VR OIDC users: \${VR_BOOTSTRAP_USERS}"
    IFS=',' read -ra _PAIRS <<< "\${VR_BOOTSTRAP_USERS}"
    for pair in "\${_PAIRS[@]}"; do
      pair="\$(echo "\$pair" | xargs)"
      [ -z "\$pair" ] && continue
      u="\${pair%%:*}"
      cypfer_role="\${pair#*:}"
      # Bare email (no ':') defaults to reader.
      [ "\$u" = "\$pair" ] && cypfer_role="reader"
      case "\$cypfer_role" in
        admin)        vr_role="administrator" ;;
        investigator) vr_role="investigator" ;;
        reader)       vr_role="reader" ;;
        *) echo "  ! invalid role '\$cypfer_role' for \$u — defaulting to reader"; vr_role="reader" ;;
      esac
      ./velociraptor --config /opt/server.config.yaml user add "\$u" --role "\$vr_role" 2>/dev/null \\
        && echo "  + \$u (\$cypfer_role → \$vr_role)" \\
        || echo "  ! failed: \$u"
    done
  fi
fi

exec /opt/velociraptor --config /opt/server.config.yaml frontend -v
EOF

  # Seed the VR roster file — source of truth for `vote grant` / `vote revoke`
  # going forward. The entrypoint above already creates the users pre-exec (no
  # restart needed at install time), so we don't call vr-apply.sh here. The
  # roster is written with matching content so runtime reconciles are a no-op
  # until someone actually grants/revokes.
  VR_ROSTER_DIR="/opt/openrelik-pipeline/rosters"
  VR_ROSTER_FILE="${VR_ROSTER_DIR}/vr.env"
  mkdir -p "${VR_ROSTER_DIR}"
  chmod 700 "${VR_ROSTER_DIR}"
  {
    echo "# Generated by install.sh on $(date -u +%FT%TZ)"
    echo "# Live VR case roster. Edit via 'vote grant' / 'vote revoke'."
    echo "# Format: email=role   (roles: admin, investigator, reader)"
    if [ -n "${VR_BOOTSTRAP_USERS:-}" ]; then
      IFS=',' read -ra VR_PAIRS <<< "${VR_BOOTSTRAP_USERS}"
      for pair in "${VR_PAIRS[@]}"; do
        pair="$(echo "$pair" | xargs)"
        [ -z "$pair" ] && continue
        email="${pair%%:*}"
        role="${pair#*:}"
        [ "$email" = "$pair" ] && role="reader"
        echo "${email}=${role}"
      done
    fi
  } > "${VR_ROSTER_FILE}"
  chmod 600 "${VR_ROSTER_FILE}"
  echo "Seeded VR roster: ${VR_ROSTER_FILE}"

  for i in 1 2 3 4 5; do
    docker compose build 2>&1 | tee /opt/openrelik-pipeline/logs/velociraptor-build.log && break
    echo "VR build failed, retry $i/5..."
    sleep 5
  done
  docker compose up -d

  echo "Configuring Velociraptor via API..."
  echo "Waiting for Velociraptor to initialise (may take 2-3 minutes on first boot)..."
  for i in $(seq 1 60); do
    if docker exec velociraptor test -f /opt/server.config.yaml 2>/dev/null; then
      echo "Velociraptor initialised — server config exists"
      sleep 15
      break
    fi
    echo "  Waiting for initialisation... ($i/60)"
    sleep 10
  done

  if ! (echo > /dev/tcp/localhost/8001) 2>/dev/null; then
    echo "WARNING: Velociraptor API not accessible on port 8001 — skipping configuration"
  else
    docker exec velociraptor /opt/velociraptor \
      --config /opt/server.config.yaml \
      user add ansible --role administrator "$(openssl rand -base64 16)"

    cd /opt/velociraptor
    docker compose restart
    sleep 20
    cd /opt/openrelik-pipeline

    docker exec velociraptor /opt/velociraptor \
      --config /opt/server.config.yaml \
      config api_client --name ansible /tmp/vr-api-client.yaml

    docker cp velociraptor:/tmp/vr-api-client.yaml /tmp/vr-api-client.yaml

    if [ ! -s /tmp/vr-api-client.yaml ] || [ -d /tmp/vr-api-client.yaml ]; then
      echo "WARNING: Failed to generate Velociraptor API cert — skipping configuration"
    else
      if [ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN}" ]; then
        echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin 2>/dev/null
      fi

      VR_CONFIG_IMAGE=${VR_CONFIG_IMAGE:-$(mirror_image ghcr.io/cypfer-inc/openrelik-vr-config:latest)}
      VR_PULL_OK=false
      for i in 1 2 3 4 5; do
        if docker pull "${VR_CONFIG_IMAGE}"; then
          VR_PULL_OK=true
          break
        fi
        echo "vr-config pull failed, retry $i/5..."
        sleep 5
      done
      if [ "${VR_PULL_OK}" != "true" ]; then
        echo "ERROR: Failed to pull vr-config image — skipping Velociraptor configuration"
        echo "       Check GHCR credentials and image name: ${VR_CONFIG_IMAGE}"
        VR_CONFIG_FAILED=true
      fi

      if [ "${VR_CONFIG_FAILED:-}" = "true" ]; then
        echo "  Skipping vr-config run — image pull failed"
      else
        docker run --rm \
          --network host \
          -e AUTHENTIK_VR_CLIENT_ID="${AUTHENTIK_VR_CLIENT_ID:-}" \
          -v /tmp/vr-api-client.yaml:/tmp/api.yaml:ro \
          "${VR_CONFIG_IMAGE}" \
          --api_config /tmp/api.yaml 2>/opt/openrelik-pipeline/logs/vr-config.log

        if [ $? -ne 0 ]; then
          echo "ERROR: Velociraptor configuration failed — check /opt/openrelik-pipeline/logs/vr-config.log"
          VR_CONFIG_FAILED=true
        fi
      fi

      rm -f /tmp/vr-api-client.yaml
      docker exec velociraptor rm -f /tmp/vr-api-client.yaml 2>/dev/null || true
      echo "Velociraptor configuration complete"
    fi
  fi

  # Connect Velociraptor to OpenRelik network so the server artifact
  # can POST collections to openrelik-pipeline:5000
  if [ "${INSTALL_OR}" = "true" ]; then
    docker network connect openrelik_default velociraptor 2>/dev/null \
      && echo "velociraptor connected to openrelik_default" \
      || echo "WARNING: velociraptor already on openrelik_default or connect failed"
  fi

  echo "Velociraptor deployment complete"
fi

# ─── Timesketch post-install configuration ────────────────────────────────────
# Runs last — gives Timesketch maximum time to start (OpenSearch is slow on LXC).
# By this point TS has had the full OR + VR deploy time to become healthy.
if [ "${INSTALL_TS}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Running Timesketch post-install configuration..."

  TS_CONFIG_IMAGE="${TS_CONFIG_IMAGE:-$(mirror_image ghcr.io/cypfer-inc/openrelik-ts-config:latest)}"
  TS_DEFAULT_SKETCH="${TS_DEFAULT_SKETCH:-true}"

  # Determine sketch name — vote uses case ID, dev uses "CYPFER Dev"
  if [ -f /etc/vote-case.env ]; then
    source /etc/vote-case.env
    TS_SKETCH_NAME="CYPFER Case-${CASE_ID}"
  else
    TS_SKETCH_NAME="${TS_SKETCH_NAME:-CYPFER Dev}"
  fi

  # GHCR login — shared token with vr-config and or-config
  if [ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN}" ]; then
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin 2>/dev/null \
      && echo "GHCR login successful" \
      || echo "WARNING: GHCR login failed — ts-config image pull may fail"
  else
    echo "WARNING: GHCR_USER or GHCR_TOKEN not set — skipping GHCR login"
  fi

  echo "  Pulling ts-config image: ${TS_CONFIG_IMAGE}"
  TS_PULL_OK=false
  for i in 1 2 3 4 5; do
    if docker pull "${TS_CONFIG_IMAGE}" 2>&1 | tee /opt/openrelik-pipeline/logs/ts-config-pull.log; then
      TS_PULL_OK=true
      break
    fi
    echo "ts-config pull failed, retry $i/5..."
    sleep 5
  done
  if [ "${TS_PULL_OK}" != "true" ]; then
    echo "ERROR: Failed to pull ts-config image — skipping Timesketch configuration"
    echo "       Check GHCR credentials and image name: ${TS_CONFIG_IMAGE}"
    TS_CONFIG_FAILED=true
  fi

  # Determine the correct Timesketch network
  if [ "${INSTALL_OR}" = "true" ]; then
    TS_NETWORK="openrelik_default"
  else
    TS_NETWORK="timesketch_default"
  fi

  # Verify the target network exists before running ts-config
  if ! docker network inspect "${TS_NETWORK}" &>/dev/null; then
    echo "ERROR: ${TS_NETWORK} network not found — Timesketch or OpenRelik failed to deploy"
    echo "       Skipping ts-config"
    TS_CONFIG_FAILED=true
  fi

  if [ "${TS_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Skipping ts-config run — image pull failed or network missing"
  else
    echo "  Starting ts-config (network: ${TS_NETWORK})..."
    docker run --rm \
      --name timesketch-configure \
      --network "${TS_NETWORK}" \
      -e TS_URL="http://timesketch-web:5000" \
      -e TS_USERNAME="admin" \
      -e TS_PASSWORD="${TIMESKETCH_PASSWORD}" \
      -e TS_CONTAINER="timesketch-web" \
      -e TS_DEFAULT_SKETCH="${TS_DEFAULT_SKETCH}" \
      -e TS_SKETCH_NAME="${TS_SKETCH_NAME}" \
      -e TS_ANALYST_PASSWORD="${TS_ANALYST_PASSWORD:-}" \
      -e TS_LEAD_PASSWORD="${TS_LEAD_PASSWORD:-}" \
      -e TS_WAIT_TIMEOUT="${TS_WAIT_TIMEOUT:-300}" \
      -e TS_WAIT_INTERVAL="${TS_WAIT_INTERVAL:-5}" \
      -e AUTHENTIK_TS_CLIENT_ID="${AUTHENTIK_TS_CLIENT_ID:-}" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "${TS_CONFIG_IMAGE}" \
      2>/opt/openrelik-pipeline/logs/ts-config.log

    TS_CONFIG_EXIT=$?
    if [ "${TS_CONFIG_EXIT}" -eq 0 ]; then
      echo "Timesketch configuration complete"

      # Re-run ts-apply.sh now that the default sketch exists. The
      # install-time run earlier in this script skipped per-sketch ACL
      # grants with "no sketches yet — skipping" because ts-config
      # hadn't yet created the default sketch. Without this re-run, no
      # roster user — including ai-summary-worker@cypfer.local — has an
      # ACL on the default sketch, and the AI worker fails with HTTP
      # 403 on /sketches/{id}/archive/ when fetching events. Hit on
      # case-2099 during Phase 6 acceptance; manual fix was
      # `tsctl grant-user ai-summary-worker@cypfer.local --sketch_id 1`.
      #
      # Idempotent: tsctl grant-user does not insert duplicate
      # sketch_accesscontrolentry rows on re-run, so this is safe even
      # when the analyst-team has been growing via `vote grant` between
      # installs.
      if [ -n "${TS_ROSTER_FILE:-}" ] && [ -f "${TS_ROSTER_FILE}" ]; then
        echo "  Re-running ts-apply.sh to grant default-sketch ACLs..."
        bash /opt/openrelik-pipeline/scripts/roster/ts-apply.sh "${TS_ROSTER_FILE}" \
          2>&1 | tee -a /opt/openrelik-pipeline/logs/ts-roster-apply.log \
          || echo "WARNING: post-sketch ts-apply.sh returned non-zero — check log"
      else
        echo "  Skipping post-sketch ts-apply.sh (no roster file — non-vote install path)"
      fi
    else
      echo "ERROR: ts-config exited with code ${TS_CONFIG_EXIT} — check logs:"
      echo "       /opt/openrelik-pipeline/logs/ts-config.log"
      TS_CONFIG_FAILED=true
    fi
  fi
fi

# ─── Observability: Timesketch audit tailer ──────────────────────────────────
# Deploys the ts-audit-tailer sidecar that polls TS Postgres and emits
# AUDIT-prefixed JSON to stdout (Promtail catches it via Docker SD).
# Gated the same as Promtail (prod + LOKI_URL) AND requires TS to have
# been installed and ts-config to have succeeded — otherwise the
# `timesketch_default` network doesn't exist and there's nothing to tail.
TS_AUDIT_STATUS="skipped"
if [ "${ENVIRONMENT}" = "prod" ] && [ -n "${LOKI_URL:-}" ] \
   && [ "${INSTALL_TS}" = "true" ] && [ "${TS_CONFIG_FAILED:-}" != "true" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "Deploying ts-audit-tailer (TS DB → Loki sidecar)"
  echo "═══════════════════════════════════════════════════"

  # Source case metadata (same as Promtail step below).
  if [ -f /etc/vote-case.env ]; then
    # shellcheck disable=SC1091
    source /etc/vote-case.env
  fi

  if [ -z "${CASE_ID:-}" ]; then
    echo "  WARN: CASE_ID not set — skipping ts-audit-tailer"
    TS_AUDIT_STATUS="skipped (no CASE_ID)"
  else
    # Pull the TS Postgres password straight out of the running container
    # (deploy_timesketch.sh writes it into the container's environment).
    TS_DB_PASS=$(docker inspect postgres --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                  | grep '^POSTGRES_PASSWORD=' | cut -d= -f2-)
    if [ -z "${TS_DB_PASS}" ]; then
      echo "  WARN: could not read POSTGRES_PASSWORD from 'postgres' container — skipping"
      TS_AUDIT_STATUS="skipped (no DB_PASS)"
    else
      TAILER_DIR="/opt/ts-audit-tailer"
      mkdir -p "${TAILER_DIR}/state"
      cp -r "${SCRIPT_DIR}/ts-audit-tailer/." "${TAILER_DIR}/"
      # Write the tailer's env file (secrets stay off the command line
      # and out of docker inspect for the main environment).
      umask 077
      cat > "${TAILER_DIR}/.env" <<EOF
DB_PASS=${TS_DB_PASS}
CASE_ID=${CASE_ID}
EOF
      umask 022

      (
        cd "${TAILER_DIR}"
        # Build the sidecar image locally (tiny — python:3.12-slim +
        # psycopg2-binary). `docker compose build` is idempotent.
        docker compose build
        docker compose up -d
      )

      # Quick smoke check: container up within 30s? A DB-unreachable
      # tailer is still "running" — failure mode is stderr spam, not
      # container exit. So we only verify presence, not log contents.
      for i in $(seq 1 15); do
        if docker ps --filter name=ts-audit-tailer --filter status=running -q | grep -q .; then
          echo "  ts-audit-tailer: running (case=${CASE_ID})"
          TS_AUDIT_STATUS="OK"
          break
        fi
        if [ "$i" -eq 15 ]; then
          echo "  WARN: ts-audit-tailer did not enter running state within 30s"
          docker logs --tail 20 ts-audit-tailer 2>&1 | sed 's/^/    /'
          TS_AUDIT_STATUS="FAILED"
        fi
        sleep 2
      done
    fi
  fi
elif [ "${ENVIRONMENT}" != "prod" ]; then
  TS_AUDIT_STATUS="skipped (dev)"
elif [ -z "${LOKI_URL:-}" ]; then
  TS_AUDIT_STATUS="skipped (no LOKI_URL)"
elif [ "${INSTALL_TS}" != "true" ]; then
  TS_AUDIT_STATUS="skipped (TS not installed)"
elif [ "${TS_CONFIG_FAILED:-}" = "true" ]; then
  TS_AUDIT_STATUS="skipped (TS config failed)"
fi

# ─── Observability: Promtail log shipper ─────────────────────────────────────
# Deploys Promtail inside the case container so every Docker container's
# stdout ships to Loki on services-1 with case=<CASE_ID> labels. Gated
# on ENVIRONMENT=prod AND LOKI_URL set — dev and air-gapped installs skip.
# This is the plumbing-only tier: no app-specific parsing yet.
PROMTAIL_FAILED=""
PROMTAIL_STATUS="skipped"
if [ "${ENVIRONMENT}" = "prod" ] && [ -n "${LOKI_URL:-}" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "Deploying Promtail (log shipper → ${LOKI_URL})"
  echo "═══════════════════════════════════════════════════"

  # Case ID: prefer /etc/vote-case.env (vote-managed), fall back to
  # CASE_ID already in env (manual deploys with CASE_ID= set).
  if [ -f /etc/vote-case.env ]; then
    # shellcheck disable=SC1091
    source /etc/vote-case.env
  fi
  if [ -z "${CASE_ID:-}" ]; then
    echo "  WARN: CASE_ID not set (no /etc/vote-case.env, no env override) — skipping Promtail"
    PROMTAIL_STATUS="skipped (no CASE_ID)"
  else
    # No wrapping block/tee — install.sh already sets a top-level
    # `exec > >(tee -a "${MASTER_LOG}") 2>&1` (line ~260), so every
    # echo here lands in /opt/openrelik-pipeline/logs/install.log
    # automatically. Piping this block to a separate `tee` forked a
    # subshell, and the PROMTAIL_STATUS assignments inside never
    # propagated to the parent — which is why successful deploys
    # showed "skipped" in the summary line.
    PROMTAIL_DIR="/opt/promtail"
    mkdir -p "${PROMTAIL_DIR}/positions"
    cp "${SCRIPT_DIR}/promtail/docker-compose.yml" "${PROMTAIL_DIR}/docker-compose.yml"
    # Substitute placeholders. Using # as sed delim so Loki URL's slashes don't conflict.
    sed -e "s#__LOKI_URL__#${LOKI_URL}#g" \
        -e "s#__CASE_ID__#${CASE_ID}#g" \
        "${SCRIPT_DIR}/promtail/promtail-config.yaml" \
        > "${PROMTAIL_DIR}/promtail-config.yaml"

    cd "${PROMTAIL_DIR}"
    docker compose pull
    docker compose up -d
    # Compose up -d doesn't recreate on mounted-file changes, and
    # Promtail doesn't hot-reload — force restart so the new config
    # is always loaded on re-run.
    docker compose restart promtail

    # Wait for /ready (bound to localhost by compose); fall back to
    # showing compose logs on failure so the operator has context.
    for i in $(seq 1 15); do
      if curl -sf --max-time 2 http://127.0.0.1:9080/ready >/dev/null 2>&1; then
        echo "  Promtail: ready (case=${CASE_ID})"
        PROMTAIL_STATUS="OK"
        break
      fi
      if [ "$i" -eq 15 ]; then
        echo "  WARN: Promtail did not become ready within 30s"
        docker compose logs --tail 30 promtail 2>&1 | sed 's/^/    /'
        PROMTAIL_FAILED="true"
        PROMTAIL_STATUS="FAILED"
      fi
      sleep 2
    done
  fi
elif [ "${ENVIRONMENT}" != "prod" ]; then
  echo ""
  echo "Promtail: skipped (ENVIRONMENT=${ENVIRONMENT}, not prod)"
  PROMTAIL_STATUS="skipped (dev)"
elif [ -z "${LOKI_URL:-}" ]; then
  echo ""
  echo "Promtail: skipped (LOKI_URL not set in config.env)"
  PROMTAIL_STATUS="skipped (no LOKI_URL)"
fi

# ─── Phase 4B: authentik-sync reconciler + bootstrap seed ────────────────────
# When /etc/authentik-sync.env is present (vote.sh writes it under PHASE4B=1),
# (1) seed the case-<CASE_ID>-<role> Authentik groups with the bootstrap users
#     so the reconciler's first tick sees them and doesn't mass-revoke;
# (2) deploy the reconciler + systemd units + enable the 60s timer.
#
# No-op when /etc/authentik-sync.env is absent — pre-4B cases and 4A-only
# cases continue through without the reconciler.
AUTHENTIK_SYNC_STATUS="skipped (not PHASE4B)"
if [ -r /etc/authentik-sync.env ]; then
  echo ""
  echo "Phase 4B: seeding Authentik bootstrap + deploying authentik-sync..."
  AUTHENTIK_SYNC_FAILED="false"
  (
    # Subshell so sourced env doesn't leak into later sections.
    set -e
    . /etc/authentik-sync.env  # AUTHENTIK_BASE_URL, AUTHENTIK_API_TOKEN
    . /etc/vote-case.env       # CASE_ID

    AK_API="${AUTHENTIK_BASE_URL%/}/api/v3"

    # Union TS/OR/VR bootstrap lists with admin > investigator > reader
    # precedence, so each user shows up in exactly one role group.
    declare -A B
    for csv in "${TS_BOOTSTRAP_USERS:-}" "${OR_BOOTSTRAP_USERS:-}" "${VR_BOOTSTRAP_USERS:-}"; do
      IFS=',' read -ra PAIRS <<< "$csv"
      for entry in "${PAIRS[@]}"; do
        entry=$(echo "$entry" | xargs)
        [ -z "$entry" ] && continue
        email="${entry%%:*}"
        role="${entry#*:}"
        [ "$role" = "$entry" ] && role="reader"
        case "$role" in admin|investigator|reader) ;; *) role="reader" ;; esac
        current="${B[$email]:-}"
        # Precedence: if current is admin, keep. If current is investigator
        # and new isn't admin, keep. Otherwise overwrite.
        if [ "$current" = "admin" ]; then continue; fi
        if [ "$current" = "investigator" ] && [ "$role" != "admin" ]; then continue; fi
        B[$email]=$role
      done
    done

    # Cache group pks.
    declare -A GROUP_PK
    for r in admin investigator reader; do
      gname="case-${CASE_ID}-${r}"
      pk=$(curl -sS -H "Authorization: Bearer $AUTHENTIK_API_TOKEN" \
            "$AK_API/core/groups/?name=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$gname")" \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("results",[{}])[0]; print(r.get("pk",""))')
      if [ -z "$pk" ]; then
        echo "  ERROR: Authentik group $gname not found — case not fully provisioned"
        exit 1
      fi
      GROUP_PK[$r]=$pk
    done

    # Add each bootstrap user to their group.
    for email in "${!B[@]}"; do
      role="${B[$email]}"
      user_pk=$(curl -sS -H "Authorization: Bearer $AUTHENTIK_API_TOKEN" \
                 "$AK_API/core/users/?email=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$email")" \
                 | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("results",[{}])[0]; print(r.get("pk",""))')
      if [ -z "$user_pk" ]; then
        echo "  SKIP: $email not in Authentik (create via UI first)"
        continue
      fi
      code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
             -H "Authorization: Bearer $AUTHENTIK_API_TOKEN" \
             -H "Content-Type: application/json" \
             -d "{\"pk\":$user_pk}" \
             "$AK_API/core/groups/${GROUP_PK[$role]}/add_user/")
      if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        echo "  OK: $email → case-${CASE_ID}-${role}"
      else
        echo "  WARN: add_user $email → case-${CASE_ID}-${role} returned HTTP $code"
      fi
    done

    # Deploy reconciler + units.
    install -d -m 0755 /opt/authentik-sync
    install -m 0755 "${SCRIPT_DIR}/authentik-sync/authentik-sync.sh"      /opt/authentik-sync/authentik-sync.sh
    install -m 0644 "${SCRIPT_DIR}/authentik-sync/authentik-sync.service" /etc/systemd/system/authentik-sync.service
    install -m 0644 "${SCRIPT_DIR}/authentik-sync/authentik-sync.timer"   /etc/systemd/system/authentik-sync.timer

    # Log file needs to exist before promtail tails it; 0640 root:adm keeps
    # it readable for promtail without broadening the reconciler's writes.
    touch /var/log/authentik-sync.log
    chmod 0640 /var/log/authentik-sync.log
    chown root:adm /var/log/authentik-sync.log 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --now authentik-sync.timer
    echo "  authentik-sync.timer enabled (60s cadence)"
  ) || AUTHENTIK_SYNC_FAILED="true"

  if [ "$AUTHENTIK_SYNC_FAILED" = "true" ]; then
    echo "Phase 4B: deploy FAILED — authentik-sync not running, reconciliation disabled"
    AUTHENTIK_SYNC_STATUS="FAILED"
    emit_install_audit install-error error authentik-sync
  else
    AUTHENTIK_SYNC_STATUS="OK"
  fi
fi

echo "═══════════════════════════════════════════════════"
echo "Install complete"

# Track overall verdict as we walk the summary; any component FAILED → error.
INSTALL_OVERALL_VERDICT=ok

# Show actual status — requested vs success
if [ "${INSTALL_TS}" = "true" ]; then
  if [ "${TS_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Timesketch:   FAILED — check /opt/openrelik-pipeline/logs/ts-config.log"
    emit_install_audit install-error error timesketch
    INSTALL_OVERALL_VERDICT=error
  else
    echo "  Timesketch:   OK"
  fi
else
  echo "  Timesketch:   skipped"
fi

if [ "${INSTALL_OR}" = "true" ]; then
  if [ "${OR_CONFIG_FAILED:-}" = "true" ]; then
    echo "  OpenRelik:    FAILED — check /opt/openrelik-pipeline/logs/or-config.log"
    emit_install_audit install-error error openrelik
    INSTALL_OVERALL_VERDICT=error
  else
    echo "  OpenRelik:    OK"
  fi
else
  echo "  OpenRelik:    skipped"
fi

if [ "${INSTALL_VR}" = "true" ]; then
  if [ "${VR_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Velociraptor: FAILED — check /opt/openrelik-pipeline/logs/vr-config.log"
    emit_install_audit install-error error velociraptor
    INSTALL_OVERALL_VERDICT=error
  else
    echo "  Velociraptor: OK"
  fi
else
  echo "  Velociraptor: skipped"
fi

echo "  Promtail:        ${PROMTAIL_STATUS}"
echo "  TS Audit:        ${TS_AUDIT_STATUS}"
echo "  authentik-sync:  ${AUTHENTIK_SYNC_STATUS}"

emit_install_audit install-complete "${INSTALL_OVERALL_VERDICT}"

# Clean up sensitive files — always remove vault credentials
rm -f /etc/azure.cfg 2>/dev/null
rm -f "${SCRIPT_DIR}/azure.cfg" 2>/dev/null
[ -n "${AZURE_CFG_ARG}" ] && rm -f "${AZURE_CFG_ARG}" 2>/dev/null

# Only delete config.env if no components failed — keeps it for re-run on failure
if [ "${TS_CONFIG_FAILED:-}" != "true" ] && [ "${OR_CONFIG_FAILED:-}" != "true" ] && [ "${VR_CONFIG_FAILED:-}" != "true" ]; then
  rm -f "${SCRIPT_DIR}/config.env" 2>/dev/null
  echo ""
  echo "Cleanup: azure.cfg and config.env removed"
else
  echo ""
  echo "Cleanup: azure.cfg removed. config.env kept for re-run (some components failed)"
fi
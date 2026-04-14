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
  # Usage: mirror_image "ghcr.io/openrelik/openrelik-server:0.7.0"
  # Returns: "51.222.196.105:5000/openrelik/openrelik-server:0.7.0" (if mirrored)
  #      or: "ghcr.io/openrelik/openrelik-server:0.7.0" (if no mirror)
  local image="$1"
  if [ -n "${REGISTRY_MIRROR:-}" ]; then
    # Strip the registry prefix (ghcr.io/, docker.io/library/, docker.io/, etc.)
    local path="${image#*/}"
    # Handle bare images (e.g. redis:8, ubuntu:22.04) — add library/ prefix
    if [[ "$image" != */* ]]; then
      path="library/${image}"
    fi
    echo "${REGISTRY_MIRROR}/${path}"
  else
    echo "$image"
  fi
}

rewrite_compose_images() {
  # Rewrite all image references in a docker-compose.yml to use the local mirror.
  # Usage: rewrite_compose_images /opt/openrelik/docker-compose.yml
  local compose_file="$1"
  if [ -z "${REGISTRY_MIRROR:-}" ]; then
    return
  fi
  echo "Rewriting image references to use local registry: ${REGISTRY_MIRROR}"
  # Rewrite ghcr.io/ references — but skip CYPFER images (small, change often, pull direct)
  sed -i "/cypfer-inc/!s|image: ghcr.io/|image: ${REGISTRY_MIRROR}/|g" "$compose_file"
  # Rewrite docker.io/ references (explicit)
  sed -i "s|image: docker.io/|image: ${REGISTRY_MIRROR}/|g" "$compose_file"
  # Rewrite bare images (redis:8, postgres:17, etc.) — add library/ prefix
  sed -i -E "s|image: (redis\|postgres\|ubuntu):|image: ${REGISTRY_MIRROR}/library/\1:|g" "$compose_file" 2>/dev/null
  # Rewrite prom/prometheus (not under library/)
  sed -i "s|image: prom/|image: ${REGISTRY_MIRROR}/prom/|g" "$compose_file"
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
set +a

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

# ─── Environment validation ───────────────────────────────────────────────────
ENVIRONMENT=${ENVIRONMENT:-dev}
echo "Environment: ${ENVIRONMENT}"

# Always capture install output to a log file — on LXC there's no terminal
# to scroll back through. tee sends to both console and log.
mkdir -p /opt/openrelik-pipeline/logs
MASTER_LOG="/opt/openrelik-pipeline/logs/install.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install starting — environment: ${ENVIRONMENT}" > "${MASTER_LOG}"
exec > >(tee -a "${MASTER_LOG}") 2>&1

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

  echo "Timesketch deployment complete"
  cd /opt
fi

# ─── OpenRelik ────────────────────────────────────────────────────────────────
if [ "${INSTALL_OR}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying OpenRelik..."
  cd /opt
  curl -s -O https://raw.githubusercontent.com/cypfer-inc/openrelik-deploy/main/docker/install.sh

  # Pre-pull OpenRelik images from local mirror before the deploy script runs
  if [ -n "${REGISTRY_MIRROR:-}" ]; then
    echo "Pre-pulling OpenRelik images from local mirror..."
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
  fi

  echo "1" | bash install.sh 2>&1 | tee /opt/openrelik-pipeline/logs/openrelik-install.log

  echo "Configuring OpenRelik..."
  cd /opt/openrelik
  chmod 777 data/prometheus
  docker compose down

  # Rewrite OpenRelik docker-compose to use local mirror
  rewrite_compose_images /opt/openrelik/docker-compose.yml

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

  docker compose restart openrelik-worker-plaso

  OPENRELIK_API_KEY="$(docker compose exec openrelik-server python admin.py create-api-key admin --key-name "cypfer")"
  OPENRELIK_API_KEY=$(echo "$OPENRELIK_API_KEY" | tr -d '[:space:]')
  sed -i "s#YOUR_API_KEY#$OPENRELIK_API_KEY#g" /opt/openrelik-pipeline/docker-compose.yml

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

  OR_CONFIG_IMAGE="${OR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-or-config:latest}"
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
  line=$(grep -n "^volumes:" docker-compose.yml | head -n1 | cut -d: -f1)
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
" docker-compose.yml

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
      echo "Vote case detected:"
      echo "  VR GUI:    ${CASE_DOMAIN} (Cloudflare → nginx → :8889)"
      echo "  VR Client: ${VR_CLIENT_DOMAIN}:8443 (grey cloud → nginx SNI → :8443)"
    fi
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
    ports:
      - "${VR_CLIENT_PORT}:${VR_CLIENT_PORT}"
      - "8001:8001"
      - "8889:8889" """ | sudo tee -a ./docker-compose.yml > /dev/null

  VR_BASE_IMAGE=$(mirror_image "ubuntu:22.04")
  echo "FROM ${VR_BASE_IMAGE}
COPY ./entrypoint .
RUN chmod +x entrypoint && \
    apt update && \
    apt install -y curl wget jq
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
    "GUI": {"public_url": "${VELOCIRAPTOR_PUBLIC_URL:-https://$IP_ADDRESS:8889}/app/index.html", "bind_address": "0.0.0.0"},
    "Monitoring": {"bind_address": "0.0.0.0"},
    "Logging": {"output_directory": "/opt/vr_data/logs", "separate_logs_per_component": true},
    "Client": {"server_urls": ["${VR_CLIENT_URL}"], "use_self_signed_ssl": true},
    "Datastore": {"location": "/opt/vr_data", "filestore_directory": "/opt/vr_data"}
  }'

  ./velociraptor --config /opt/server.config.yaml user add admin "$VELOCIRAPTOR_PASSWORD" --role administrator
fi

exec /opt/velociraptor --config /opt/server.config.yaml frontend -v
EOF

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

      VR_CONFIG_IMAGE=${VR_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-vr-config:latest}
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

  TS_CONFIG_IMAGE="${TS_CONFIG_IMAGE:-ghcr.io/cypfer-inc/openrelik-ts-config:latest}"
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
      -v /var/run/docker.sock:/var/run/docker.sock \
      "${TS_CONFIG_IMAGE}" \
      2>/opt/openrelik-pipeline/logs/ts-config.log

    TS_CONFIG_EXIT=$?
    if [ "${TS_CONFIG_EXIT}" -eq 0 ]; then
      echo "Timesketch configuration complete"
    else
      echo "ERROR: ts-config exited with code ${TS_CONFIG_EXIT} — check logs:"
      echo "       /opt/openrelik-pipeline/logs/ts-config.log"
      TS_CONFIG_FAILED=true
    fi
  fi
fi

echo "═══════════════════════════════════════════════════"
echo "Install complete"

# Show actual status — requested vs success
if [ "${INSTALL_TS}" = "true" ]; then
  if [ "${TS_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Timesketch:   FAILED — check /opt/openrelik-pipeline/logs/ts-config.log"
  else
    echo "  Timesketch:   OK"
  fi
else
  echo "  Timesketch:   skipped"
fi

if [ "${INSTALL_OR}" = "true" ]; then
  if [ "${OR_CONFIG_FAILED:-}" = "true" ]; then
    echo "  OpenRelik:    FAILED — check /opt/openrelik-pipeline/logs/or-config.log"
  else
    echo "  OpenRelik:    OK"
  fi
else
  echo "  OpenRelik:    skipped"
fi

if [ "${INSTALL_VR}" = "true" ]; then
  if [ "${VR_CONFIG_FAILED:-}" = "true" ]; then
    echo "  Velociraptor: FAILED — check /opt/openrelik-pipeline/logs/vr-config.log"
  else
    echo "  Velociraptor: OK"
  fi
else
  echo "  Velociraptor: skipped"
fi

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
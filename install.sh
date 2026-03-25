#!/bin/bash

# ─── Usage ────────────────────────────────────────────────────────────────────
# bash install.sh              — install everything (default)
# bash install.sh --all        — install everything
# bash install.sh --ts         — install Timesketch only
# bash install.sh --or         — install OpenRelik (requires Timesketch already installed)
# bash install.sh --vr         — install Velociraptor only
# bash install.sh --ts --or    — install Timesketch + OpenRelik
# bash install.sh --or --vr    — install OpenRelik + Velociraptor
# ─────────────────────────────────────────────────────────────────────────────

# ─── Parse arguments ──────────────────────────────────────────────────────────
INSTALL_TS=false
INSTALL_OR=false
INSTALL_VR=false

if [ $# -eq 0 ]; then
  INSTALL_TS=true
  INSTALL_OR=true
  INSTALL_VR=true
fi

for ARG in "$@"; do
  case "$ARG" in
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
    --help|-h)
      echo "Usage: bash install.sh [--ts] [--or] [--vr] [--all]"
      echo ""
      echo "  --ts   Install Timesketch and dependencies"
      echo "  --or   Install OpenRelik and dependencies (requires Timesketch)"
      echo "  --vr   Install Velociraptor and configure via API"
      echo "  --all  Install everything (default if no arguments given)"
      echo ""
      echo "Examples:"
      echo "  bash install.sh              # install all"
      echo "  bash install.sh --vr         # Velociraptor only"
      echo "  bash install.sh --ts --or    # Timesketch + OpenRelik"
      echo "  bash install.sh --or --vr    # OpenRelik + Velociraptor"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $ARG"
      echo "       Run bash install.sh --help for usage"
      exit 1
      ;;
  esac
done

echo "Install plan:"
echo "  Timesketch:   $INSTALL_TS"
echo "  OpenRelik:    $INSTALL_OR"
echo "  Velociraptor: $INSTALL_VR"
echo "─────────────────────────────────────────────────"

# ─── Pre-flight checks ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  echo "       Please contact your Admin for the latest"
  echo "       file and instructions"
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

mkdir -p /opt/openrelik-pipeline/logs

# ─── Environment validation ───────────────────────────────────────────────────
ENVIRONMENT=${ENVIRONMENT:-dev}
echo "Environment: ${ENVIRONMENT}"

if [ "${ENVIRONMENT}" = "prod" ]; then
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

if [ -n "${DOCKERHUB_USER}" ] && [ -n "${DOCKERHUB_TOKEN}" ]; then
  echo "Authenticating to Docker Hub..."
  echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USER}" --password-stdin || {
    echo "WARNING: Docker Hub login failed — may hit rate limits"
  }
fi

cd /opt

# ─── Timesketch ───────────────────────────────────────────────────────────────
if [ "${INSTALL_TS}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying Timesketch..."
  echo "Output is being logged, this may take 5-7 minutes"
  curl -s -O https://raw.githubusercontent.com/google/timesketch/master/contrib/deploy_timesketch.sh
  chmod 755 deploy_timesketch.sh
  (./deploy_timesketch.sh <<EOF
Y
N
EOF
  ) > /opt/openrelik-pipeline/logs/timesketch-install.log 2>&1

  cd timesketch

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

  echo "1" | bash install.sh 2>&1 | tee /opt/openrelik-pipeline/logs/openrelik-install.log

  echo "Configuring OpenRelik..."
  cd /opt/openrelik
  chmod 777 data/prometheus
  docker compose down
  sed -i 's/127\.0\.0\.1/0\.0\.0\.0/g' /opt/openrelik/docker-compose.yml
  sed -i "s/localhost/$IP_ADDRESS/g" /opt/openrelik/config.env
  sed -i "s/localhost/$IP_ADDRESS/g" /opt/openrelik/config/settings.toml

  if [ -n "${OPENRELIK_PUBLIC_URL}" ]; then
    sed -i "s|api_server_url = \"http://$IP_ADDRESS:8710\"|api_server_url = \"${OPENRELIK_PUBLIC_URL}-api\"|" /opt/openrelik/config/settings.toml
    sed -i "s|ui_server_url = \"http://$IP_ADDRESS:8711\"|ui_server_url = \"${OPENRELIK_PUBLIC_URL}\"|" /opt/openrelik/config/settings.toml
    sed -i "s|allowed_origins = \[.*\]|allowed_origins = [\"http://$IP_ADDRESS:8711\", \"${OPENRELIK_PUBLIC_URL}\"]|" /opt/openrelik/config/settings.toml
    echo "OpenRelik settings.toml updated with public URLs"
  fi

  OPENRELIK_PG_PASSWORD=$(grep POSTGRES_PASSWORD /opt/openrelik/config.env | cut -d= -f2)
  sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${OPENRELIK_PG_PASSWORD}/" /opt/openrelik-pipeline/config.env
  echo "Postgres password synced from OpenRelik config"

  CONFIG_TOML="/opt/openrelik/config/settings.toml"
  LEGACY_STORAGE_PATH='storage_path = "/usr/share/openrelik/data/artifacts"'
  grep -q '^\[server\]' "$CONFIG_TOML" || echo -e '\n[server]' >> "$CONFIG_TOML"
  grep -q '^[[:space:]]*storage_path[[:space:]]*=' "$CONFIG_TOML" || \
    sed -i "/^\[server\]/a $LEGACY_STORAGE_PATH" "$CONFIG_TOML"

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

  OPENRELIK_API_KEY="$(docker compose exec openrelik-server python admin.py create-api-key admin --key-name "demo")"
  OPENRELIK_API_KEY=$(echo "$OPENRELIK_API_KEY" | tr -d '[:space:]')
  sed -i "s#YOUR_API_KEY#$OPENRELIK_API_KEY#g" /opt/openrelik-pipeline/docker-compose.yml

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

  docker network connect openrelik_default timesketch-web
  docker compose up -d

  docker network disconnect openrelik_default openrelik-pipeline 2>/dev/null || true
  docker rm -f openrelik-pipeline 2>/dev/null || true

  echo "Deploying the OpenRelik pipeline..."
  cd /opt/openrelik-pipeline
  docker compose pull
  docker compose up -d

  echo "OpenRelik deployment complete"
fi

# ─── Velociraptor ─────────────────────────────────────────────────────────────
if [ "${INSTALL_VR}" = "true" ]; then
  echo "═══════════════════════════════════════════════════"
  echo "Deploying Velociraptor..."
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
      - "8000:8000"
      - "8001:8001"
      - "8889:8889" """ | sudo tee -a ./docker-compose.yml > /dev/null

  echo "FROM ubuntu:22.04
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
    "Frontend": {"hostname": "$IP_ADDRESS"},
    "API": {"bind_address": "0.0.0.0"},
    "GUI": {"public_url": "${VELOCIRAPTOR_PUBLIC_URL:-https://$IP_ADDRESS:8889}/app/index.html", "bind_address": "0.0.0.0"},
    "Monitoring": {"bind_address": "0.0.0.0"},
    "Logging": {"output_directory": "/opt/vr_data/logs", "separate_logs_per_component": true},
    "Client": {"server_urls": ["${VELOCIRAPTOR_CLIENT_URL:-https://$IP_ADDRESS:8000/}"], "use_self_signed_ssl": true},
    "Datastore": {"location": "/opt/vr_data", "filestore_directory": "/opt/vr_data"}
  }'

  ./velociraptor --config /opt/server.config.yaml user add admin "$VELOCIRAPTOR_PASSWORD" --role administrator
fi

exec /opt/velociraptor --config /opt/server.config.yaml frontend -v
EOF

  docker compose build 2>&1 | tee /opt/openrelik-pipeline/logs/velociraptor-build.log
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
      docker pull "${VR_CONFIG_IMAGE}"

      docker run --rm \
        --network host \
        -v /tmp/vr-api-client.yaml:/tmp/api.yaml:ro \
        "${VR_CONFIG_IMAGE}" \
        --api_config /tmp/api.yaml 2>&1 | tee /opt/openrelik-pipeline/logs/vr-config.log

      rm -f /tmp/vr-api-client.yaml
      docker exec velociraptor rm -f /tmp/vr-api-client.yaml 2>/dev/null || true
      echo "Velociraptor configuration complete"
    fi
  fi

  echo "Velociraptor deployment complete"
fi

echo "═══════════════════════════════════════════════════"
echo "Install complete"
echo "  Timesketch installed:   ${INSTALL_TS}"
echo "  OpenRelik installed:    ${INSTALL_OR}"
echo "  Velociraptor installed: ${INSTALL_VR}"

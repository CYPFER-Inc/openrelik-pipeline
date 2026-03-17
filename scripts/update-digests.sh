#!/usr/bin/env bash
# =============================================================================
# scripts/update-digests.sh
#
# Resolves the current SHA256 digest for every upstream image and writes
# them into config.env. Run this monthly or after any upstream release.
#
# USAGE:
#   bash scripts/update-digests.sh [--env-file path/to/config.env]
#
# REQUIREMENTS:
#   docker  (must be installed and running)
#   crane   (optional but preferred — faster, no pull required)
#           Install: go install github.com/google/go-containerregistry/cmd/crane@latest
#           Or:      brew install crane
#
# WORKFLOW:
#   1. Run this script
#   2. Review the diff: git diff config.env
#   3. Check upstream changelogs for each image that changed
#   3. Push to main — triggers scan-images.yml CVE scan automatically
#   5. Commit: git add config.env && git commit -m "chore: update image digests YYYY-MM-DD"
# =============================================================================

set -euo pipefail

ENV_FILE="${1:-config.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "⚠️  ${ENV_FILE} not found — copying from config.env.example"
  cp config.env.example "${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Resolve digest using crane (preferred) or docker inspect fallback
resolve_digest() {
  local image="$1"
  local digest=""

  if command -v crane &>/dev/null; then
    digest=$(crane digest "${image}" 2>/dev/null || true)
  fi

  if [[ -z "${digest}" ]]; then
    # Fallback: pull image and inspect
    echo "  (crane not found — pulling ${image} to resolve digest...)" >&2
    docker pull "${image}" --quiet >/dev/null 2>&1 || true
    digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null \
      | awk -F'@' '{print $2}' || true)
  fi

  echo "${digest}"
}

# Update a single KEY=value line in config.env
set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -q "^${key}=" "${file}"; then
    # Replace existing line
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    # Append if missing
    echo "${key}=${value}" >> "${file}"
  fi
}

# ---------------------------------------------------------------------------
# Image manifest
# Format: ENV_VAR_NAME  full-image-reference-with-tag
# ---------------------------------------------------------------------------
declare -A IMAGES=(
  # Tier 2 — OpenRelik core
  ["OPENRELIK_SERVER_DIGEST"]="ghcr.io/openrelik/openrelik-server:latest"
  ["OPENRELIK_MEDIATOR_DIGEST"]="ghcr.io/openrelik/openrelik-mediator:latest"
  ["OPENRELIK_UI_DIGEST"]="ghcr.io/openrelik/openrelik-ui:latest"

  # Tier 2 — OpenRelik workers
  ["OPENRELIK_WORKER_PLASO_DIGEST"]="ghcr.io/openrelik/openrelik-worker-plaso:latest"
  ["OPENRELIK_WORKER_TIMESKETCH_DIGEST"]="ghcr.io/openrelik/openrelik-worker-timesketch:latest"
  # Hayabusa runs inside the pipeline container — no separate image needed
  # ["OPENRELIK_WORKER_HAYABUSA_DIGEST"]="ghcr.io/openrelik/openrelik-worker-hayabusa:latest"
  # ["OPENRELIK_WORKER_EXTRACTION_DIGEST"]="ghcr.io/openrelik/openrelik-worker-extraction:latest" — not needed by DDI pipeline
  # ["OPENRELIK_WORKER_HASHER_DIGEST"]="ghcr.io/openrelik/openrelik-worker-hasher:latest" — no published image
  # ["OPENRELIK_WORKER_GREP_DIGEST"]="ghcr.io/openrelik/openrelik-worker-grep:latest" — no published image
  # ["OPENRELIK_WORKER_STRINGS_DIGEST"]="ghcr.io/openrelik/openrelik-worker-strings:latest" — no published image

  # Tier 3 — Infrastructure
  ["REDIS_DIGEST"]="redis:7-alpine"
  ["POSTGRES_DIGEST"]="postgres:14"

  # Third-party
  ["TIMESKETCH_DIGEST"]="us-docker.pkg.dev/osdfir-registry/timesketch/timesketch:latest"
  ["VELOCIRAPTOR_DIGEST"]="wlambert/velociraptor:latest"
)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Resolving image digests..."
echo "   Writing results to: ${ENV_FILE}"
echo "   $(date)"
echo "---------------------------------------------------------------"

UPDATED=0
FAILED=()

for env_var in "${!IMAGES[@]}"; do
  image="${IMAGES[$env_var]}"
  echo ""
  echo "  📦 ${image}"

  digest=$(resolve_digest "${image}")

  if [[ -z "${digest}" ]]; then
    echo "  ⚠️  Could not resolve digest for ${image} — skipping"
    FAILED+=("${image}")
    continue
  fi

  # Read old value for change detection
  old_value=$(grep "^${env_var}=" "${ENV_FILE}" | cut -d'=' -f2 || true)

  set_env_value "${env_var}" "${digest}" "${ENV_FILE}"

  if [[ "${old_value}" == "${digest}" ]]; then
    echo "  ✓  Unchanged: ${digest}"
  else
    echo "  ✅ Updated:   ${digest}"
    if [[ -n "${old_value}" ]]; then
      echo "     Was:       ${old_value}"
    fi
    UPDATED=$((UPDATED + 1))
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================="
echo "  Digest update complete — $(date +%Y-%m-%d)"
echo "  ${UPDATED} image(s) changed"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "  ⚠️  ${#FAILED[@]} failed to resolve:"
  for f in "${FAILED[@]}"; do
    echo "     - ${f}"
  done
fi
echo "======================================================="
echo ""
echo "Next steps:"
echo "  1. Review changes:      git diff ${ENV_FILE}"
echo "  2. Check changelogs for any images that changed"
echo "  3. Push:                git push origin main  (triggers CVE scan automatically)"
echo "  4. Commit:              git add ${ENV_FILE} && git commit -m 'chore: update image digests $(date +%Y-%m-%d)'"

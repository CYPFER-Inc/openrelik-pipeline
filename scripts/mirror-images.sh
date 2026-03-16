#!/usr/bin/env bash
# =============================================================================
# mirror-images.sh
# Pull all upstream openrelik Docker images and re-push them to your org's
# GitHub Container Registry (ghcr.io/YOUR-ORG/...).
#
# USAGE:
#   export TARGET_ORG="your-github-org"          # required
#   export GITHUB_TOKEN="ghp_xxxx"               # required - PAT with packages:write
#   bash scripts/mirror-images.sh
#
# OPTIONAL - pin to specific versions instead of latest:
#   export OPENRELIK_VERSION="2024.12.12"
#   export WORKER_VERSION="2024.12.12"
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
TARGET_ORG="${TARGET_ORG:?ERROR: Set TARGET_ORG env var to your GitHub org name}"
GITHUB_TOKEN="${GITHUB_TOKEN:?ERROR: Set GITHUB_TOKEN env var to a PAT with packages:write}"

OPENRELIK_VERSION="${OPENRELIK_VERSION:-latest}"
WORKER_VERSION="${WORKER_VERSION:-latest}"

SOURCE_ORG="openrelik"
REGISTRY="ghcr.io"

# ---------------------------------------------------------------------------
# Image manifest
# Format: "source-image-name:version  target-image-name"
# Leave target-image-name empty to keep the same name as source
# ---------------------------------------------------------------------------
declare -A IMAGES=(
  # Core OpenRelik stack (from openrelik org)
  ["openrelik-server:${OPENRELIK_VERSION}"]="openrelik-server"
  ["openrelik-mediator:${OPENRELIK_VERSION}"]="openrelik-mediator"
  ["openrelik-ui:${OPENRELIK_VERSION}"]="openrelik-ui"

  # Workers (from openrelik org)
  ["openrelik-worker-plaso:${WORKER_VERSION}"]="openrelik-worker-plaso"
  ["openrelik-worker-timesketch:${WORKER_VERSION}"]="openrelik-worker-timesketch"
  ["openrelik-worker-hayabusa:${WORKER_VERSION}"]="openrelik-worker-hayabusa"
  ["openrelik-worker-extraction:${WORKER_VERSION}"]="openrelik-worker-extraction"
  ["openrelik-worker-hasher:${WORKER_VERSION}"]="openrelik-worker-hasher"
  ["openrelik-worker-grep:${WORKER_VERSION}"]="openrelik-worker-grep"
  ["openrelik-worker-strings:${WORKER_VERSION}"]="openrelik-worker-strings"
)

# Third-party images referenced in the compose stack
# Format: "full-source-image"  "target-name-in-your-org"
declare -A THIRD_PARTY_IMAGES=(
  ["redis:7-alpine"]="redis"
  ["postgres:14"]="postgres"
)

# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------
echo "🔐 Logging in to ${REGISTRY} as ${TARGET_ORG}..."
echo "${GITHUB_TOKEN}" | docker login "${REGISTRY}" -u "${TARGET_ORG}" --password-stdin

# ---------------------------------------------------------------------------
# Mirror openrelik/* images
# ---------------------------------------------------------------------------
echo ""
echo "📦 Mirroring openrelik images → ${REGISTRY}/${TARGET_ORG}/..."
echo "---------------------------------------------------------------"

FAILED=()

for source_tag in "${!IMAGES[@]}"; do
  target_name="${IMAGES[$source_tag]}"
  source_image="${REGISTRY}/${SOURCE_ORG}/${source_tag}"
  # Extract the tag from source_tag (everything after the colon)
  tag="${source_tag##*:}"
  target_image="${REGISTRY}/${TARGET_ORG}/${target_name}:${tag}"

  echo ""
  echo "  ↓ Pulling  ${source_image}"
  if docker pull "${source_image}"; then
    echo "  ↑ Pushing  ${target_image}"
    docker tag "${source_image}" "${target_image}"
    docker push "${target_image}"

    # Also tag as latest if we pulled a dated version
    if [[ "${tag}" != "latest" ]]; then
      latest_target="${REGISTRY}/${TARGET_ORG}/${target_name}:latest"
      docker tag "${source_image}" "${latest_target}"
      docker push "${latest_target}"
      echo "  ✅ Also tagged as :latest"
    fi

    echo "  ✅ Done: ${target_image}"
  else
    echo "  ⚠️  FAILED to pull ${source_image} — skipping"
    FAILED+=("${source_image}")
  fi
done

# ---------------------------------------------------------------------------
# Mirror third-party images (optional - for air-gap / full control)
# ---------------------------------------------------------------------------
echo ""
echo "📦 Mirroring third-party base images → ${REGISTRY}/${TARGET_ORG}/..."
echo "---------------------------------------------------------------"

for source_image in "${!THIRD_PARTY_IMAGES[@]}"; do
  target_name="${THIRD_PARTY_IMAGES[$source_image]}"
  tag="${source_image##*:}"
  target_image="${REGISTRY}/${TARGET_ORG}/${target_name}:${tag}"

  echo ""
  echo "  ↓ Pulling  ${source_image}"
  if docker pull "${source_image}"; then
    docker tag "${source_image}" "${target_image}"
    docker push "${target_image}"
    echo "  ✅ Done: ${target_image}"
  else
    echo "  ⚠️  FAILED to pull ${source_image} — skipping"
    FAILED+=("${source_image}")
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================="
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "✅ All images mirrored successfully to ${REGISTRY}/${TARGET_ORG}/"
else
  echo "⚠️  Completed with ${#FAILED[@]} failure(s):"
  for f in "${FAILED[@]}"; do
    echo "   - ${f}"
  done
fi
echo "======================================================="
echo ""
echo "Next step: update your docker-compose.yml to use:"
echo "  image: ${REGISTRY}/${TARGET_ORG}/<image-name>:\${VERSION}"

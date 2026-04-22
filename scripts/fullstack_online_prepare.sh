#!/usr/bin/env bash
set -euo pipefail

# Online phase: pull/build everything needed for offline validation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${1:-offline-fullstack-bundle}"

mkdir -p "${BUNDLE_DIR}/images" "${BUNDLE_DIR}/artifacts"
PULL_TIMEOUT_SECONDS="${PULL_TIMEOUT_SECONDS:-300}"

pull_or_fail() {
  local image="$1"
  echo "Pulling ${image} (timeout ${PULL_TIMEOUT_SECONDS}s)..."
  if ! timeout "${PULL_TIMEOUT_SECONDS}" docker pull "${image}"; then
    echo "ERROR: failed to pull ${image} within timeout."
    exit 1
  fi
}

echo "[1/6] Pulling required images..."
pull_or_fail "redis:7.2-alpine"
pull_or_fail "ghcr.io/berriai/litellm:main-latest"
pull_or_fail "python:3.11-slim"

echo "[2/6] Building local images..."
docker build -t offline-ci-orchestrator:latest "${ROOT_DIR}/orchestrator"
docker build -t offline-mock-vllm:latest "${ROOT_DIR}/docker/mock-vllm"
docker build -t offline-ci-python:3.11 - <<'DOCKER'
FROM python:3.11-slim
RUN useradd -m -u 1000 ciuser
USER ciuser
WORKDIR /workspace
DOCKER

echo "[3/6] Exporting images to bundle..."
for image in \
  redis:7.2-alpine \
  ghcr.io/berriai/litellm:main-latest \
  python:3.11-slim \
  offline-ci-orchestrator:latest \
  offline-mock-vllm:latest \
  offline-ci-python:3.11
do
  safe_name="$(echo "${image}" | tr '/:' '__')"
  docker save "${image}" -o "${BUNDLE_DIR}/images/${safe_name}.tar"
done

echo "[4/6] Capturing wheel artifacts for orchestrator..."
python -m pip download -r "${ROOT_DIR}/orchestrator/requirements.txt" -d "${BUNDLE_DIR}/artifacts/wheels"

echo "[5/6] Capturing optional OpenCode binary (if present)..."
if command -v opencode >/dev/null 2>&1; then
  cp "$(command -v opencode)" "${BUNDLE_DIR}/artifacts/opencode"
  chmod +x "${BUNDLE_DIR}/artifacts/opencode"
  echo "OpenCode binary captured."
else
  echo "OpenCode not found on online machine; offline validation will use mock fixer."
fi

echo "[6/6] Packaging bundle..."
tar czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
echo "Bundle ready: ${BUNDLE_DIR}.tar.gz"

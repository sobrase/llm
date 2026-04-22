#!/usr/bin/env bash
set -euo pipefail

# Run this on a machine with internet access.
# It prepares a transferable bundle for offline installation.

BUNDLE_DIR="${1:-offline-bundle}"
mkdir -p "${BUNDLE_DIR}/images" "${BUNDLE_DIR}/models" "${BUNDLE_DIR}/wheels"

IMAGES=(
  "redis:7.2-alpine"
  "ghcr.io/berriai/litellm:main-latest"
  "vllm/vllm-openai:latest"
  "python:3.11-slim"
)

echo "[1/5] Pull docker images..."
for image in "${IMAGES[@]}"; do
  docker pull "${image}"
done

echo "[2/5] Build orchestrator image..."
docker build -t offline-ci-orchestrator:latest ./orchestrator

echo "[3/5] Export docker images..."
for image in "${IMAGES[@]}" "offline-ci-orchestrator:latest"; do
  safe_name="$(echo "${image}" | tr '/:' '__')"
  docker save "${image}" -o "${BUNDLE_DIR}/images/${safe_name}.tar"
done

echo "[4/5] Download Python wheels..."
python -m pip download -r orchestrator/requirements.txt -d "${BUNDLE_DIR}/wheels"

echo "[5/5] Model sync (example for local mirror path)..."
echo "Copy your Qwen model files into: ${BUNDLE_DIR}/models/Qwen2.5-Coder-32B-Instruct"
echo "Example with Python huggingface_hub on online machine:"
echo "  python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id=\"Qwen/Qwen2.5-Coder-32B-Instruct\", local_dir=\"${BUNDLE_DIR}/models/Qwen2.5-Coder-32B-Instruct\", local_dir_use_symlinks=False)'"

tar czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
echo "Bundle generated: ${BUNDLE_DIR}.tar.gz"

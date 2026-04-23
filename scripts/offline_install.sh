#!/usr/bin/env bash
set -euo pipefail

# Run this on the offline/air-gapped target.

BUNDLE_TAR="${1:?usage: offline_install.sh <offline-bundle.tar.gz>}"
TARGET_DIR="${2:-/opt/offline-agentic-ci}"

mkdir -p "${TARGET_DIR}"
tar xzf "${BUNDLE_TAR}" -C "${TARGET_DIR}"

BUNDLE_ROOT="$(find "${TARGET_DIR}" -maxdepth 2 -type d -name "offline-bundle" | head -n 1)"
if [[ -z "${BUNDLE_ROOT}" ]]; then
  echo "offline-bundle directory not found after extraction"
  exit 1
fi

echo "[1/5] Load docker images..."
for img in "${BUNDLE_ROOT}"/images/*.tar; do
  docker load -i "${img}"
done

echo "[2/5] Sync model files..."
mkdir -p "${TARGET_DIR}/models"
cp -r "${BUNDLE_ROOT}/models/"* "${TARGET_DIR}/models/" || true

echo "[3/5] Copy OpenCode air-gap artifacts (schema + npm tarball)..."
if [[ -d "${BUNDLE_ROOT}/opencode" ]]; then
  cp -a "${BUNDLE_ROOT}/opencode" "${TARGET_DIR}/opencode-airgap"
  echo "  -> ${TARGET_DIR}/opencode-airgap (see README-airgap.txt inside)"
else
  echo "  (no opencode/ in bundle; regenerate bundle with scripts/online_bundle.sh on an online host)"
fi

echo "[4/5] Prepare env file..."
if [[ ! -f "${TARGET_DIR}/.env" ]]; then
  cp .env.example "${TARGET_DIR}/.env"
  sed -i "s|^VLLM_HOST_MODELS_DIR=.*|VLLM_HOST_MODELS_DIR=${TARGET_DIR}/models|" "${TARGET_DIR}/.env"
  if [[ -d "${TARGET_DIR}/models/Qwen__Qwen3.5-122B-A10B" ]]; then
    sed -i "s|^VLLM_MODEL=.*|VLLM_MODEL=/models/Qwen__Qwen3.5-122B-A10B|" "${TARGET_DIR}/.env"
  else
    FIRST_MODEL_DIR="$(ls -1 "${TARGET_DIR}/models" | head -n 1 || true)"
    if [[ -n "${FIRST_MODEL_DIR}" ]]; then
      sed -i "s|^VLLM_MODEL=.*|VLLM_MODEL=/models/${FIRST_MODEL_DIR}|" "${TARGET_DIR}/.env"
    fi
  fi
  echo "Edit ${TARGET_DIR}/.env with your secrets and Gitea endpoints."
fi

echo "[5/5] Deploy stack..."
cp docker-compose.yml "${TARGET_DIR}/docker-compose.yml"
cp -r docker orchestrator scripts docs "${TARGET_DIR}/"
if [[ -d .opencode ]]; then
  cp -a .opencode "${TARGET_DIR}/"
fi
cd "${TARGET_DIR}"
chmod +x scripts/*.sh docker/vllm/start-vllm.sh
docker compose --env-file .env up -d

echo "Offline CI stack deployed in ${TARGET_DIR}"

#!/usr/bin/env bash
set -euo pipefail

# Install a model bundle on an offline target host.
# Usage:
#   ./install_models_offline.sh <bundle.tar.gz> [TARGET_MODELS_DIR]

BUNDLE_TAR="${1:?usage: install_models_offline.sh <bundle.tar.gz> [TARGET_MODELS_DIR]}"
TARGET_MODELS_DIR="${2:-/opt/offline-agentic-ci/models}"

mkdir -p "${TARGET_MODELS_DIR}"
tar xzf "${BUNDLE_TAR}" -C "${TARGET_MODELS_DIR}"

echo "Models installed in: ${TARGET_MODELS_DIR}"
echo "Set these env vars in your stack .env:"
echo "  VLLM_HOST_MODELS_DIR=${TARGET_MODELS_DIR}"
echo "  VLLM_MODEL=/models/<one_of_dirs_below>"
echo ""
echo "Available model dirs:"
for d in "${TARGET_MODELS_DIR}"/*; do
  [[ -d "${d}" ]] && echo "  - ${d}"
done

#!/usr/bin/env bash
set -euo pipefail

# Package downloaded model snapshots into a transferable archive.
# Usage:
#   ./build_offline_models_bundle.sh [MODELS_DIR] [OUT_TAR_GZ]

MODELS_DIR="${1:-../offline-bundle/models}"
OUT_TAR_GZ="${2:-./offline-models-bundle.tar.gz}"

if [[ ! -d "${MODELS_DIR}" ]]; then
  echo "ERROR: models dir not found: ${MODELS_DIR}"
  exit 1
fi

tar czf "${OUT_TAR_GZ}" -C "${MODELS_DIR}" .
echo "Bundle created: ${OUT_TAR_GZ}"

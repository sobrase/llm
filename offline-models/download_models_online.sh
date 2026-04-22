#!/usr/bin/env bash
set -euo pipefail

# Download model snapshots from Hugging Face on an internet-connected machine.
# Usage:
#   ./download_models_online.sh [DEST_DIR] [MANIFEST]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${1:-${SCRIPT_DIR}/../offline-bundle/models}"
MANIFEST="${2:-${SCRIPT_DIR}/models.manifest}"
ALLOW_LOWBIT_QUANTS="${ALLOW_LOWBIT_QUANTS:-0}"

if ! command -v hf >/dev/null 2>&1; then
  echo "ERROR: hf CLI is required. Install with: pip install -U huggingface_hub"
  exit 1
fi

if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: manifest not found: ${MANIFEST}"
  exit 1
fi

if ! hf auth whoami >/dev/null 2>&1; then
  echo "ERROR: Hugging Face auth missing. Run: hf auth login"
  exit 1
fi

mkdir -p "${DEST_DIR}"

echo "Downloading model snapshots listed in ${MANIFEST}"
while IFS= read -r repo; do
  [[ -z "${repo}" || "${repo}" =~ ^# ]] && continue

  # Default safety rail: avoid aggressive low-bit repos (Q4/AWQ/GPTQ/GGUF).
  # Set ALLOW_LOWBIT_QUANTS=1 only if you explicitly want them.
  if [[ "${ALLOW_LOWBIT_QUANTS}" != "1" ]]; then
    repo_lc="$(echo "${repo}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${repo_lc}" == *"q4"* || "${repo_lc}" == *"awq"* || "${repo_lc}" == *"gptq"* || "${repo_lc}" == *"gguf"* ]]; then
      echo "SKIP (low-bit quant blocked): ${repo}"
      continue
    fi
  fi

  safe_name="$(echo "${repo}" | tr '/' '__')"
  out_dir="${DEST_DIR}/${safe_name}"
  mkdir -p "${out_dir}"

  echo "-> ${repo}"
  hf download "${repo}" --local-dir "${out_dir}"
done < "${MANIFEST}"

echo "Done. Models downloaded to: ${DEST_DIR}"

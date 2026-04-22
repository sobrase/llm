#!/usr/bin/env bash
set -euo pipefail

# Download model snapshots from Hugging Face on an internet-connected machine.
# Usage:
#   ./download_models_online.sh [DEST_DIR] [MANIFEST]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${1:-${SCRIPT_DIR}/../offline-bundle/models}"
MANIFEST="${2:-${SCRIPT_DIR}/models.manifest}"
ALLOW_LOWBIT_QUANTS="${ALLOW_LOWBIT_QUANTS:-0}"

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required."
  exit 1
fi

if ! command -v git-lfs >/dev/null 2>&1 && ! git lfs version >/dev/null 2>&1; then
  echo "ERROR: git-lfs is required."
  exit 1
fi

if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: manifest not found: ${MANIFEST}"
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
  rm -rf "${out_dir}"

  echo "-> ${repo}"
  repo_url="https://huggingface.co/${repo}"

  if [[ -n "${HF_TOKEN:-}" ]]; then
    # Use bearer auth without relying on Hugging Face CLI/libs.
    GIT_LFS_SKIP_SMUDGE=1 git -c "http.extraHeader=Authorization: Bearer ${HF_TOKEN}" \
      clone "${repo_url}" "${out_dir}"
    git -C "${out_dir}" -c "http.extraHeader=Authorization: Bearer ${HF_TOKEN}" lfs pull
  else
    GIT_LFS_SKIP_SMUDGE=1 git clone "${repo_url}" "${out_dir}"
    git -C "${out_dir}" lfs pull
  fi
done < "${MANIFEST}"

echo "Done. Models downloaded to: ${DEST_DIR}"

#!/usr/bin/env bash
set -euo pipefail

# Verify offline vLLM model wiring before startup.
# Usage:
#   ./verify_offline_vllm_setup.sh [ENV_FILE]

ENV_FILE="${1:-../.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}"
  exit 1
fi

read_env_value() {
  local key="$1"
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      gsub(/^"/, "", $2)
      gsub(/"$/, "", $2)
      print $2
      exit
    }
  ' "${ENV_FILE}"
}

VLLM_HOST_MODELS_DIR="$(read_env_value "VLLM_HOST_MODELS_DIR")"
VLLM_MODEL="$(read_env_value "VLLM_MODEL")"

if [[ -z "${VLLM_HOST_MODELS_DIR}" ]]; then
  echo "ERROR: VLLM_HOST_MODELS_DIR missing in env: ${ENV_FILE}"
  exit 1
fi

if [[ -z "${VLLM_MODEL}" ]]; then
  echo "ERROR: VLLM_MODEL missing in env: ${ENV_FILE}"
  exit 1
fi

if [[ ! -d "${VLLM_HOST_MODELS_DIR}" ]]; then
  echo "ERROR: host models dir does not exist: ${VLLM_HOST_MODELS_DIR}"
  exit 1
fi

if [[ "${VLLM_MODEL}" != /models/* ]]; then
  echo "ERROR: VLLM_MODEL must be a container path under /models, got: ${VLLM_MODEL}"
  exit 1
fi

REL_MODEL_PATH="${VLLM_MODEL#/models/}"
HOST_MODEL_PATH="${VLLM_HOST_MODELS_DIR}/${REL_MODEL_PATH}"

if [[ ! -d "${HOST_MODEL_PATH}" ]]; then
  echo "ERROR: selected model dir not found on host: ${HOST_MODEL_PATH}"
  exit 1
fi

if [[ ! -f "${HOST_MODEL_PATH}/config.json" ]]; then
  echo "ERROR: model dir seems incomplete (missing config.json): ${HOST_MODEL_PATH}"
  exit 1
fi

echo "OK: offline vLLM wiring looks valid."
echo " - VLLM_HOST_MODELS_DIR=${VLLM_HOST_MODELS_DIR}"
echo " - VLLM_MODEL=${VLLM_MODEL}"
echo " - Resolved host path=${HOST_MODEL_PATH}"

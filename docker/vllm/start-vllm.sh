#!/usr/bin/env bash
set -euo pipefail

MODEL_PATH="${VLLM_MODEL:?VLLM_MODEL is required}"
SERVED_MODEL_NAME="${VLLM_SERVED_MODEL_NAME:-qwen35-122b}"
TP_SIZE="${VLLM_TENSOR_PARALLEL_SIZE:-8}"
MAX_LEN="${VLLM_MAX_MODEL_LEN:-32768}"
GPU_MEM="${VLLM_GPU_MEMORY_UTILIZATION:-0.92}"
DTYPE="${VLLM_DTYPE:-bfloat16}"
EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

exec python -m vllm.entrypoints.openai.api_server \
  --host 0.0.0.0 \
  --port 8000 \
  --model "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --tensor-parallel-size "${TP_SIZE}" \
  --dtype "${DTYPE}" \
  --gpu-memory-utilization "${GPU_MEM}" \
  --max-model-len "${MAX_LEN}" \
  --disable-log-requests \
  ${EXTRA_ARGS}

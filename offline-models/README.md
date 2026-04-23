# Offline Multi-Model Bundle for vLLM

This folder provides a repeatable workflow to prepare and deploy multiple vLLM-compatible models in air-gapped environments.

## Recommended model set for 8x L40S

- `Qwen/Qwen3.5-122B-A10B` (primary high-quality model)
- `Qwen/Qwen3-Coder-Next` (latest coding-focused candidate)
- `Qwen/Qwen2.5-Coder-32B-Instruct` (high-throughput coding model)
- `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` (reasoning-focused fallback)

## Quantization policy (quality-first)

- Default policy is **no aggressive quantization**.
- Allowed baseline: `bf16` (recommended) and `fp8` if validated on your workload.
- Blocked by default in download script: repos containing `q4`, `awq`, `gptq`, or `gguf`.
- Override only if needed: `ALLOW_LOWBIT_QUANTS=1 ./download_models_online.sh ...`

## Folder structure

- `models.manifest`: list of models to mirror
- `download_models_online.sh`: pull model snapshots on an internet-connected machine
- `build_offline_models_bundle.sh`: package snapshots into a transfer archive
- `install_models_offline.sh`: install model snapshots on the target offline host
- `verify_offline_vllm_setup.sh`: validate `.env` wiring and assert real (non-LFS) weights exist

## 1) Download snapshots online

```bash
cd offline-models
chmod +x *.sh
./download_models_online.sh ../offline-bundle/models
```

## 2) Build transferable archive

```bash
cd offline-models
./build_offline_models_bundle.sh ../offline-bundle/models ./offline-models-bundle.tar.gz
```

## 3) Install on offline host

```bash
cd offline-models
./install_models_offline.sh ./offline-models-bundle.tar.gz /opt/offline-agentic-ci/models
```

## 4) Configure `.env`

Configure both host mount and in-container model path:

```env
VLLM_HOST_MODELS_DIR=/opt/offline-agentic-ci/models
VLLM_MODEL=/models/Qwen__Qwen3.5-122B-A10B
VLLM_SERVED_MODEL_NAME=qwen35-122b
```

Run a quick wiring check before `docker compose up`:

```bash
cd offline-models
./verify_offline_vllm_setup.sh ../.env
```

## 5) Add routes in LiteLLM

To add additional model endpoints, duplicate one model block in `docker/litellm/config.yaml` and update:

- `model_name`
- `litellm_params.model`
- `api_base` (if using another vLLM instance)
- `rpm` / `tpm`


#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:?repo dir required}"
MODEL="${2:-chat-fast}"
TEST_OUTPUT="${3:-No test output available}"

: "${LITELLM_BASE_URL:=http://litellm:4000}"
: "${LITELLM_API_KEY:=replace_me}"

PROMPT_FILE="$(mktemp)"
cat > "${PROMPT_FILE}" <<EOF
You are an autonomous CI code-fix agent.

Rules:
1. Fix only failing tests and minimal related code.
2. Do not disable tests.
3. Keep changes small and deterministic.
4. Stop after making one coherent patch.

Test failure output:
${TEST_OUTPUT}
EOF

export MODEL_ARG="${MODEL}"
export LITELLM_BASE_URL
export LITELLM_API_KEY
: "${OPENCODE_MODEL_CONTEXT:=8192}"
: "${OPENCODE_MODEL_MAX_OUTPUT:=2048}"
export OPENCODE_MODEL_CONTEXT OPENCODE_MODEL_MAX_OUTPUT

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to build OPENCODE_CONFIG_CONTENT for LiteLLM" >&2
  exit 1
fi

# OpenCode reads inline JSON (OPENCODE_CONFIG_CONTENT); see https://opencode.ai/docs/cli
export OPENCODE_CONFIG_CONTENT="$(
  python3 <<'PY'
import json, os

base = os.environ["LITELLM_BASE_URL"].rstrip("/")
api_key = os.environ["LITELLM_API_KEY"]
model_arg = os.environ.get("MODEL_ARG", "chat-fast")
if "/" in model_arg:
    provider_id, model_id = model_arg.split("/", 1)
else:
    provider_id, model_id = "litellm", model_arg

ctx = int(os.environ.get("OPENCODE_MODEL_CONTEXT", "8192"))
out = int(os.environ.get("OPENCODE_MODEL_MAX_OUTPUT", "2048"))
# OpenCode adds a large system prompt; input+output must stay within vLLM max_model_len (=ctx).
out = min(out, max(64, ctx - 2048))
if out >= ctx:
    out = max(32, ctx // 4)

# No "$schema" URL here: air-gapped hosts must not fetch https://opencode.ai/... at runtime.
cfg = {
    "provider": {
        provider_id: {
            "npm": "@ai-sdk/openai-compatible",
            "name": "LiteLLM",
            "options": {"baseURL": f"{base}/v1", "apiKey": api_key},
            "models": {
                model_id: {
                    "name": model_id,
                    "limit": {"context": ctx, "output": out},
                }
            },
        }
    },
}
print(json.dumps(cfg))
PY
)"

cd "${REPO_DIR}"

if [[ "${MODEL_ARG}" == */* ]]; then
  OPENCODE_MODEL_SPEC="${MODEL_ARG}"
else
  OPENCODE_MODEL_SPEC="litellm/${MODEL_ARG}"
fi

# Current OpenCode CLI: provider/model, prompt attachment via -f/--file (no --instruction-file).
# Non-interactive CI: auto-approve tool prompts (review before enabling in sensitive environments).
opencode run \
  --model "${OPENCODE_MODEL_SPEC}" \
  --file "${PROMPT_FILE}" \
  --dangerously-skip-permissions \
  "Follow the instructions in the attached CI prompt file and apply changes in this repository."

rm -f "${PROMPT_FILE}"

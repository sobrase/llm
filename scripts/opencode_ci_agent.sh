#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:?repo dir required}"
MODEL="${2:-qwen35-122b-ci}"
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

cd "${REPO_DIR}"

# OpenCode CLI expected to be available in PATH in worker environment.
# Adjust this command to your local OpenCode binary syntax if needed.
opencode run \
  --model "${MODEL}" \
  --base-url "${LITELLM_BASE_URL}/v1" \
  --api-key "${LITELLM_API_KEY}" \
  --instruction-file "${PROMPT_FILE}" \
  --allowed-tools "read,write,edit,bash" \
  --max-steps 20

rm -f "${PROMPT_FILE}"

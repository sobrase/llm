#!/usr/bin/env bash
set -euo pipefail

# Offline phase: load bundle then validate full CI chain.
# Uses mock-vllm + litellm + real orchestrator loop + sandbox execution.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_TAR="${1:?usage: fullstack_offline_validate.sh <offline-fullstack-bundle.tar.gz>}"
WORK_ROOT="${2:-/tmp/offline-fullstack-validate}"
KEEP_TMP="${KEEP_TMP:-0}"

BUNDLE_DIR="${WORK_ROOT}/bundle"
TMP_DIR="${WORK_ROOT}/run"
VENV_DIR="${TMP_DIR}/venv"

cleanup() {
  set +e
  if [[ -n "${WEBHOOK_PID:-}" ]]; then kill "${WEBHOOK_PID}" 2>/dev/null || true; fi
  if [[ -n "${WORKER_PID:-}" ]]; then kill "${WORKER_PID}" 2>/dev/null || true; fi
  docker compose -f "${ROOT_DIR}/docker-compose.e2e.yml" --env-file "${TMP_DIR}/.env.e2e" down -v --remove-orphans >/dev/null 2>&1 || true
  if [[ "${KEEP_TMP}" != "1" ]]; then
    rm -rf "${WORK_ROOT}"
  fi
}
trap cleanup EXIT

mkdir -p "${BUNDLE_DIR}" "${TMP_DIR}"

echo "[1/9] Extracting bundle..."
tar xzf "${BUNDLE_TAR}" -C "${BUNDLE_DIR}"
SRC_DIR="$(rg -n --files "${BUNDLE_DIR}" -g "*/images/*.tar" | head -n 1 | sed 's|/images/.*$||')"
if [[ -z "${SRC_DIR}" ]]; then
  echo "Bundle content invalid: image tar files not found."
  exit 1
fi

echo "[2/9] Loading docker images from bundle..."
for image_tar in "${SRC_DIR}"/images/*.tar; do
  docker load -i "${image_tar}" >/dev/null
done

echo "[3/9] Tagging local e2e images..."
docker tag offline-mock-vllm:latest offline-mock-vllm:latest >/dev/null

echo "[4/9] Starting offline LLM stack with --pull never..."
cat > "${TMP_DIR}/.env.e2e" <<EOF
LITELLM_MASTER_KEY=test-master-key
EOF
docker compose -f "${ROOT_DIR}/docker-compose.e2e.yml" --env-file "${TMP_DIR}/.env.e2e" up -d --pull never

echo "[5/9] Waiting LiteLLM readiness..."
for _ in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer test-master-key" >/dev/null; then
    break
  fi
  sleep 0.5
done
curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer test-master-key" >/dev/null

echo "[6/9] Preparing local orchestrator runtime..."
python -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
"${VENV_DIR}/bin/pip" install -r "${ROOT_DIR}/orchestrator/requirements.txt" >/dev/null

echo "[7/9] Building deterministic failing repo and mock OpenCode fixer..."
mkdir -p "${TMP_DIR}/remote.git" "${TMP_DIR}/seed"
git init --bare "${TMP_DIR}/remote.git" >/dev/null
git --git-dir="${TMP_DIR}/remote.git" symbolic-ref HEAD refs/heads/main
git -C "${TMP_DIR}/seed" init >/dev/null
git -C "${TMP_DIR}/seed" config user.name "dev"
git -C "${TMP_DIR}/seed" config user.email "dev@local"
cat > "${TMP_DIR}/seed/calculator.py" <<'PY'
def add(a, b):
    return a - b
PY
cat > "${TMP_DIR}/seed/test_calculator.py" <<'PY'
import unittest
from calculator import add
class TestCalculator(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)
if __name__ == "__main__":
    unittest.main()
PY
git -C "${TMP_DIR}/seed" add -A
git -C "${TMP_DIR}/seed" commit -m "feat: failing fixture" >/dev/null
git -C "${TMP_DIR}/seed" branch -M main
git -C "${TMP_DIR}/seed" remote add origin "${TMP_DIR}/remote.git"
git -C "${TMP_DIR}/seed" push -u origin main >/dev/null
HEAD_SHA="$(git -C "${TMP_DIR}/seed" rev-parse HEAD)"

cat > "${TMP_DIR}/mock_opencode_fix.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="${1:?repo dir required}"
curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer test-master-key" >/dev/null
sed -i 's/return a - b/return a + b/' "${REPO_DIR}/calculator.py"
SH
chmod +x "${TMP_DIR}/mock_opencode_fix.sh"

echo "[8/9] Running webhook + worker + processing..."
export REDIS_URL="redis://127.0.0.1:6379/0"
export GITEA_WEBHOOK_SECRET=""
export MAX_FIX_LOOPS=5
export TEST_IMAGE="offline-ci-python:3.11"
export TEST_COMMAND="python -m unittest -q test_calculator.TestCalculator.test_add"
export GITEA_BASE_URL=""
export GITEA_TOKEN=""
export BOT_GIT_NAME="ci-agent-bot"
export BOT_GIT_EMAIL="ci-agent@local.lan"
export OPENCODE_SCRIPT="${TMP_DIR}/mock_opencode_fix.sh"
export OPENCODE_MODEL="qwen-coder"
export LITELLM_BASE_URL="http://127.0.0.1:4000"
export LITELLM_API_KEY="test-master-key"
export SANDBOX_NETWORK="none"
export SANDBOX_CPU_LIMIT="1"
export SANDBOX_MEMORY_LIMIT="1g"

PYTHONPATH="${ROOT_DIR}/orchestrator" "${VENV_DIR}/bin/python" -m app.main webhook >"${TMP_DIR}/webhook.log" 2>&1 &
WEBHOOK_PID=$!
PYTHONPATH="${ROOT_DIR}/orchestrator" "${VENV_DIR}/bin/python" -m app.main worker >"${TMP_DIR}/worker.log" 2>&1 &
WORKER_PID=$!

for _ in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null; then
    break
  fi
  sleep 0.5
done
curl -fsS http://127.0.0.1:8080/healthz >/dev/null

cat > "${TMP_DIR}/payload.json" <<JSON
{
  "ref": "refs/heads/main",
  "after": "${HEAD_SHA}",
  "repository": {
    "clone_url": "${TMP_DIR}/remote.git",
    "full_name": "local/e2e-offline-fullstack"
  }
}
JSON
curl -fsS -X POST http://127.0.0.1:8080/webhook/gitea \
  -H "Content-Type: application/json" \
  --data-binary "@${TMP_DIR}/payload.json" >/dev/null

sleep 8
NEW_SHA="$(git --git-dir="${TMP_DIR}/remote.git" rev-parse refs/heads/main)"
if [[ "${NEW_SHA}" == "${HEAD_SHA}" ]]; then
  echo "ERROR: worker did not push a fixing commit."
  echo "--- webhook.log ---"
  cat "${TMP_DIR}/webhook.log" || true
  echo "--- worker.log ---"
  cat "${TMP_DIR}/worker.log" || true
  exit 1
fi

echo "[9/9] Verifying final code and tests..."
git clone -b main "${TMP_DIR}/remote.git" "${TMP_DIR}/verify" >/dev/null 2>&1
rg -n "return a \\+ b" "${TMP_DIR}/verify/calculator.py" >/dev/null
docker run --rm --network none -v "${TMP_DIR}/verify:/workspace:rw" -w /workspace offline-ci-python:3.11 \
  bash -lc "python -m unittest -q test_calculator.TestCalculator.test_add" >/dev/null

echo "FULLSTACK OFFLINE VALIDATION SUCCESS"
echo "Initial SHA: ${HEAD_SHA}"
echo "Fixed SHA:   ${NEW_SHA}"
echo "Artifacts: ${WORK_ROOT} (KEEP_TMP=1 to preserve)"

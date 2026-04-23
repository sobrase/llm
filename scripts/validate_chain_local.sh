#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/offline-ci-e2e-XXXXXX)"
REDIS_CONTAINER="offline-ci-e2e-redis"
VENV_DIR="${TMP_DIR}/venv"
KEEP_TMP="${KEEP_TMP:-0}"

cleanup() {
  set +e
  if [[ -n "${WEBHOOK_PID:-}" ]]; then kill "${WEBHOOK_PID}" 2>/dev/null || true; fi
  if [[ -n "${WORKER_PID:-}" ]]; then kill "${WORKER_PID}" 2>/dev/null || true; fi
  docker rm -f "${REDIS_CONTAINER}" >/dev/null 2>&1 || true
  if [[ "${KEEP_TMP}" == "1" ]]; then
    echo "Keeping temp dir for debug: ${TMP_DIR}"
  else
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

echo "[1/10] Preparing local Python venv for orchestrator runtime..."
python -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip >/dev/null
python -m pip install -r "${ROOT_DIR}/orchestrator/requirements.txt" >/dev/null

echo "[2/10] Starting Redis for queue simulation..."
docker rm -f "${REDIS_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${REDIS_CONTAINER}" -p 6379:6379 redis:7.2-alpine >/dev/null

echo "[3/10] Creating bare remote and seed repository..."
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
git -C "${TMP_DIR}/seed" commit -m "feat: initial failing test fixture" >/dev/null
git -C "${TMP_DIR}/seed" branch -M main
git -C "${TMP_DIR}/seed" remote add origin "${TMP_DIR}/remote.git"
git -C "${TMP_DIR}/seed" push -u origin main >/dev/null
HEAD_SHA="$(git -C "${TMP_DIR}/seed" rev-parse HEAD)"

echo "[4/10] Building local test image with unittest support..."
cat > "${TMP_DIR}/Dockerfile.test" <<'DOCKER'
FROM python:3.11-slim
RUN useradd -m -u 1000 ciuser
USER ciuser
WORKDIR /workspace
DOCKER
docker build -f "${TMP_DIR}/Dockerfile.test" -t offline-ci-python:3.11 "${TMP_DIR}" >/dev/null

echo "[5/10] Creating mock OpenCode fixer script..."
cat > "${TMP_DIR}/mock_opencode_fix.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="${1:?}"
# Simulate deterministic agent patch based on failing tests.
sed -i 's/return a - b/return a + b/' "${REPO_DIR}/calculator.py"
SH
chmod +x "${TMP_DIR}/mock_opencode_fix.sh"

echo "[6/10] Starting orchestrator webhook API and worker..."
export REDIS_URL="redis://127.0.0.1:6379/0"
export GITEA_WEBHOOK_SECRET=""
export MAX_FIX_LOOPS=5
export TEST_IMAGE="offline-ci-python:3.11"
export TEST_COMMAND="python -m unittest -q"
export GITEA_BASE_URL=""
export GITEA_TOKEN=""
export BOT_GIT_NAME="ci-agent-bot"
export BOT_GIT_EMAIL="ci-agent@local.lan"
export OPENCODE_SCRIPT="${TMP_DIR}/mock_opencode_fix.sh"
export OPENCODE_MODEL="chat-fast"
export SANDBOX_NETWORK="none"
export SANDBOX_CPU_LIMIT="1"
export SANDBOX_MEMORY_LIMIT="1g"

PYTHONPATH="${ROOT_DIR}/orchestrator" python -m app.main webhook >"${TMP_DIR}/webhook.log" 2>&1 &
WEBHOOK_PID=$!
PYTHONPATH="${ROOT_DIR}/orchestrator" python -m app.main worker >"${TMP_DIR}/worker.log" 2>&1 &
WORKER_PID=$!

echo "[7/10] Waiting for webhook health..."
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null; then
    break
  fi
  sleep 0.5
done
if ! curl -fsS http://127.0.0.1:8080/healthz >/dev/null; then
  echo "ERROR: webhook API did not become healthy"
  echo "--- webhook log ---"
  cat "${TMP_DIR}/webhook.log" || true
  echo "--- worker log ---"
  cat "${TMP_DIR}/worker.log" || true
  exit 1
fi

echo "[8/10] Posting simulated Gitea push webhook..."
cat > "${TMP_DIR}/payload.json" <<JSON
{
  "ref": "refs/heads/main",
  "after": "${HEAD_SHA}",
  "repository": {
    "clone_url": "${TMP_DIR}/remote.git",
    "full_name": "local/e2e-repo"
  }
}
JSON
curl -fsS -X POST http://127.0.0.1:8080/webhook/gitea \
  -H "Content-Type: application/json" \
  --data-binary "@${TMP_DIR}/payload.json" >/dev/null

echo "[9/10] Waiting worker processing and validating bot push..."
sleep 8
NEW_HEAD="$(git --git-dir="${TMP_DIR}/remote.git" rev-parse refs/heads/main)"
if [[ "${NEW_HEAD}" == "${HEAD_SHA}" ]]; then
  echo "ERROR: no new commit was pushed by agent loop"
  echo "--- webhook log ---"
  cat "${TMP_DIR}/webhook.log" || true
  echo "--- worker log ---"
  cat "${TMP_DIR}/worker.log" || true
  exit 1
fi

echo "[10/10] Verifying fixed repo passes tests in sandbox..."
git clone -b main "${TMP_DIR}/remote.git" "${TMP_DIR}/verify" >/dev/null 2>&1
if ! rg -n "return a \\+ b" "${TMP_DIR}/verify/calculator.py" >/dev/null; then
  echo "ERROR: expected agent fix not present in calculator.py"
  exit 1
fi
docker run --rm --network none -v "${TMP_DIR}/verify:/workspace:rw" -w /workspace offline-ci-python:3.11 \
  bash -lc "python -m unittest -q test_calculator.TestCalculator.test_add" >/dev/null

echo "E2E SUCCESS"
echo "Initial SHA: ${HEAD_SHA}"
echo "Fixed SHA:   ${NEW_HEAD}"
echo "Logs: ${TMP_DIR}/worker.log and ${TMP_DIR}/webhook.log"

import argparse
import hashlib
import hmac
import json
import logging
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional

import redis
import requests
import uvicorn
from fastapi import FastAPI, Header, HTTPException, Request


REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
QUEUE_NAME = os.getenv("QUEUE_NAME", "ci_jobs")
WEBHOOK_SECRET = os.getenv("GITEA_WEBHOOK_SECRET", "")
MAX_FIX_LOOPS = int(os.getenv("MAX_FIX_LOOPS", "5"))
TEST_IMAGE = os.getenv("TEST_IMAGE", "offline-ci-python:3.11")
TEST_COMMAND = os.getenv("TEST_COMMAND", "pytest -q")
GITEA_BASE_URL = os.getenv("GITEA_BASE_URL", "").rstrip("/")
GITEA_TOKEN = os.getenv("GITEA_TOKEN", "")
BOT_GIT_NAME = os.getenv("BOT_GIT_NAME", "ci-agent-bot")
BOT_GIT_EMAIL = os.getenv("BOT_GIT_EMAIL", "ci-agent@local.lan")
OPENCODE_SCRIPT = os.getenv("OPENCODE_SCRIPT", "/workspace/scripts/opencode_ci_agent.sh")
OPENCODE_MODEL = os.getenv("OPENCODE_MODEL", "chat-fast")
SANDBOX_NETWORK = os.getenv("SANDBOX_NETWORK", "none")
SANDBOX_CPU_LIMIT = os.getenv("SANDBOX_CPU_LIMIT", "2")
SANDBOX_MEMORY_LIMIT = os.getenv("SANDBOX_MEMORY_LIMIT", "4g")

rds = redis.from_url(REDIS_URL, decode_responses=True)
app = FastAPI(title="Offline CI Orchestrator")
logger = logging.getLogger("offline_ci_orchestrator")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


@dataclass
class Job:
    repo_clone_url: str
    repo_full_name: str
    branch: str
    commit_sha: str

    @classmethod
    def from_webhook(cls, payload: Dict[str, Any]) -> "Job":
        repo = payload["repository"]
        ref = payload.get("ref", "refs/heads/main")
        branch = ref.split("/")[-1]
        return cls(
            repo_clone_url=repo["clone_url"],
            repo_full_name=repo["full_name"],
            branch=branch,
            commit_sha=payload["after"],
        )


def verify_webhook(raw_body: bytes, signature: Optional[str]) -> bool:
    if not WEBHOOK_SECRET:
        return True
    if not signature:
        return False
    expected = hmac.new(WEBHOOK_SECRET.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def gitea_api_headers() -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if GITEA_TOKEN:
        headers["Authorization"] = f"token {GITEA_TOKEN}"
    return headers


def set_commit_status(job: Job, state: str, description: str, target_url: str = "") -> None:
    if not GITEA_BASE_URL or not GITEA_TOKEN:
        return
    url = f"{GITEA_BASE_URL}/api/v1/repos/{job.repo_full_name}/statuses/{job.commit_sha}"
    body = {
        "state": state,
        "context": "offline-agentic-ci",
        "description": description[:140],
        "target_url": target_url,
    }
    try:
        requests.post(url, headers=gitea_api_headers(), json=body, timeout=8)
    except Exception:
        pass


def run_cmd(cmd: list[str], cwd: Optional[str] = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=True)


def clone_repo(job: Job, workdir: str) -> str:
    repo_dir = os.path.join(workdir, "repo")
    run_cmd(["git", "clone", "--branch", job.branch, "--single-branch", job.repo_clone_url, repo_dir])
    run_cmd(["git", "checkout", job.commit_sha], cwd=repo_dir)
    run_cmd(["git", "config", "user.name", BOT_GIT_NAME], cwd=repo_dir)
    run_cmd(["git", "config", "user.email", BOT_GIT_EMAIL], cwd=repo_dir)
    return repo_dir


def run_tests_in_sandbox(repo_dir: str) -> subprocess.CompletedProcess:
    cmd = [
        "docker",
        "run",
        "--rm",
        "--network",
        SANDBOX_NETWORK,
        "--cpus",
        SANDBOX_CPU_LIMIT,
        "--memory",
        SANDBOX_MEMORY_LIMIT,
        "--read-only",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=512m",
        "-v",
        f"{repo_dir}:/workspace:rw",
        "-w",
        "/workspace",
        "-e",
        "PYTHONDONTWRITEBYTECODE=1",
        TEST_IMAGE,
        "bash",
        "-lc",
        TEST_COMMAND,
    ]
    return subprocess.run(cmd, text=True, capture_output=True)


def run_opencode_fix(repo_dir: str, test_output: str) -> subprocess.CompletedProcess:
    short_output = test_output[-4000:]
    cmd = [
        "bash",
        OPENCODE_SCRIPT,
        repo_dir,
        OPENCODE_MODEL,
        short_output,
    ]
    return subprocess.run(cmd, text=True, capture_output=True)


def has_changes(repo_dir: str) -> bool:
    result = run_cmd(["git", "status", "--porcelain"], cwd=repo_dir)
    return bool(result.stdout.strip())


def cleanup_generated_artifacts(repo_dir: str) -> None:
    # Prevent test/runtime artifacts from polluting bot commits.
    run_cmd(["bash", "-lc", "rm -rf __pycache__ .pytest_cache"], cwd=repo_dir, check=False)


def commit_and_push(repo_dir: str, branch: str, loop_index: int) -> str:
    run_cmd(["git", "add", "-A"], cwd=repo_dir)
    msg = f"ci(agent): auto-fix failing tests (loop {loop_index})"
    run_cmd(["git", "commit", "-m", msg], cwd=repo_dir)
    run_cmd(["git", "push", "origin", f"HEAD:{branch}"], cwd=repo_dir)
    sha = run_cmd(["git", "rev-parse", "HEAD"], cwd=repo_dir).stdout.strip()
    return sha


def process_job(raw_job: str) -> None:
    job_dict = json.loads(raw_job)
    job = Job(**job_dict)
    set_commit_status(job, "pending", "CI worker started")

    os.makedirs("/tmp/ci-workdir", exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ci-job-", dir="/tmp/ci-workdir") as temp_dir:
        repo_dir = clone_repo(job, temp_dir)
        for i in range(1, MAX_FIX_LOOPS + 1):
            test_result = run_tests_in_sandbox(repo_dir)
            if test_result.returncode == 0:
                set_commit_status(job, "success", f"Tests passed (loop {i})")
                return

            if i == MAX_FIX_LOOPS:
                set_commit_status(job, "failure", "Tests still failing after max loops")
                return

            fix_result = run_opencode_fix(repo_dir, test_result.stdout + "\n" + test_result.stderr)
            if fix_result.returncode != 0:
                set_commit_status(job, "failure", f"OpenCode failed loop {i}")
                return

            cleanup_generated_artifacts(repo_dir)
            if has_changes(repo_dir):
                new_sha = commit_and_push(repo_dir, job.branch, i)
                job.commit_sha = new_sha
            else:
                set_commit_status(job, "failure", f"No code change generated on loop {i}")
                return


@app.get("/healthz")
def healthz() -> Dict[str, str]:
    return {"status": "ok"}


@app.post("/webhook/gitea")
async def gitea_webhook(request: Request, x_gitea_signature: Optional[str] = Header(default=None)) -> Dict[str, str]:
    raw_body = await request.body()
    if not verify_webhook(raw_body, x_gitea_signature):
        raise HTTPException(status_code=401, detail="Invalid signature")

    payload = await request.json()
    if payload.get("after", "").startswith("0000000"):
        return {"status": "ignored", "reason": "branch delete"}

    job = Job.from_webhook(payload)
    rds.lpush(QUEUE_NAME, json.dumps(job.__dict__))
    return {"status": "queued", "repo": job.repo_full_name, "sha": job.commit_sha}


def run_worker_forever() -> None:
    while True:
        try:
            item = rds.brpop(QUEUE_NAME, timeout=5)
            if not item:
                continue
            _, raw_job = item
            process_job(raw_job)
        except Exception as exc:
            logger.exception("Worker loop failed: %s", exc)
            time.sleep(2)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["webhook", "worker"], default="webhook", nargs="?")
    args = parser.parse_args()
    if args.mode == "webhook":
        uvicorn.run(app, host="0.0.0.0", port=8080)
    else:
        run_worker_forever()


if __name__ == "__main__":
    main()

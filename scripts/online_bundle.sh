#!/usr/bin/env bash
set -euo pipefail

# Run this on a machine with internet access.
# It prepares a transferable bundle for offline installation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORCHESTRATOR_DIR="${REPO_ROOT}/orchestrator"

BUNDLE_DIR="${1:-offline-bundle}"
mkdir -p "${BUNDLE_DIR}/images" "${BUNDLE_DIR}/models" "${BUNDLE_DIR}/wheels" "${BUNDLE_DIR}/opencode/npm-tarballs"

IMAGES=(
  "redis:7.2-alpine"
  "postgres:16-alpine"
  "ghcr.io/berriai/litellm:main-latest"
  "vllm/vllm-openai:latest"
  "python:3.11-slim"
  "nvidia/cuda:12.4.1-base-ubuntu22.04"
)

echo "[1/6] Pull docker images..."
for image in "${IMAGES[@]}"; do
  docker pull "${image}"
done

echo "[2/6] Build orchestrator image..."
docker build -t offline-ci-orchestrator:latest "${ORCHESTRATOR_DIR}"

echo "[3/6] Export docker images..."
for image in "${IMAGES[@]}" "offline-ci-orchestrator:latest"; do
  safe_name="$(echo "${image}" | tr '/:' '__')"
  docker save "${image}" -o "${BUNDLE_DIR}/images/${safe_name}.tar"
done

echo "[4/6] Download Python wheels..."
python -m pip download -r "${ORCHESTRATOR_DIR}/requirements.txt" -d "${BUNDLE_DIR}/wheels"

echo "[5/6] Prefetch OpenCode air-gap assets (schema JSON + @ai-sdk/openai-compatible npm tarball)..."
curl -fsSL "https://opencode.ai/config.json" -o "${BUNDLE_DIR}/opencode/opencode-config.schema.json"
OPENCOMPAT_VERSION="${OPENCOMPAT_VERSION:-}"
if [[ -n "${OPENCOMPAT_VERSION}" ]]; then
  meta_url="https://registry.npmjs.org/@ai-sdk/openai-compatible/${OPENCOMPAT_VERSION}"
else
  meta_url="https://registry.npmjs.org/@ai-sdk/openai-compatible/latest"
fi

meta_json="$(curl -fsSL "${meta_url}")"
ver="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<< "${meta_json}")"
tb_url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dist"]["tarball"])' <<< "${meta_json}")"
dst="${BUNDLE_DIR}/opencode/npm-tarballs/ai-sdk-openai-compatible-${ver}.tgz"
curl -fsSL "${tb_url}" -o "${dst}"
echo "Downloaded ${tb_url} -> ${dst}"

cat > "${BUNDLE_DIR}/opencode/README-airgap.txt" <<'EOF'
OpenCode en zone air-gap
========================

1) Ne mets pas de clef "$schema" pointant vers https://opencode.ai/... dans OPENCODE_CONFIG_CONTENT
   ou opencode.json : sans reseau, ce fetch echoue. Le fichier opencode-config.schema.json dans ce
   repertoire est une copie locale (telechargee en ligne par online_bundle.sh) pour reference / IDE.

2) Le tarball npm @ai-sdk/openai-compatible est dans npm-tarballs/. Sur la machine offline, installe-le
   la ou OpenCode charge les paquets (souvent sous ~/.opencode), par exemple apres consultation de la
   doc OpenCode pour les providers openai-compatible.

3) Installe aussi le binaire OpenCode lui-meme sur la machine online avant transfert (curl/install officiel),
   puis copie le binaire et ~/.opencode si necessaire — ce script ne redistribue pas le CLI OpenCode.
EOF

echo "[6/6] Model sync (example for local mirror path)..."
echo "Copy your Qwen model files into: ${BUNDLE_DIR}/models/Qwen2.5-Coder-32B-Instruct"
echo "Example with git-lfs on online machine:"
echo "  GIT_LFS_SKIP_SMUDGE=1 git clone https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct ${BUNDLE_DIR}/models/Qwen2.5-Coder-32B-Instruct && git -C ${BUNDLE_DIR}/models/Qwen2.5-Coder-32B-Instruct lfs pull"

tar czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
echo "Bundle generated: ${BUNDLE_DIR}.tar.gz"

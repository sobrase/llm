# Offline Agentic CI/CD Stack (Gitea + vLLM + LiteLLM + OpenCode)

## 1) Architecture globale (texte)

```text
                    +-----------------------+
                    |  Developers (LAN)     |
                    +-----------+-----------+
                                |
                                v
                    +-----------------------+
                    |  Gitea (self-hosted)  |
                    |  - Git repositories   |
                    |  - Webhooks           |
                    +-----------+-----------+
                                |
                                | webhook push
                                v
          +-----------------------------------------------+
          | Python CI Orchestrator                        |
          | - webhook API (FastAPI)                       |
          | - Redis queue producer                        |
          | - worker loop controller (max 3-5 retries)    |
          +---------------------+-------------------------+
                                |
                                v
                     +----------------------+
                     | Redis (job queue)    |
                     | - LPUSH/BRPOP jobs   |
                     +----------+-----------+
                                |
                                v
        +-------------------------------------------------------+
        | CI Worker (orchestrator mode worker)                  |
        | 1) clone repo@commit                                  |
        | 2) run tests in Docker sandbox                        |
        | 3) if fail -> call OpenCode agent                     |
        | 4) commit bot fix + push                              |
        | 5) retry tests (up to MAX_LOOPS)                      |
        +----------------------+--------------------------------+
                               |
                               v
                +-------------------------------+
                | Docker Sandbox Runner         |
                | isolated container per test   |
                +-------------------------------+
                               |
                               v
                 +-------------------------------+
                 | OpenCode Agent CLI            |
                 | uses LiteLLM OpenAI endpoint  |
                 +---------------+---------------+
                                 |
                                 v
                    +---------------------------+
                    | LiteLLM Gateway           |
                    | - routing                 |
                    | - rate limit/QoS          |
                    | - priority CI low         |
                    +-------------+-------------+
                                  |
                                  v
                   +--------------------------------------------+
                   | vLLM pool                                  |
                   | - vllm-fast (low latency)                  |
                   | - vllm-balanced (default)                  |
                   | - vllm-heavy (high quality / CI)           |
                   | OpenAI compatible API behind LiteLLM       |
                   +--------------------------------------------+
```

## 2) Principes de robustesse

- Architecture event-driven simple: webhook -> queue Redis -> worker.
- Boucle agentic bornée (`MAX_FIX_LOOPS=5` par défaut).
- Sandbox Docker obligatoire pour toute exécution de tests.
- Tous les composants packagés en conteneurs, sans appel cloud.
- Scripts dédiés pour préparer des artefacts sur machine connectée puis installer en air-gap.

## 3) Arborescence

- `docker-compose.yml`: stack complète.
- `docker/litellm/config.yaml`: routing/QoS.
- `docker/vllm/start-vllm.sh`: démarrage multi-GPU vLLM.
- `orchestrator/`: service Python webhook + worker.
- `scripts/opencode_ci_agent.sh`: agent OpenCode pour auto-fix.
- `scripts/online_bundle.sh`: téléchargement en environnement online.
- `scripts/offline_install.sh`: installation en environnement offline.
- `offline-models/`: préparation multi-modèles vLLM pour air-gap.
- `docs/workflow-example.md`: scénario complet fail -> fix -> retry -> commit.
- `docs/security-hardening.md`: recommandations sécurité.
- `.opencode/agents/chat.md`: agent OpenCode « chat » (réponses courtes, sans gabarit de rapport) pour `opencode run --agent chat`.
- README §6 : tableau des variables d’environnement à tuner (vLLM, OpenCode, LiteLLM, orchestrateur).

## 4) Images incluses dans le bundle offline

Le bundle généré par `scripts/online_bundle.sh` inclut désormais ces images:

- `redis:7.2-alpine`
- `postgres:16-alpine`
- `ghcr.io/berriai/litellm:main-latest`
- `vllm/vllm-openai:latest`
- `python:3.11-slim`
- `nvidia/cuda:12.4.1-base-ubuntu22.04`
- `offline-ci-orchestrator:latest` (build local pendant le bundling ; le compose **n’utilise plus** `build:` sur les orchestrateurs — même image `ORCHESTRATOR_IMAGE`, `pull_policy: never`. Après modification du code Python : `docker build -t offline-ci-orchestrator:latest ./orchestrator`)
- Dossier `offline-bundle/opencode/` : schéma `opencode-config.schema.json` (copie locale) + tarball npm `@ai-sdk/openai-compatible` pour usage sans accès à npmjs / opencode.ai au runtime (version figeable avec `OPENCOMPAT_VERSION=… ./scripts/online_bundle.sh`)

## 5) Defaults offline dans le compose principal

Le `docker-compose.yml` principal vise un usage offline direct (modèles sous `/models/...`, LiteLLM, Postgres pour la base admin, Redis). Les services vLLM additionnels peuvent rester commentés pour une seule GPU.

Tu peux surcharger vLLM avec les variables `VLLM_FAST_*` (et les blocs commentés `VLLM_BALANCED_*`, etc. si tu les réactives). Le détail des variables « qui posent problème » et leur réglage selon le modèle est en **§6**.

### OpenCode CLI + LiteLLM

La commande `opencode run` actuelle ne prend pas `--instruction-file`, `--base-url` ni `--api-key`. Il faut un provider au format `provider/model`, un fichier joint avec `-f` / `--file`, et la config LiteLLM via `opencode.json` ou la variable **`OPENCODE_CONFIG_CONTENT`** (voir [documentation CLI OpenCode](https://opencode.ai/docs/cli)).

**Air-gap** : n’inclus pas `"$schema": "https://opencode.ai/config.json"` dans le JSON injecté (sinon OpenCode peut tenter un fetch réseau). Une copie locale du schéma et le tarball npm `@ai-sdk/openai-compatible` sont téléchargés dans le bundle par `scripts/online_bundle.sh` (`offline-bundle/opencode/`), puis copiés vers `opencode-airgap/` par `scripts/offline_install.sh`.

**Tokens** : OpenCode envoie un gros prompt système. Pour éviter `ContextWindowExceededError`, on privilégie une fenêtre modèle plus large (`VLLM_FAST_MAX_MODEL_LEN=8192`) et une sortie plus confortable (`OPENCODE_MODEL_MAX_OUTPUT=2048`). Si le prompt devient très long, monte encore la fenêtre si la VRAM le permet.

**Boucles / pavés « résumé structuré »** : par défaut, `opencode run` utilise l’agent **`build`** (outils, tours multiples). OpenCode embarque aussi un agent **`summary`** conçu pour des résumés structurés : si tu vois des blocs *Goal / Next steps / Critical Context* ou un rappel « command in English », ce n’est en général **pas** LiteLLM, c’est le **comportement agent / compaction**. `OPENCODE_DISABLE_CLAUDE_CODE=1` **ne suffit pas** toujours à supprimer ce gabarit.

**Recommandé pour une phrase ou un chat court** : lance OpenCode **depuis la racine de ce dépôt** (pour charger `.opencode/agents/`) et utilise l’agent projet **`chat`** :

```bash
opencode run --agent chat --model litellm/chat-fast "dis moi bonjour"
```

Tu peux combiner avec **`--pure`** si tu veux désactiver les plugins externes. Pour réduire l’influence de `~/.claude/`, garde les variables `OPENCODE_DISABLE_CLAUDE_CODE*` (voir §6). Pour le CI auto-fix, on continue d’utiliser l’agent **`build`** via `scripts/opencode_ci_agent.sh` avec `--dangerously-skip-permissions` ; pour un test manuel « une phrase », **ne** passe **pas** ce flag.

Exemple minimal (depuis un clone de dépôt, avec `LITELLM_BASE_URL` sans slash final) :

```bash
export LITELLM_BASE_URL=http://127.0.0.1:4000
export LITELLM_API_KEY=test-master-key
export OPENCODE_MODEL_CONTEXT=8192
export OPENCODE_MODEL_MAX_OUTPUT=2048
export OPENCODE_CONFIG_CONTENT="$(
python3 <<'PY'
import json, os
b = os.environ["LITELLM_BASE_URL"].rstrip("/") + "/v1"
k = os.environ["LITELLM_API_KEY"]
ctx = int(os.environ.get("OPENCODE_MODEL_CONTEXT", "8192"))
out = int(os.environ.get("OPENCODE_MODEL_MAX_OUTPUT", "2048"))
out = min(out, max(64, ctx - 2048))
if out >= ctx:
    out = max(32, ctx // 4)
cfg = {
    "provider": {
        "litellm": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "LiteLLM",
            "options": {"baseURL": b, "apiKey": k},
            "models": {"chat-fast": {"name": "chat-fast", "limit": {"context": ctx, "output": out}}},
        }
    },
}
print(json.dumps(cfg))
PY
)"

opencode run \
  --agent chat \
  --model litellm/chat-fast \
  --file /tmp/prompt.txt \
  "Réponds brièvement au message du fichier joint."
```

Test GPU avec l’image CUDA incluse dans le bundle :

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

## 6) Variables d’environnement à tuner (erreurs fréquentes)

Toutes ces variables viennent en pratique du **`.env`** à la racine du dépôt (ou de l’export manuel avant `opencode run`). Les valeurs doivent rester **cohérentes entre elles** : modèle vLLM, route LiteLLM, noms exposés, fenêtre de contexte, VRAM.

### vLLM (`VLLM_FAST_*`)

| Variable | Rôle | Symptôme si mal réglé | Comment la tuner selon le modèle |
|----------|------|------------------------|----------------------------------|
| `VLLM_HOST_MODELS_DIR` | Répertoire **hôte** monté sur `/models` dans le conteneur | vLLM ne trouve pas les poids, démarrage impossible | Chemin absolu vers le dossier qui **contient** le répertoire du modèle (ex. `.../models` avec `Qwen_...` dedans). |
| `VLLM_FAST_MODEL` | Chemin **dans le conteneur** vers les poids | Idem | Doit être `/models/<nom_du_dossier>` aligné sur ce que tu as sur l’hôte. |
| `VLLM_FAST_SERVED_MODEL_NAME` | Nom OpenAI renvoyé par vLLM (`/v1/models`) | LiteLLM ou clients appellent un id qui n’existe pas | Doit correspondre au suffixe après `openai/` dans `docker/litellm/config.yaml` pour cette route (ex. `openai/qwen-fast` → `qwen-fast`). |
| `VLLM_FAST_MAX_MODEL_LEN` | Fenêtre **max** (prompt + génération) côté moteur | `ContextWindowExceededError`, OOM GPU | **Base recommandée ici** : `8192` pour laisser de la place à OpenCode + génération. **VRAM serrée** : `4096`. **Prompts longs / modèles plus lourds** : `8192–16384` si la VRAM suit. Toujours aligner avec `OPENCODE_MODEL_CONTEXT`. |
| `VLLM_FAST_GPU_MEMORY_UTILIZATION` | Fraction VRAM utilisée par vLLM | OOM, ou GPU sous-utilisée | **VRAM serrée** : 0.55–0.75. **Carte large** : jusqu’à ~0.90–0.92. Baisser si crash au chargement ou en génération longue. |
| `VLLM_FAST_TENSOR_PARALLEL_SIZE` | Nombre de GPU pour le modèle | Erreur multi-GPU, lenteur inattendue | **1 GPU** : `1`. Modèles très larges multi-cartes : `2`, `4`, … et **liste** dans `VLLM_FAST_VISIBLE_DEVICES`. |
| `VLLM_FAST_VISIBLE_DEVICES` | GPU vus par le conteneur | mauvaise carte, pas de GPU | Ex. `0` ou `0,1`. Doit matcher le nombre de GPU réel et `TENSOR_PARALLEL_SIZE`. |
| `VLLM_FAST_DTYPE` | Précision (`half`, `bfloat16`, …) | NaN, OOM, lenteur | **Beaucoup de cartes consumer** : `half`. **Ampere+ avec bfloat16** : `bfloat16` souvent meilleur qualité/stabilité. |
| `VLLM_FAST_EXTRA_ARGS` | Flags CLI vLLM (dont outils) | `tool_choice=auto` refusé ; parsing d’outils incohérent | OpenCode envoie des **tool calls** : garde `--enable-auto-tool-choice` et un **`--tool-call-parser`** adapté à la **famille** du modèle (souvent `hermes` pour Qwen ; pour Llama 3.x souvent `llama3_json` / doc vLLM selon version). **`--enforce-eager`** : utile pour stabilité / debug, parfois un peu plus lent. |

Après changement : `docker compose up -d --force-recreate vllm-fast` (et LiteLLM si besoin).

### OpenCode ↔ fenêtre de contexte (`OPENCODE_*`)

| Variable | Rôle | Symptôme si mal réglé | Comment la tuner |
|----------|------|------------------------|------------------|
| `OPENCODE_MODEL` | Nom de **route** LiteLLM (sans préfixe `litellm/`) | 404 / mauvais modèle | Identique à `model_name` dans `docker/litellm/config.yaml` (ex. `chat-fast`). Avec le CLI : `litellm/<OPENCODE_MODEL>`. |
| `OPENCODE_MODEL_CONTEXT` | Plafond « context » côté config OpenCode | Identique à `max_tokens` trop grand vs vLLM | À garder **≤ `VLLM_FAST_MAX_MODEL_LEN`**. Monte avec le modèle / la VRAM comme pour `VLLM_FAST_MAX_MODEL_LEN`. |
| `OPENCODE_MODEL_MAX_OUTPUT` | Plafond de **génération** (max tokens sortie) | `ContextWindowExceededError` (prompt système OpenCode + sortie > max) | Règle pratique : avec `MAX_MODEL_LEN=8192`, commencer à `2048`. Si prompts très lourds, réduire temporairement ; si marge large, augmenter graduellement. `scripts/opencode_ci_agent.sh` applique aussi un **clamp** (`ctx - 2048`). |
| `OPENCODE_DISABLE_CLAUDE_CODE` | Désactive la lecture du contexte `.claude/` (prompt + skills) | Réponses hors sujet ou « résumés » répétitifs | Mets `1` pour des tests **hors** intégration Cursor/Claude. |
| `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT` | Ignore `~/.claude/CLAUDE.md` | Idem | `1` si ce fichier impose un format de réponse. |
| `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS` | Ne charge pas `.claude/skills` | Idem | `1` pour isoler le comportement du modèle. |

### LiteLLM, Postgres, secrets

| Variable | Rôle | Symptôme si mal réglé | Comment la tuner |
|----------|------|------------------------|------------------|
| `LITELLM_MASTER_KEY` | Clé admin / proxy | refus d’auth sur l’API LiteLLM | Valeur forte en prod ; la même logique que la doc LiteLLM pour les appels directs au proxy. |
| `LITELLM_API_KEY` | Clé « client » attendue par la config `key_management_settings` | `401` depuis l’orchestrateur ou OpenCode | Doit correspondre à ce que tu passes dans les clients ; dans ce dépôt, souvent **égale** à `LITELLM_MASTER_KEY` en dev (voir `docker/litellm/config.yaml`). |
| `LITELLM_DATABASE_URL` | Postgres pour l’UI admin / métadonnées | « not connected to DB » sur l’admin | URL du service `postgres` du compose ; mots de passe **alignés** avec `POSTGRES_*`. |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Identifiants base | Postgres ou LiteLLM ne démarrent pas | Même utilisateur / base / mot de passe que dans `LITELLM_DATABASE_URL`. |

### Orchestrateur, sandbox, Gitea

| Variable | Rôle | Symptôme si mal réglé | Comment la tuner |
|----------|------|------------------------|------------------|
| `ORCHESTRATOR_IMAGE` | Image Docker partagée par **api** et **worker** | `pull access denied` ou image absente | Défaut `offline-ci-orchestrator:latest` (produite par `online_bundle.sh` ou `docker build -t offline-ci-orchestrator:latest ./orchestrator`). Le compose utilise `pull_policy: never` pour l’air-gap. |
| `TEST_COMMAND` | Commande dans le conteneur de test | Tests ne lancent pas ce que tu crois | **Toujours entre guillemets** si la commande contient des espaces (ex. `"pytest -q"`). Sinon `source .env` casse le shell. |
| `TEST_IMAGE` | Image pour exécuter les tests | Image introuvable offline | Prépare / charge l’image dans le bundle ou `docker load`. |
| `MAX_FIX_LOOPS` | Nombre de boucles agent | Trop de / pas assez de tentatives | 3–10 selon tolérance CI. |
| `SANDBOX_NETWORK` / `SANDBOX_CPU_LIMIT` / `SANDBOX_MEMORY_LIMIT` | Ressources du conteneur de test | timeouts, OOM dans le sandbox | Monter CPU/RAM si la suite de tests est lourde ; `SANDBOX_NETWORK=none` pour isolation stricte. |
| `GITEA_*` / `GITEA_WEBHOOK_SECRET` | Intégration forge | webhooks rejetés, pas de clone | Renseigner sur la machine qui parle à Gitea ; vide tant que tu ne branches pas la forge. |

### Cohérence « modèle » (checklist rapide)

1. **Poids** : `VLLM_HOST_MODELS_DIR` + `VLLM_FAST_MODEL` pointent le bon dossier.  
2. **Nom API** : `VLLM_FAST_SERVED_MODEL_NAME` = suffixe `openai/...` dans `docker/litellm/config.yaml`.  
3. **Route agrégée** : `model_name: chat-fast` (ou autre) = `OPENCODE_MODEL` = entrée dans `key_management_settings.models`.  
4. **Contexte** : `VLLM_FAST_MAX_MODEL_LEN` ≥ `OPENCODE_MODEL_CONTEXT` ; sortie OpenCode compatible (voir §5 et `OPENCODE_MODEL_MAX_OUTPUT`).  
5. **Outils OpenCode** : `VLLM_FAST_EXTRA_ARGS` avec parser adapté à la famille du modèle si tu utilises le mode agent.
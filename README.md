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

# Exemple de workflow CI agentic complet

## Cas: push avec tests en échec

1. Dev push commit `abc123` sur `feature/login`.
2. Gitea envoie webhook `push` vers `POST /webhook/gitea`.
3. Orchestrator API valide signature HMAC et ajoute job dans Redis.
4. Worker récupère job:
   - clone repo et checkout `abc123`
   - exécute tests en sandbox Docker
5. Tests échouent (`pytest` code exit != 0).
6. Worker appelle `scripts/opencode_ci_agent.sh` avec le log d'erreur.
7. OpenCode interroge LiteLLM (`model alias ci`), qui route vers vLLM Qwen coder.
8. OpenCode patch le code.
9. Worker commit `ci(agent): auto-fix failing tests (loop 1)` puis push.
10. Worker relance tests en sandbox sur nouveau commit.
11. Si tests passent: status Gitea `success`.
12. Sinon: boucle jusqu'à `MAX_FIX_LOOPS` (max 5), puis status `failure`.

## Conditions d'arrêt

- Succès immédiat des tests.
- Échec OpenCode (commande non valide / timeout).
- Aucun changement produit par l'agent.
- Limite de boucles atteinte.

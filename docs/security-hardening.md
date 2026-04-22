# Recommandations sécurité sandbox (offline CI)

- Exécuter les tests avec `--network=none` (défaut) pour empêcher exfiltration.
- Utiliser `--read-only` + `--tmpfs /tmp` pour limiter écritures.
- Limiter ressources avec `--cpus` et `--memory`.
- Monter uniquement le repo (`-v repo:/workspace`) et rien d'autre.
- Empêcher privilèges:
  - ajouter `--cap-drop=ALL`
  - ajouter `--security-opt=no-new-privileges:true`
  - utiliser un profil seccomp durci.
- Isoler worker et sandbox sur un host dédié CI.
- Restreindre le token Gitea du bot (scope repo minimal).
- Activer rotation des secrets (`.env`) et journalisation locale chiffrée.
- Ajouter un allowlist de commandes autorisées côté agent OpenCode.
- Désactiver toute exécution shell non nécessaire dans prompts agent.

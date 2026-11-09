<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:468b22d25497. Edit agent-rules/docs/rules/deployment.md, then run `make rules`; local edits here are not kept. -->
## Production and Deployment

General rules for touching production. The concrete deployment standard (hosts, pipeline, settings, secrets list) lives in the project's own deployment doc.

### Hands off production

- Deploy only through the project's automated pipeline, as documented in its runbook.
- Do not log in to production hosts, run commands against production databases or storage, or change CI secrets or variables. Hand those steps to the user as exact commands.
- Never print secrets, commit them, or ship them in client-side bundles. Public client configuration is not a place for secrets, even when the value originates in a secret store.
- Other applications may share the same host. Scope changes to this app's own resources; avoid global cleanups, host-wide restarts, or changes to shared infrastructure as part of routine deployment.

### Deployment standard

- CI runs in GitHub Actions. An app deployed to a general VPS deploys from GitHub Actions and runs in Docker on the VPS.
- If the project has tests, they run in CI, and the deploy runs only after they pass. Deploy only the exact commit whose required checks passed. Separate pipelines firing on the same push do not establish a dependency; use explicit dependencies between jobs.
- Serialize production deployments, and never interrupt one in progress with a newer push.
- Build artifacts in CI, not on the production host. Pin the server identity; do not disable host-key checking.
- Pass runtime configuration through an explicit allowlist. Adding a setting means updating the pipeline, the deploy script, the application configuration, and the docs together. Validate required values before changing the host, and write configuration atomically with restrictive permissions.
- Keep runtime versions consistent across version files, build files, and pipelines. Use lockfiles and bounded job timeouts.
- Deploy scripts fail fast and are safe to rerun. Never reset databases or load demo data in production.
- Schema changes stay compatible with rollback and with the previous release (rolling back an app doesn't reverse its migrations), or have a documented recovery procedure. Never run destructive down-migrations automatically. Document backup and restore before risky migrations.
- Changing a storage backend does not migrate existing files. Copy and verify them through a deliberate migration, and preserve originals until verified.
- Add paid or third-party services only when the app needs them, and never automatically.

### Validation, recovery, and reporting

- Before delivering deployment changes, run the relevant application checks and validate scripts, pipelines, and server configuration in suitable environments.
- Retain a known-good build for recovery, labeled by commit, and document how to restore it and recheck health.
- A deployment is complete only after remote health checks and public checks (frontend and a real API response over HTTPS) pass. An internal check alone does not verify the proxy, DNS, or TLS.
- Don't claim zero downtime unless it is true. Distinguish local validation from an actual deployment, report anything unverified, and keep the README aligned with the final configuration.

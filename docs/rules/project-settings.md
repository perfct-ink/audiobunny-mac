<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:a39baa68091e. Edit agent-rules/docs/rules/project-settings.md, then run `make rules`; local edits here are not kept. -->
## Project Settings

Every repo keeps a short settings file at `docs/project/settings.md`, in this shape (the agent-rules repo keeps a copy in `templates/settings.md`). Read it before anything else; the shared rules depend on it.

```markdown
## Project Settings

- **Platforms:** frontend, backend
- **Prototyping mode:** off
```

### Platforms

One or more of:

- `frontend`: UI that runs in a browser, whether a SPA or pages rendered by the server.
- `backend`: a server or API, including one that renders pages.
- `mac`: a native macOS app.
- `iOS`: a native iOS app.

Apply only the rules for the listed platforms: [backend.md](backend.md) for `backend`, [frontend.md](frontend.md) and [design-principles.md](design-principles.md) for `frontend`, and [native.md](native.md) plus the platform's own conventions (and the design principles, where they make sense natively) for `mac` and `iOS`. Platforms not listed are out of scope here; for example, don't add a backend to a `frontend`-only repo, and don't assume an iOS app lives in a `frontend` repo.

### Prototyping mode

`on` or `off` (default `off`). When `on`, [prototyping-mode.md](prototyping-mode.md) applies for every session in the repo: ordinary changes go directly to main without PRs; backlog tasks use branches, automatically merging completed tasks while keeping incomplete work on its branch. The user can also switch it on or off for one session by saying so; that overrides the file for that session only. Change the file only when the user asks.

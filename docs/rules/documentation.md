<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:79e762fe61e2. Edit agent-rules/docs/rules/documentation.md, then run `make rules`; local edits here are not kept. -->
## Documentation

Keep docs up to date with the architecture, including architectural diagrams, in the `docs/` folder. Keep the root directory small (see Root Directory in [code-requirements.md](code-requirements.md)).

- **Rules vs. project docs.** `docs/rules/` holds the shared rules, the same in every project. `docs/project/` holds only that project's settings (`settings.md`) and facts: stack, layout, commands, product terms, roles, deployment targets. Project docs never relax, replace or add rules; a needed change in behavior goes into the shared rules or becomes a setting.
- **Don't modify `docs/rules/` in a project repo.** Its files are copies synced from the agent-rules repo (`~/Sites/agent-rules`) by `make rules`. Don't edit, rename, add or delete them here: the next sync skips or overwrites local edits. To change a rule, edit it in agent-rules, then run `make rules` here (or `make sync-all` in agent-rules for every repo). Project-specific facts go in `docs/project/` instead.
- **Agent loaders.** The root `AGENTS.md` is a short loader that points at `docs/rules/`, `docs/project/` and the feature index; `CLAUDE.md` just imports `AGENTS.md`. Edit the rules and project docs, not `CLAUDE.md`.
- **Services.** Document every internal and external service the project uses, why it is used, and the configuration variables it needs.
- **Planned and shipped work.** Planned work lives in `docs/backlog/` (one file per task) and implemented work in `docs/features/`; see [backlog.md](backlog.md) and [feature-docs.md](feature-docs.md). Split larger initiatives into independently actionable task files rather than writing them into a shared file.
- **Code wins.** When a doc and the code disagree, the code is right. Fix the doc when you touch that area.

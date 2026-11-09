<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:dbcb24a20649. Edit agent-rules/docs/rules/versioning.md, then run `make rules`; local edits here are not kept. -->
## Versioning

Applies only to projects that already have a `VERSION` file at the root. Don't create one.

- **Semver.** `VERSION` holds the version as semver (`major.minor.patch`). Other parts of the app (the UI, a `/version` endpoint, build metadata) load it from that file rather than repeating it.
- **Bump only in `make release`.** Never bump `VERSION` or tag as part of an ordinary change, a turn, or a backlog branch; `make release` does it when a release is cut (see [make-files.md](make-files.md)).
- **Which part to bump.** When it's unclear: bugs, patches and small fixes bump the patch (`x.x.n`); enhancements that affect the UI and new features bump the minor (`x.n.0`). Major bumps are the user's call.

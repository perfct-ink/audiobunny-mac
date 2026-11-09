<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:d235c86eb7ab. Edit agent-rules/docs/rules/feature-docs.md, then run `make rules`; local edits here are not kept. -->
## Feature Docs

One file per feature in `docs/features/<feature_name>.md` (snake_case, named for the feature, not a task number), indexed in `docs/features/README.md`. Write or update it when a task completes (see backlog.md, Completing Work).

- Describe the feature as it exists in the code, not as planned. Read the code first.
- Cover: what it does for users, the API endpoints and models, who can view and who can change it, the web entry points, the tests that cover it, and known limits.
- Put dated `Implemented <date>` and `Not implemented` notes in a short History section at the bottom, so the rest reads as current reference. Say whether it is deployed.
- Say plainly what was not verified (tests, lint, browser, migration) when it wasn't run.
- Extending a feature updates its existing doc; don't add a second one.

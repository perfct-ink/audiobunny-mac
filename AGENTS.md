# audiobunny-mac

This file stays minimal. It loads the shared rules (synced from agent-rules into `docs/rules/`) and this project's settings and facts (`docs/project/`). Edit those, not this file.

## Shared rules

<!-- agent-rules:begin -->
Shared rules from agent-rules, synced by `make rules`. Don't edit them here; docs/project/ holds this repo's settings and facts, not rules.

@docs/rules/project-settings.md
@docs/rules/backend.md
@docs/rules/backlog-mode.md
@docs/rules/backlog.md
@docs/rules/code-requirements.md
@docs/rules/conventions.md
@docs/rules/deployment.md
@docs/rules/design-principles.md
@docs/rules/documentation.md
@docs/rules/feature-docs.md
@docs/rules/frontend.md
@docs/rules/make-files.md
@docs/rules/native.md
@docs/rules/prototyping-mode.md
@docs/rules/versioning.md
<!-- agent-rules:end -->

## Project settings and facts

Settings and facts about this repo (its stack, layout, how to run it, where it deploys). They don't change the shared rules. Add one `@docs/project/<name>.md` line per file.

@docs/project/settings.md

## Features

@docs/features/README.md

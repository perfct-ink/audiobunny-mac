<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:31603dd64a52. Edit agent-rules/docs/rules/code-requirements.md, then run `make rules`; local edits here are not kept. -->
## Code Requirements

General standards for all code. Follow the principles everywhere; stack-specific details (paths, commands, tools) belong in the project's own docs. Don't rewrite working code just to match these rules (see Linting).

### General Coding Standards

#### DRY
Code should not be repeated unless repeating it is measurably more performant (rare). If metaprogramming or a shared abstraction is available, prefer it. When files contain the same or similar functions, consolidate them. Check for an existing helper, component, or data function before writing a new one.

#### Static Data
Any collection of two or more objects belongs in a static data file, not inline in views or controllers.

#### Data Files
Keep data separate from views, like the model in MVC or the data tier in a three-tier design. Each data entity has a data file with parity to the entity.
- Enumerations that mirror an API live with the entity. If the entity's source of truth is another API, keep the data file in sync with it.
- Data-only and pure functions for a single entity (filtering, searching, sorting, aggregating, formatting) live in its data file, which keeps them easy to unit test.
- File names are singular, unless a framework enforces its own naming.

### Linting
All code should be linted to match common style guides, and lint must report no errors. Tests, type checks, and security scans must pass.
- **Existing code:** fix lint findings deliberately, in the code you are already changing. Never reformat or "tidy" unrelated working code.

### Root Directory & Folder Structure
Keep the root directory to as few files as possible. When a frontend and a backend are used together, each lives in its own folder (an exception is a backend that must serve the frontend files from a particular directory). Everything server-related or deployment-related lives in its own folder, as do docs. `README.md` stays at the root, where the code host renders it.

### Web Applications
Applies to projects with the `frontend` or `backend` platform.
- Every web application has a `Dockerfile` and a Docker Compose file, with health checks (see [backend.md](backend.md)).
- Local development never hits live services; use local containers, sandboxes or fakes instead.
- The development database has a seed that gives a good starting point for user acceptance testing.

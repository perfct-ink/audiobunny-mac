<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:9d7cee3dce75. Edit agent-rules/docs/rules/make-files.md, then run `make rules`; local edits here are not kept. -->
# Make Files

make should be used for forgettable tasks that are common development and production workflows.
Every project should have a make file. The make file should provide all initial provisioning and installing dependencies in make setup.

Some examples are:

- make setup - Setup the environment. Install dependencies. Require everything needed to run up.
- make up - Non destructive setup. If running, `make down`. Build and run in development. Keep running attached. Delete previous build if it exists. No need to delete anything if previous build is removed automatically.
- make dev - Run `make dev` and open it.
- make build - Build for development once.
- make running - Check to see if its running.
- make test - Run every test suite.
- make clean - Clean existing builds and artifacts.
- make down - kill app. Stop any containers or background processes it started.
- make help - help for all make commands, grouped by category.
- make all - alias for `make help`
- make deploy - If theres a deployment script that isnt in CI, deploy the app directly.
- make release - Bump the version and tag the release (see [versioning.md](versioning.md)). Only for projects with a `VERSION` file.

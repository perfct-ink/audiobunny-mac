<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:1af018a7f90c. Edit agent-rules/docs/rules/native.md, then run `make rules`; local edits here are not kept. -->
# Native

For macOS/iOS development.

## Makefile

Every native app should have a make file.

```sh
# Building
make dev - Build for development, close it if its open, delete old build, then open the new build.
make build - Build for production.
make clean - Clean existing builds.

make setup - Setup the environment if needed.

make open - Open dev app.
make close - kill the app. Only if native.

# Production
make install - Build for production and install to /Applications folder.
make uninstall - make close. Remove if installed.
make reinstall - make uninstall, make install

# Help
make all - default to run. Same as `make setup` and `make dev`
make help - help for all make commands, grouped by category.
```
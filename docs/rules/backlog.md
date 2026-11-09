<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:4899fc1329d2. Edit agent-rules/docs/rules/backlog.md, then run `make rules`; local edits here are not kept. -->
## Backlog Management

The `/docs/backlog/` directory contains specifications for incomplete work. Each Markdown file represents an independently actionable task. The `/docs/features/` directory documents completed and implemented functionality.

### Task Organization

- Use descriptive, kebab-case filenames (e.g., `add-user-onboarding.md`).
- Do not use sequential task numbers or infer priority from filenames.
- Keep tasks focused, self-contained, and independently implementable whenever possible.
- Each backlog item should describe its objective, requirements, and acceptance criteria.
- Use YAML frontmatter for optional metadata such as `priority`, `depends_on`, and `components`.
- Avoid modifying unrelated backlog files.

### Picking Up Work

1. Review `/docs/backlog/` for available tasks.
2. Check task dependencies and any existing branches or pull requests to avoid duplicating work.
3. Prefer high-priority tasks that can be completed independently.
4. Before starting, identify files and components likely to be affected.
5. Avoid working on tasks that overlap with another agent's active changes.
6. Use a dedicated Git branch or worktree for each task.
7. If multiple agents may claim tasks concurrently, use an atomic remote claim mechanism. Checking for an existing branch alone does not guarantee exclusive ownership.

### Implementation

1. Read the selected backlog specification completely.
2. Inspect the relevant code and existing feature documentation.
3. Implement the requirements while following existing project conventions.
4. Add or update tests as appropriate.
5. Verify that all acceptance criteria are satisfied.
6. Keep changes scoped to the selected task.
7. Do not modify other agents' branches or worktrees.

### Completing Work

1. Once implementation and tests are complete, update the relevant documentation in `/docs/features/`.
2. If the task introduces a new feature, create a corresponding feature document.
3. If the task modifies an existing feature, update its existing documentation instead.
4. Remove the completed specification from `/docs/backlog/`.
5. Include the documentation updates and backlog removal in the same pull request as the implementation.
6. Consider the task complete only after its changes have been successfully merged.

### Creating Backlog Items

- Create a new Markdown file in `/docs/backlog/` for each new task.
- Use a unique, descriptive filename rather than a numerical identifier.
- Check for existing backlog items to avoid duplicates.
- Split large tasks into smaller, independently executable tasks when practical.
- Document dependencies explicitly when tasks must be completed in a particular order.
- Do not implement newly discovered work outside the current task's scope; create a backlog item for it instead.

### Conflict Prevention

- Never use a shared `/docs/backlog.md` file to track individual tasks or execution status.
- Do not rename or reorganize unrelated backlog files.
- Avoid modifying shared configuration or infrastructure files unless required.
- Prefer tasks that affect different components when multiple agents are working concurrently.
- Coordinate overlapping changes through Git branches and pull requests.
- Rebase onto the latest main branch and rerun relevant tests before merging, then rebase merge (see Branches in [conventions.md](conventions.md)).

### Guiding Principles

- **Backlog files describe intended functionality.**
- **Feature files describe implemented functionality.**
- **Code represents actual behavior.**
- **Tests verify correctness.**
- **Git and pull requests track execution; no separate task database is required.**
- **Minimize shared-file modifications to reduce conflicts between agents.**
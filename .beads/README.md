# Beads / Gas Town Workflow

Current repo guidance as of 2026-04-24.

This repo uses `bd` (Beads) for dependency-aware issue tracking and Gas Town
for multi-agent dispatch when the checkout is inside a town. Current Beads
storage is Dolt-backed. The runtime database lives under `.beads/dolt/` and is
ignored by git; tracked `.beads/` files are configuration, metadata, prime
context, and lightweight exports.

## Startup

```bash
bd prime          # Print agent workflow context
gt prime          # Restore Gas Town role context when in a town
gt mol status     # Check your hook
gt mail inbox     # Check mail if your hook is empty
bd ready          # Find unblocked Beads work
```

If `gt mol status` shows hooked work, that work is the assignment. Execute it.

## Work Commands

```bash
bd create "Title" --type task --priority 2
bd update <id> --claim
bd show <id>
bd close <id> --reason "Completed"
gt sling <id> [target]
gt done
```

Use `bd update <id> --claim` for Beads-only work. Use `gt sling` when work
should land on an agent hook and start immediately.

## Maintenance

```bash
bd doctor
bd hooks install --force
bd worktree info
bd vc status
bd dolt commit
bd dolt pull
bd dolt push
```

`bd sync` is a compatibility command under the Dolt backend. The CLI reports it
as a no-op because Dolt persists writes directly.

## Worktrees

Prefer `bd worktree create` for new worktrees. It creates a local
`.beads/redirect` file pointing at the shared Beads database. The redirect is
intentionally ignored and must stay local. For manually-created worktrees, run
`bd worktree info` and keep `BEADS_NO_DAEMON=1` for direct access.

## References

- Canonical Beads repo: <https://github.com/gastownhall/beads>
- Published docs: <https://gastownhall.github.io/beads/>

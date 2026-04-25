# Gas Town Integration

Gas Town is a multi-agent workspace manager that coordinates AI agents working on shared codebases. The ogent Gas Town integration brings this coordination directly into Emacs, allowing you to manage agent workflows, track issues, and communicate with other agents without leaving your editor.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Key Concepts](#key-concepts)
- [Commands Reference](#commands-reference)
  - [Main Dispatch Menu](#main-dispatch-menu)
  - [Status Buffer](#status-buffer)
  - [Mail Commands](#mail-commands)
  - [Issue Tracking](#issue-tracking)
  - [Session Management](#session-management)
- [Keybindings](#keybindings)
- [Modes](#modes)
- [Troubleshooting](#troubleshooting)

## Prerequisites

Gas Town integration requires:

1. **gt CLI**: The Gas Town command-line tool must be in your PATH
2. **bd CLI**: The Beads issue tracking CLI must be in your PATH
3. **A Gas Town workspace**: Your project must be part of a Gas Town town structure

To verify your setup:

```bash
which gt                    # Should return path to gt executable
which bd                    # Should return path to bd executable
gt status --json --fast     # Fast town snapshot (run from town root)
```

## Quick Start

1. **Open the dispatch menu**: `M-x ogent-gastown-dispatch` or `SPC e G G`

2. **Check your hook** (assigned work): `M-x ogent-gastown-show-hook` or `SPC e G h`

3. **View status buffer** (magit-style overview): `M-x ogent-gastown-status` or `SPC e G s`

4. **Find ready work**: `M-x ogent-gastown-show-ready` or `SPC e G r`

5. **Claim an issue**: `M-x ogent-gastown-claim-issue` or `SPC e G C`

## Key Concepts

### Town Structure

A Gas Town workspace (the "town") contains multiple **rigs**:

```
~/gt/                           # Town root
├── mayor/                      # Coordinator agent
├── <rig>/                      # Project container
│   ├── .beads/                 # Issue tracking
│   ├── polecats/               # Worker worktrees
│   ├── refinery/               # Merge queue
│   └── witness/                # Worker manager
```

### Beads (Issue Tracking)

Beads is a git-native issue tracker. Issues have:
- **ID**: Prefixed identifier (e.g., `gt-abc`)
- **Status**: open, in_progress, blocked, closed
- **Dependencies**: Issues can block other issues
- **Molecules**: Workflow templates attached to issues

### Hook

Your "hook" is your current assignment. When work is on your hook:
- You're expected to execute it
- Other agents know you're working on it
- Session handoffs preserve hook state

### Mail

Agents communicate via mail messages. Mail can contain:
- Work assignments
- Handoff notes for session continuity
- Coordination requests
- Status updates

### Convoy

A convoy groups related issues for batch work. Convoys help track:
- Progress across multiple issues
- Parallel work distribution
- Completion milestones

## Commands Reference

### Main Dispatch Menu

**`ogent-gastown-dispatch`** (`SPC e G G`)

Opens a transient menu with all Gas Town operations organized by category:
- **Status**: View hook, mail, convoy, workers
- **Issues**: Ready work, claim, close
- **Mail**: Read, send messages
- **Session**: Prime, handoff

### Status Buffer

**`ogent-gastown-status`** (`SPC e G s`)

Opens a magit-style buffer showing:
- Current hook status
- Unread mail count
- Active convoy progress
- Rig details with inline beads stats (ready/in-progress/blocked counts)
- Worker states (polecats and crew)
- Active workspace indicator (`WS:<path>`) in the header line

The buffer is interactive - press `TAB` to expand sections, `RET` to act on items.
The workspace indicator is intentionally strict. If you need to retarget, reopen
status from the desired town directory (or set `GT_ROOT`/`GT_TOWN` first).

#### Fetch Architecture

The status buffer runs six parallel async fetches on every refresh:

| Section | Command | Data |
|---------|---------|------|
| Hook | `gt hook status mayor/ --json` | Current hook assignment |
| Mail | `gt mail inbox --json` | Inbox messages |
| Convoy | `gt convoy list --json` | Active convoys |
| Workers | `gt polecat list --all --json` | Polecat states |
| Town Status | `gt status --json --fast` | Rig list, beads stats, deacon, witnesses |
| Crew | `gt crew list --all --json` | Crew worker list |

The hook target is resolved from the active Gas Town role context when available;
`mayor/` is the fallback target shown here.

The town status fetch uses `--fast` by default. The `--fast` flag skips expensive
operations (overseer mail counts, hook discovery per-rig, merge queue summaries)
while keeping the data needed for the status buffer display. Rig-level details like
beads stats come from preloaded agent beads rather than per-rig lookups.

Each fetch is independent. If one fails (timeout or error), the others continue and
the buffer still renders the sections that succeeded. Failed sections display
placeholder text (e.g., "No messages", "No work hooked") rather than error messages.
The default timeout is 30 seconds per fetch.

Use `g` to refresh and `G` to force-refresh (clears cache first).

### Mail Commands

**`ogent-gastown-show-mail`** (`SPC e G m`)

Displays your inbox with unread messages highlighted.

**`ogent-gastown-send-mail`** (`SPC e G M`)

Interactive mail composition. Prompts for:
- Recipient address (e.g., `refinery/`, `polecat/alpha`)
- Subject line
- Message body

### Issue Tracking

**`ogent-gastown-show-ready`** (`SPC e G r`)

Lists issues that have no blockers and are ready to work on.

**`ogent-gastown-show-issue`** (`SPC e G i`)

Prompts for an issue ID and displays full details including:
- Description and acceptance criteria
- Dependencies (blocking/blocked by)
- Attached molecules
- Comments and history

**`ogent-gastown-claim-issue`** (`SPC e G C`)

Claim an issue to work on. This:
1. Sets status to `in_progress`
2. Assigns you as the worker
3. Hooks the issue (makes it your current assignment)

**`ogent-gastown-close-issue`** (`SPC e G x`)

Mark an issue as complete. Prompts for:
- Issue ID
- Completion reason/notes

### Session Management

**`ogent-gastown-prime`** (`SPC e G p`)

Prime your session by:
1. Checking your hook for assigned work
2. Loading beads context
3. Syncing with remote state

Run this at the start of each session.

**`ogent-gastown-done`** (`SPC e G d`)

End your session cleanly:
1. Sync beads changes
2. Create handoff notes
3. Push to remote

**`ogent-gastown-show-hook`** (`SPC e G h`)

Display what's currently on your hook (your assignment).

**`ogent-gastown-show-convoy`** (`SPC e G c`)

Open the convoy inspector.  Delegates to the magit-style convoy
inspector (`ogent-convoy-inspect`) which shows detailed convoy
metadata and tracked issues.  Falls back to a plain listing if
the inspector is unavailable.

## Keybindings

### Doom Emacs

All Gas Town commands are under `SPC e G`:

| Key | Command | Description |
|-----|---------|-------------|
| `G` | `ogent-gastown-dispatch` | Main dispatch menu |
| `s` | `ogent-gastown-status` | Status buffer |
| `h` | `ogent-gastown-show-hook` | Show current hook |
| `m` | `ogent-gastown-show-mail` | Show inbox |
| `M` | `ogent-gastown-send-mail` | Send mail |
| `c` | `ogent-gastown-show-convoy` | Inspect convoy |
| `r` | `ogent-gastown-show-ready` | Ready issues |
| `i` | `ogent-gastown-show-issue` | Show issue details |
| `C` | `ogent-gastown-claim-issue` | Claim issue |
| `x` | `ogent-gastown-close-issue` | Close issue |
| `p` | `ogent-gastown-prime` | Prime session |
| `d` | `ogent-gastown-done` | Session done/handoff |

### Vanilla Emacs

Use `C-c . G` prefix for Gas Town commands in vanilla Emacs keybinding setup.

## Modes

### ogent-gastown-mode

A minor mode that shows Gas Town status in the header line:
- Hook status (what you're working on)
- Unread mail count
- Convoy progress

Enable with `M-x ogent-gastown-mode` in any buffer.

### ogent-gastown-global-mode

Globally enables `ogent-gastown-mode` in all buffers. Add to your config:

```elisp
(ogent-gastown-global-mode 1)
```

## Troubleshooting

### "gt command not found"

**Problem:** Gas Town CLI not installed or not in PATH.

**Solution:**
1. Install the gt CLI tool
2. Verify it's in PATH: `which gt`
3. If using a shell wrapper, ensure Emacs inherits the PATH:
   ```elisp
   (when (memq window-system '(mac ns x))
     (exec-path-from-shell-initialize))
   ```

### "bd command not found"

**Problem:** Beads CLI not installed or not in PATH.

**Solution:**
1. Install the bd CLI tool
2. Verify with `which bd`
3. Same PATH considerations as above

### "Not in a Gas Town workspace"

**Problem:** Current directory is not part of a town.

**Solution:**
1. Navigate to a directory within a Gas Town town
2. Verify with `gt status` in terminal
3. If working across multiple towns, set `GT_ROOT` or `GT_TOWN` before opening status
4. Check that the town structure exists (`.beads/` directories)

### Status buffer empty or showing placeholder text

**Problem:** Status buffer shows "No work hooked", "No messages", or other placeholder
text where you expect real data.

This can mean either (a) the data genuinely doesn't exist, or (b) the underlying
fetch failed silently. The status buffer converts fetch failures to `nil`, which
renders the same placeholder text as legitimately empty data.

**Diagnosing:**

1. Test each fetch command individually in a terminal to isolate which one is failing:

   ```bash
   # Fast town snapshot (rig list, stats, deacon, witnesses)
   timeout 12 gt status --json --fast

   # Hook status
   timeout 12 gt hook status mayor/ --json

   # Mail inbox
   timeout 12 gt mail inbox --json

   # Convoy list
   timeout 12 gt convoy list --json

   # Worker list
   timeout 12 gt polecat list --all --json

   # Crew list
   timeout 12 gt crew list --all --json
   ```

2. If a command hangs (no output before timeout), it's likely blocking on a
   slow operation. The status buffer uses a 30-second timeout (configurable via
   `ogent-gastown-timeout`).

3. If a command returns an error or invalid JSON, the status buffer silently
   drops that section's data.

4. Check `*Messages*` in Emacs for any process-level errors.

**Quick fix:** Run `ogent-gastown-refresh` (`g` in the status buffer) to retry
all fetches. Use `ogent-gastown-refresh-force` (`G`) to also clear the cache.

### Diagnosing stalled gt commands

**Problem:** A `gt` subcommand hangs or takes too long, causing status sections
to appear empty.

**Solution:**

1. Compare fast vs regular status to isolate the slow path:

   ```bash
   time timeout 12 gt status --json --fast   # Should be quick
   time timeout 12 gt status --json          # Includes expensive lookups
   ```

   If `--fast` works but regular doesn't, the bottleneck is in mail lookups,
   hook discovery, or merge queue summaries (all skipped by `--fast`).

2. Test individual section commands (see list above) to find which one hangs.

3. Check for workspace issues:

   ```bash
   gt doctor        # Run health checks
   gt whoami        # Verify identity resolution
   ```

4. If `gt status --json --fast` itself fails, verify you're running from
   within a valid town directory or that `GT_ROOT`/`GT_TOWN` is set correctly.

### Mail not sending

**Problem:** `ogent-gastown-send-mail` fails.

**Solution:**
1. Verify recipient address format (e.g., `refinery/`, `polecat/name`)
2. Check `gt mail send` works in terminal
3. Look for errors in `*Messages*` buffer

### Hook not updating

**Problem:** Hook shows stale assignment.

**Solution:**
1. Run `ogent-gastown-prime` to refresh
2. Check `gt hook` in terminal
3. Verify beads sync: `bd sync --status`

## Integration with ogent

Gas Town commands integrate with the rest of ogent:

- **Issue context**: When viewing an issue, you can pin its description as context for AI requests
- **Codemap**: Use `ogent-codemap-generate` to create context maps for issue work
- **Completions**: AI responses can reference beads issues using `@issue-id` syntax
- **Edit workflow**: Code edits from AI can be tracked in beads for review

See [getting-started.md](getting-started.md) for general ogent usage.

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
which gt     # Should return path to gt executable
which bd     # Should return path to bd executable
gt status    # Should show town status (run from town root)
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
- Worker states (polecats)

The buffer is interactive - press `TAB` to expand sections, `RET` to act on items.

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

Show active convoy status and progress.

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
| `c` | `ogent-gastown-show-convoy` | Show convoy |
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
3. Check that the town structure exists (`.beads/` directories)

### Status buffer empty

**Problem:** Status buffer shows no data.

**Solution:**
1. Run `ogent-gastown-prime` to sync state
2. Check `gt status` works in terminal
3. Verify you're in the correct rig

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

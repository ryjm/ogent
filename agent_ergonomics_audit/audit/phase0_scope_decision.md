# Pass 1 Scope Decision

**Mode.** `full`, the skill's default, continuing the user's improvement request.
**Target.** `/workspace/ogent`, https://github.com/ryjm/ogent.
**Workspace.** `/workspace/ogent/agent_ergonomics_audit/`, inside the repository.
**Target branch.** `master`; commit and push directly, without pull requests.
**Triangulation appetite.** Independent peer agents using the available model.
Claude/Gemini runners are unavailable; no cross-model agreement is claimed.
**CASS appetite.** `skip`; the binary and session history are unavailable.
**Date.** 2026-10-08.

## Must-not-touch

- Provider logins, credentials, and live inference are excluded by the user.
- Preserve existing model choices, configurations, and positional tool APIs.
- Use `br` for tracker mutations; commit its JSONL export, never databases.
- Serialize production edits because Agent Mail is unavailable.

## Deprecation policies

Add optional structured output and introspection without removing human output.
Reject invalid or ambiguous arguments with corrective guidance. Preserve existing
successful tool results where practical; document intentional correctness fixes.

## Out-of-scope feature work

ogent is an Emacs package, not a standalone CLI. Apply the skill's
`references/methodology/DSL-AND-SDK-AUDIT.md` extension to the six default tools,
their shared registry/execution boundary, doctor batch API, and Makefile commands.
Do not invent a standalone ogent executable or change agent features to satisfy
CLI-specific checks. Inventory and score the focused primary surface set;
secondary Armory/UI commands remain outside this pass.

## Toolchain and helper fallbacks

Use existing Emacs 29.1/30.2 Docker environments and cached real dependencies.
No build toolchain installation is needed. Missing helper skills use the shipped
inline fallbacks; native lint/ERT replace UBS, peer review replaces triangulation,
and production edits are serialized. JSM authentication is already available.

## Resumed-pass notes

First ergonomics pass. Baseline is `72016bb66928a20a49238266645abde583fa595d`.
The preceding reality-check repairs and their passing eight-job CI are complete.

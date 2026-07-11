# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GPT-5.6 model family (`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`) and
  Claude Sonnet 5 in the model registry; `gpt-5.6-sol` is the new default.
- `ogent-model-picker` (`C-c . @`): an oh-my-pi style model cockpit for
  switching the session/buffer model, setting the default, assigning
  per-task model roles, pinning models onto Org subtrees, and browsing the
  registry as an Org table (`ogent-models-browse`).
- Model roles (`ogent-model-roles`): map tasks (`edit`, `codemap`, `fast`,
  `deep`) to models or alias roles, with per-project overrides via
  `ogent-project-model-roles` in `.ogent.el`.
- Layered model resolution (`ogent-models-effective`): inherited
  `OGENT_MODEL` Org property > task role > gptel session model > project
  model > default.  Org Babel blocks accept `@role` designators in `:model`
  and honor the inherited property.

### Changed
- Onboarding model catalogs now resolve from `ogent-model-registry` (single
  source of truth) instead of duplicating ids and descriptions.
- Bumped minimum transient to 0.13.5 and Org to 9.8.7.

### Fixed
- `ogent-theme-flash` no longer errors when `ogent-theme-animation-speed`
  is `none`.

## [0.1.0] - 2026-06-17

### Added
- Org-first AI prompting with `@handle` context references, pinned context, and codemap-backed project slices.
- gptel-backed model and preset selection, including provider onboarding for OAuth and API-key flows.
- Companion buffers and structured response blocks for working on prompts outside Org source trees.
- Inline edit review flows with diff rendering and accept/reject mechanics for generated code changes.
- Codemap generation and project exploration helpers for navigating larger codebases from inside Emacs.
- Armory views for agents, conversations, jobs, and related operational state.
- A modularized codebase split into focused façade-backed modules instead of a single monolithic entry file.

[Unreleased]: https://github.com/ryjm/ogent/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ryjm/ogent/releases/tag/v0.1.0

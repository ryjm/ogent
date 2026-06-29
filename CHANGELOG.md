# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Anthropic OAuth (Claude Pro/Max) requests now work with current gptel releases: the request and curl-args advice tolerate gptel's widened function arities, and the backend emits Bearer OAuth headers instead of leaking the default `x-api-key` header.
- Magit-Section 4.5.0+ compatibility: collapsible-section visibility indicators use the new `magit-section-visibility-indicators` variable when present, falling back to the deprecated singular variable on older Magit.

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

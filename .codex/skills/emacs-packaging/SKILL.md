---
name: emacs-packaging
description: Verify native Emacs installation, autoloads, supported dependency versions and optional integrations without providers.
---

# Emacs packaging and compatibility

Read package headers, repository specs, CI matrix and installation documentation. Derive the supported Emacs and dependency floor from the package contract. Verify against actual minimum and current versions, recording exact loaded library paths and versions. Test helpers or stubs do not prove a real package boots.

Use isolated `emacs -Q` sessions and owned stores. Verify `require`, generated autoloads, entry commands, Custom groups and the documented load-path/package recipe. Run strict byte compilation, check-declare, checkdoc and indentation. New files must be included in the build discovery mechanism. Exercise offline process/HTTP fixtures for runtime behavior without provider login or inference.

Boot with optional packages absent, then test available Magit sections, completion and Evil hooks present and loaded in both relevant orders. Confirm graceful fallback, idempotent setup and local bindings. Respect installed Org/Transient rather than silently assuming bundled versions. Inspect archive contents and dependency declarations; do not introduce a required integration to improve a visual detail.

Document the actual compatibility matrix, skipped/expected failures, installation commands and limitations. After an authorized push verify all required CI jobs for the exact commit SHA. Follow the user's publication preference; this repository uses master directly, with no PR. Never claim successful installation, Doom integration, provider support or CI from an unexecuted command or an unrelated run.

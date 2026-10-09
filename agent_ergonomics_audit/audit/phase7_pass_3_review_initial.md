# Phase 7, pass 3: initial independent correctness review

Reviewed on 2026-10-08 while the second-pass implementation was being integrated.
Read `AGENTS.md`, `specs/style-guide.org`, and the tool execution/effects/ledger
sections of `specs/architecture.org`. Source and tests were read only. Probes ran
with Emacs 30.2 in `ogent-fixes`, loading `test/ogent-test-helper.el` explicitly
and source-loading the project. No providers, credentials, network calls, broad
makem runs, Beads mutations, or commits were used. References below identify the
code observed during this review; integration can move line numbers.

## Confirmed findings sent to the integration owner

1. **P1: stderr draining can hang past the requested timeout.**
   `lisp/ogent-tool-process.el:93` cancels the timer, then lines 100–102 drain the
   separate stderr pipe until no output arrives. A shell can exit while a
   background descendant continuously writes stderr. Reproduction:
   ```elisp
   (ogent-tool-process-bash
    "printf parent; (while :; do printf x >&2; done) & exit 0" nil 0.2)
   ```
   This did not return before an external five-second timeout killed Emacs.
   The equivalent stdout writer returned in 0.013 seconds. Bound the drain and
   close or terminate inherited descendant pipes before final completion.

2. **P1: registry replacement during approval executes unapproved code.**
   `lisp/ogent-tool-execution.el:200` checks the captured registry snapshot
   before the approval prompt. Lines 203–214 then dispatch through the current
   registry without checking again. A probe registered a `changing` tool with
   `:confirm t`; the approval boundary replaced its same-named registry entry
   with a different function and critical network effects, then returned
   `approve`. Calling the original wrapper returned `"replacement ran"`.
   Recheck the original snapshot after approval and before every dispatch path.

3. **P2: shell failures are recorded as successful ledger terminals.**
   `lisp/ui/ogent-ui-toolcalls.el:269` invokes the structured result function,
   and line 271 records `failure=nil` unconditionally for returned values.
   The dispatcher classifies process failure afterward. Actual calls:
   ```elisp
   (ogent-agent-call "bash" '(:command "printf out; exit 7"))
   (ogent-agent-call "bash" '(:command "printf out; sleep 3" :timeout 0.1))
   ```
   Returned typed `command_failed` and `timeout` results respectively, but
   their intercepted `ogent-ledger-record-tool-finish` calls both had
   `failure=nil`. Apply the same process failure classification in the ledger
   owner without adding duplicate terminal records. The newly added async
   owner at `lisp/ogent-tool-execution.el:102` has the same distinction: it
   records failure only when the callback's failure parameter is present.

4. **P2: ordinary wildcards inside recursive globs cross directories.**
   `lisp/ogent-tools.el:326` embeds `wildcard-to-regexp`'s `.*` directly in a
   path-component regexp. With `foo/direct.el` and `foo/deep/nested.el`:
   ```elisp
   (ogent-tools--glob-files "**/foo/*.el" root)
   ```
   Returned both files. A single `*` should match one component, so only
   `foo/direct.el` belongs. Use slash-excluding wildcard translation inside
   ordinary components while retaining recursive `**` semantics.

5. **P2: GNU fallback accepts invalid regexes when no files qualify.**
   `lisp/ogent-tool-process.el:455` uses `xargs -r`, which never invokes grep
   for an empty filename set. With only ripgrep discovery disabled at the
   executable boundary, actual GNU grep/xargs execution produced successful
   empty pages for both:
   ```elisp
   (ogent-tool-process-grep "[" empty-directory)
   (ogent-tool-process-grep "[" populated-directory "*.notpresent")
   ```
   Regex syntax must still be validated when there are no candidates, as the
   ripgrep path does. Preserve valid no-match searches as success.

6. **P2 contract limitation: final newlines cannot be reconstructed.**
   `lisp/ogent-tool-results.el:47` removes the final empty split item, and
   line 73 returns content without a final separator. Files containing `"abc"`
   and `"abc\n"` both return one identical line and `:content "abc"`; only
   their opaque snapshots differ. There is no final-newline field. Preserve
   this fact in the structured contract if callers must reproduce source text.

## In-progress gaps identified, with owner already integrating fixes

- `ogent-agent--tool` omitted SDK `:result-args`, hiding `column`, `offset`, and
  `limit` from discovery. Guide/result-contract text still described all tool
  results as text, and early recovery text named an undefined descriptor.
- The initial synchronous SDK path invoked generic `:async t` functions
  without a callback, yielding a wrong-number-of-arguments terminal error.
  A later probe of the newly added async API completed once despite duplicate
  completion and an error after completion; this new behavior passed.

## Other probes

Read and JSON continuations froze absolute paths correctly in the existing
focused tests. Tried malformed continuation entries produced actionable
`user-error` responses rather than execution. Initial invalid-byte file reads
were automatically decoded by Emacs and serialized successfully; no JSON
failure was established there. The stdout/stderr budget, process timeout
partial output, and generic callback completion paths were inspected. No
finding based only on a hypothetical failure is included above.

Ad-hoc reproducible scripts are `/tmp/ogent-second-pass-review.el`,
`/tmp/ogent-second-pass-review2.el`, `/tmp/ogent-second-pass-review3.el`,
`/tmp/ogent-second-pass-review4.el`, and
`/tmp/ogent-second-pass-stderr-review.el` in the review workspace/container.

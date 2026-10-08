# Task 07: Compile a deliberately failing Emacs fixture command and detect failure from exit status.

**Status.** COMPLETE

**Steps.** 1 captured command invocations (1 Emacs SDK invocations).

**First-try success?** YES — initial functional strategy succeeded without correction; required pages, separate requested operations, and validation do not count as retries.

**What worked.** The SDK async shell tool ran timeout 10s emacs -Q --batch -f batch-byte-compile broken.el in a newly created isolated fixture. The invalid fixture produced End of file during parsing. The documented done callback supplied integer 1, which was propagated with kill-emacs; the captured outer process exit code was 1.

**What was confusing.** The async callback is needed for a clean integer status. This task compiled only the fixture and neither compiled nor cleaned repository files. No repository Makefile was read or copied.

**Round-trips to completion.** 1 (all captured command invocations).

# Task 05: Replace same in a two-occurrence fixture without changing the wrong occurrence, and explicitly replace all only in a fixture.

**Status.** COMPLETE

**Steps.** 2 captured command invocations (2 Emacs SDK invocations).

**First-try success?** YES — initial functional strategy succeeded without correction; required pages, separate requested operations, and validation do not count as retries.

**What worked.** The registry says old_string must be unique. Using first: same as context changed only the intended first line and preserved second: same, verified through the read-file tool. A separate original fixture used replace_all=t and read-back showed both occurrences changed.

**What was confusing.** The help-only discovery was sufficient for the chosen safe path. An ambiguous bare same replacement without replace_all was not attempted, so this simulation makes no claim about the ambiguity guard itself.

**Round-trips to completion.** 2 (all captured command invocations).

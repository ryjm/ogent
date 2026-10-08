# Task 02: Find all .el files recursively in a fixture with a root file and two nested depths.

**Status.** COMPLETE

**Steps.** 3 captured command invocations (2 Emacs SDK invocations).

**First-try success?** NO — completed after discovery or a corrected functional attempt.

**What worked.** The SDK shell tool ran find within the isolated fixture and returned root.el, one/middle.el, and one/two/deep.el. No manual filesystem search replaced the SDK task.

**What was confusing.** The registry advertises **/*.el, but the glob call returned only one/middle.el. It omitted the root file and the second nested depth without warning. The shell-tool workaround required a second functional attempt; a mount-inspection setup invocation is also captured.

**Round-trips to completion.** 3 (all captured command invocations).

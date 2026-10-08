# Task 04: Search a fixture for a pattern beginning with a dash and distinguish no matches from an invalid [ regex.

**Status.** COMPLETE

**Steps.** 4 captured command invocations (4 Emacs SDK invocations).

**First-try success?** NO — completed after discovery or a corrected functional attempt.

**What worked.** After the literal -dash search failed, the equivalent regex [-]dash returned the intended line. missingword returned No matches found. The invalid [ regex returned an Invalid regular expression diagnostic and the streaming completion message reported child exit 2, distinguishable from no-match exit 1.

**What was confusing.** The leading-dash pattern was parsed as a grep option and its seven diagnostic lines were labeled as seven matches. The invalid regex diagnostic was labeled as one match. Both failures left the outer Emacs exit code at 0; interpreting diagnostics and the streaming exit message was necessary.

**Round-trips to completion.** 4 (all captured command invocations).

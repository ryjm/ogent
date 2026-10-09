# Second implementation pass: fresh-eyes review log

Baseline: `b3caf9300c7336ef812ed061158f851c5a47ccf7`.
Verified production freeze: `5d07d807bc85a093725db24e33996b4af690ec0f`.
Reviewers run independently and delegate production corrections to the root
integrator. Earlier unclean rounds and failing reproductions remain preserved.

| Round | Outcome | Evidence |
|---|---|---|
| Initial | Unclean; bounded stderr/process cleanup and contract integration corrections | [Report](phase7_pass_3_review_initial.md) |
| 2 | Unclean; six verified integration defects corrected | [Report](phase7_pass_3_review_round2.md) |
| 3 | Unclean; two verified frozen-batch/filter defects corrected | [Report](phase7_pass_3_review_round3.md) |
| 4 | Unclean; mutable object snapshots and Unicode filter parity corrected | [Report](phase7_pass_3_review_round4.md) |
| 5 | Clean at intermediate 9ac13b2; 188 focused tests on each runtime and independent 560-match engine parity | [Report](phase7_pass_3_review_round5.md) |
| 6 | Unclean; equivalent filters changed file-symlink scope; root also confirmed late-NUL binary mismatch | [Report](phase7_pass_3_review_round6.md) |
| 7 | Unclean; real ledger storage failure suppressed async terminal delivery on both runtimes | [Report](phase7_pass_3_review_round7.md) |
| 8 | Unclean; relative ledger paths split start/finish across projects at async completion | [Report](phase7_pass_3_review_round8.md) |
| 9 | Clean on a2fa8ce; 108 focused checks plus one independent overlapping-ledger check per runtime, zero skips | [Report](phase7_pass_3_review_round9.md) |
| 10 | Clean on a2fa8ce; 108 focused checks plus one independent real-IO probe per runtime; 218 final passes, two corrected reviewer-fixture failures preserved | [Report](phase7_pass_3_review_round10.md) |
| 11 | Unclean on021: matched raw-byte filename silently dropped by glob metadata filtering, reproduced on both runtimes | [Report](phase7_pass_3_review_round11.md) |
| 12 | Unclean onff4: empty/excluded raw-byte roots reflected as success in plist but unsupported in JSON, reproduced on both runtimes | [Report](phase7_pass_3_review_round12.md) |
| 13 | Unclean onb7: raw search filter enters next-page args, native success while JSON cannot retain results; source and bytecode reproductions on both runtimes | [Report](phase7_pass_3_review_round13.md) |
| 14 | Clean on5d07: broad source review plus 54 selected source, strict compiled and actual-gptel checks across both runtimes; zero skips | [Report](phase7_pass_3_review_round14.md) |
| 15 | Clean on5d07: independent broad caller review, 68 selected ERT invocations across current/minimum actual dependencies and both runtimes, plus two build contracts; zero skips | [Report](phase7_pass_3_review_round15.md) |

The search follow-up shares candidate scope across GNU grep and ripgrep and
classifies whole-file raw NUL bytes before counting text matches. The ledger
follow-up retains completed data, reports storage failure separately, delivers
one terminal callback and completes streaming cleanup. Its focused checks pass
210/210 plus four existing UI checks on both Emacs versions; these do not replace
the final native gate. [Ledger evidence](evidence/pass_3/ledger_recovery/README.md).
The subsequent context fix preserves each call's destination and enabled state
without binding tool or callback context. Its 213 focused tests and four existing
UI checks pass on both versions; three context regressions fail on 10f and pass
on a2fa. [Context evidence](evidence/pass_3/ledger_context/README.md).

Round 5 preserves an initial cancellation fixture that raced natural completion;
its corrected live-process probe verifies the actual cancellation contract.
Source/bootstrap failures in any review are retained with their successful
source-forced reruns. They are not counted as passing production checks.

## Calibrated prompts, verbatim

1. Carefully read over all of the new code you just wrote and other existing code you just modified with "fresh eyes" looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover.
2. Sort of randomly explore the code files in this project, choosing code files to deeply investigate and understand and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, I want you to do a super careful, methodical, and critical check with "fresh eyes" to find any obvious bugs, problems, errors, issues, silly mistakes, etc. and then systematically and meticulously and intelligently correct them. Be sure to comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in the AGENTS.md file.
3. Ok can you now turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues, etc. and carefully diagnose their underlying root causes using first-principle analysis and then fix or revise them if necessary? Don't restrict yourself to the latest commits, cast a wider net and go super deep!

The explicit review-only assignments route all discovered production corrections
to the integrator rather than allowing concurrent edits. Any substantive change
resets the two-clean-round streak. Full native checks follow the second clean
round; focused test results do not substitute for them.

Rounds 9 and 10 were consecutively clean on the intermediate a2fa source.
Its full native matrix passed seven checks and failed strict lint on two warning
issues. The warning fixes invalidated that freeze. Round 11 then reproduced the
raw-filename glob omission on021. A separate actual-gptel encoding probe exposed
an Emacs30 UTF-8 byte-string nesting failure. The ff4 repair validates matched
filenames before metadata filtering and normalizes serialized JSON text for
nested transport. Both fixes pass focused compiled checks on both runtimes.
Round12 then identified raw roots that did not expose matching files. The b7
repair validates resolved roots and reflected glob patterns before enumeration
or search target classification. Its nine compiled focused checks pass on both
versions. Round13 exposed raw search filters retained in continuation args. The5d07
repair validates both pattern and filter text before any query; ten compiled
focused checks pass on each runtime. Rounds14/15 are consecutively clean on the
same5d07 source, with unchanged source/index guards. All eight full native checks
pass after those reviews, with unchanged source SHA/fingerprint. Both supported
versions run 3,236 tests with zero unexpected results; full suites retain 18/19
platform-dependent skips. Actual current/minimum offline dependencies each run
206 tests, with zero unexpected results and 2/3 skips. Optional `ubs` remains unavailable, as recorded in
[optional-tool status](verification/pass_3/ubs.json).

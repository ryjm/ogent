# Second-pass score regression investigation

Measured source: `5d07d807bc85a093725db24e33996b4af690ec0f`.
Reviews exposed search scope, ledger and Unicode transport defects that were
repaired; this source has eleven complete baseline/current regression proofs. Numerical
nonregression and behavioral verification remain separate evidence.

No paired aggregate surface regresses by more than 50 points. All nineteen
paired surface changes are nonnegative under consistent applicability. Original
independent judgments were retained after shared incremental checks of later
repairs; the final source did not receive two new blind numerical readings.

Comparing historical pass 2 directly to pass 4 would mix rubric judgments with
source changes. Primitive method aliases, raw mutation safety, bytecode cleanup
and subprocess variability were interpreted differently. That apparent
regression is not dismissed: the original rows are preserved, genuine archived
baseline probes are rerun, and [paired calibration](rubric_reconciliation_pass_3.md)
records the criteria and dissent. The paired baseline is pass 3; post is pass 4.

Behavioral regression evidence is stronger than numerical scoring: all eleven
recommendation wrappers fail against archived baseline and pass against the
unchanged final source, with selected/executed counts, no skips/timeouts, and
fixture/source hashes checked. See [proof](verification/pass_3/regression_proof.json)
and [independent integrity check](verification/pass_3/regressions/integrity_check.json).
The final replay also completes all nine canonical workflows; it is a repeated
regression run rather than a new blind efficiency comparison.

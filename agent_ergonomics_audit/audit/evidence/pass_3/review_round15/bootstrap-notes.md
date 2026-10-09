# Review harness observations

The first independent probe had two unmatched parentheses in the owned probe
source. Both initial runtime invocations exited 255 before ERT started.
`probe30` and `probe29` preserve full argv, times, exit and stdout/stderr.
The initial source is preserved byte for byte as `probe-bootstrap.source.txt`;
its original `.el` copy is ignored to avoid build discovery. Only the owned
probe was corrected. Successful runs use separate `probe-fixed30` and
`probe-fixed29` records. These bootstrap failures are excluded from passing
test counts and are not production findings.

The first probe30 shell tool yielded before completion, and the reviewer
printed only its empty output rather than its session identifier. The recorder
continued and produced a complete exit-255 record; that record was read
explicitly afterward. No execution is inferred from the missing tool display.

Some combined skill, diff, ledger and runtime inspection outputs were
truncated by the tool display budget. Focused source reads and full on-disk
execution logs were used subsequently; truncated displays are not test
evidence. The recorder now prints only execution metadata and ERT summaries,
while retaining complete stdout/stderr files.

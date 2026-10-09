# Pass 3 final known-task regression replay

**9/9 tasks passed; 89 regression round trips.** Execution ran from 2026-10-08T23:42:58.506474+00:00 to 2026-10-08T23:43:02.963203+00:00, with SHA `5d07d807bc85a093725db24e33996b4af690ec0f` at both ends and both production worktree guards exiting 0.

| Task | Status | Fresh first-strategy result | Regression trips |
|---|---|---|---|
| 1. Discover named execution, search shape, and async support | PASS | Unassigned for known replay | 1 |
| 2. Page README seven lines at a time and preserve positions | PASS | Unassigned for known replay | 63 |
| 3. Discover all 105 .el files without duplicates | PASS | Unassigned for known replay | 4 |
| 4. Page 250 exact match locations with colon/newline filename | PASS | Unassigned for known replay | 4 |
| 5. Distinguish no matches from invalid regex, including empty directory | PASS | Unassigned for known replay | 4 |
| 6. Approval calls never prompt/mutate; unsafe batch preflight rejects | PASS | Unassigned for known replay | 3 |
| 7. Compose glob/search/read in one batch | PASS | Unassigned for known replay | 1 |
| 8. Async search finishes once and supports cancellation | PASS | Unassigned for known replay | 4 |
| 9. Discover makem JSON and run actual minimal compiler/ERT success and failure | PASS | Unassigned for known replay | 5 |

This reused the established public scripts and owned fixtures. It is not a fresh-agent or comparative-efficiency result. The original 9/9 tasks, seven first-strategy successes, and 94-trip exercise remain unchanged.

Approval checks produced zero prompts or mutations. Unsafe batch preflight read zero files. Normal async completion and cancellation each delivered one terminal callback. Actual production makem success exited 0; intentional compiler and ERT failure fixtures exited 1 with typed locations `audit-build.el:14:1` and `test/audit-build-tests.el:4` (null column).

All complete argv, stdout, stderr, exits, and timings are retained in [summary.json](summary.json) and its raw command records. [report.org](report.org) details the nine outcomes and limits. [preservation_manifest.json](preservation_manifest.json) verifies all 40 previous final-freeze files in `../replay_b7b966c/` and all 343 historical artifacts unchanged. No native-gate or remote-CI claim is made.

;;; focused.el --- Independent round 8 focused ERT gate -*- lexical-binding: t; -*-
(load "/work/test/ogent-agent-execution-tests.el" nil t)
(load "/work/test/ogent-tool-process-tests.el" nil t)
(load "/work/test/ui/ogent-ui-toolcalls-tests.el" nil t)
(ert-run-tests-batch-and-exit
 '(member
   ogent-agent-execution-async-ledger-write-failure-retains-terminal
   ogent-agent-execution-async-ledger-records-success
   ogent-agent-execution-legacy-async-ledger-failure-visible-once
   ogent-agent-execution-sync-ledger-failure-retains-completed-data
   ogent-agent-execution-async-malformed-result-delivers-once
   ogent-agent-execution-async-immediate-result-returns-nil
   ogent-agent-execution-async-ledger-failure-preserves-tool-error
   ogent-agent-execution-ledger-start-failure-prevents-effects
   ogent-agent-execution-async-custom-once-and-sync-rejection
   ogent-agent-execution-model-json-async-callback
   ogent-agent-execution-json-unsupported-extension-callback-once
   ogent-agent-execution-process-shell-failures-retain-data
   ogent-ui-toolcalls-streaming-ledger-failure-finalizes-drawer
   ogent-ui-toolcalls-streaming-duplicate-terminal-ignored
   ogent-ui-toolcalls-sync-text-ledger-failure-retains-output
   ogent-tool-process-bash-callback-error-cleans-up
   ogent-tool-process-bash-startup-error-is-terminal
   ogent-tool-process-bash-terminal-exit-bounds-descendant-drain
   ogent-tool-process-bash-cancel-keeps-partial-output
   ogent-tool-process-grep-async-once
   ogent-tool-process-ripgrep-real-json-protocol))

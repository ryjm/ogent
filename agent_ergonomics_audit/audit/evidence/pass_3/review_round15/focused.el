;;; focused.el --- Bounded independently selected contracts -*- lexical-binding: t; -*-
(load-file "/work/test/ogent-agent-execution-tests.el")
(load-file "/work/test/ogent-tool-process-tests.el")
(load-file "/work/test/ogent-debug-tests.el")
(load-file "/work/test/ui/ogent-ui-toolcalls-tests.el")
(ert-run-tests-batch-and-exit
 '(member
   ogent-agent-execution-process-raw-query-contract
   ogent-agent-execution-read-respects-configured-default
   ogent-agent-execution-next-retains-long-line-characters
   ogent-agent-execution-model-inplace-change-during-approval
   ogent-agent-execution-model-freezes-object-arguments
   ogent-agent-execution-model-detects-object-schema-mutation
   ogent-agent-execution-batch-freezes-nested-object-values
   ogent-agent-execution-batch-inplace-effects-change
   ogent-agent-execution-async-ledger-failure-preserves-tool-error
   ogent-agent-execution-legacy-async-ledger-failure-visible-once
   ogent-agent-execution-sync-ledger-failure-retains-completed-data
   ogent-agent-execution-json-unsupported-extension-callback-once
   ogent-tool-process-grep-gnu-component-filters
   ogent-tool-process-grep-ripgrep-component-filters
   ogent-tool-process-grep-gnu-binary-scope
   ogent-tool-process-grep-ripgrep-binary-scope
   ogent-tool-process-grep-gnu-symlink-scope
   ogent-tool-process-grep-ripgrep-symlink-scope
   ogent-tool-process-grep-ripgrep-selected-parent-order
   ogent-tool-process-bash-terminal-exit-bounds-descendant-drain
   ogent-tool-process-bash-callback-error-cleans-up
   ogent-debug-test-structured-read-replay-retains-column
   ogent-debug-test-structured-process-failures-in-history
   ogent-debug-test-history-json-preserves-execution-mode
   ogent-ui-toolcalls-streaming-ledger-failure-finalizes-drawer
   ogent-ui-toolcalls-streaming-duplicate-terminal-ignored))

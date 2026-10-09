;;; focused.el --- Bounded wider contract selector -*- lexical-binding: t; -*-
(load-file "/work/test/ogent-agent-execution-tests.el")
(load-file "/work/test/ogent-tool-process-tests.el")
(load-file "/work/test/ui/ogent-ui-toolcalls-tests.el")
(ert-run-tests-batch-and-exit
 '(member
   ogent-agent-execution-process-raw-query-contract
   ogent-agent-execution-glob-raw-root-contract
   ogent-agent-execution-process-raw-root-contract
   ogent-agent-execution-read-long-line-continuation
   ogent-agent-execution-next-refuses-changed-snapshot
   ogent-agent-execution-next-freezes-path-and-follows-json
   ogent-agent-execution-model-refreshes-object-schema-cache
   ogent-agent-execution-model-freezes-argument-strings
   ogent-agent-execution-batch-freezes-canonical-alias-target
   ogent-agent-execution-batch-preflight-prevents-unsafe-prefix
   ogent-agent-execution-validates-before-policy
   ogent-agent-execution-sync-ledger-context-survives-tool-context-change
   ogent-agent-execution-async-ledger-context-survives-project-switch
   ogent-agent-execution-ledger-start-failure-prevents-effects
   ogent-agent-execution-async-denial-and-cancel
   ogent-tool-process-grep-empty-gnu-candidates-validate-regex
   ogent-tool-process-grep-ripgrep-selected-groups-preserve-pages
   ogent-ui-toolcalls-streaming-ledger-context-survives-project-switch))

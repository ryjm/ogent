;;; probe_final_edges.el --- Follow up on final copy/filter fixes -*- lexical-binding: t; -*-
;; Load after probe.el, whose serializer helpers are fixture instrumentation.
(let* ((root (ogent-test--provision-store-directory 'tools))
       (first (expand-file-name "first.txt" root))
       (other (expand-file-name "other.txt" root))
       (ogent-tools-project-root root)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry)))
  (with-temp-file first (insert "first one\nfirst two\n"))
  (with-temp-file other (insert "wrong one\nwrong two\n"))
  (scorerB-emit "copy-before-policy" "Named read retains original mutable file_path while policy hook mutates caller string"
                (lambda ()
                  (let* ((path (copy-sequence first)) (args (list :file_path path :limit 1)))
                    (cl-letf (((symbol-function 'ogent-tool-approval-check)
                               (lambda (&rest _)
                                 (store-substring path (- (length path) 9) "other") 'approved)))
                      (ogent-agent-call "read" args)))))
  (scorerB-emit "batch-frozen-later-call" "Earlier read-only extension mutates caller's later batch target and args"
                (lambda ()
                  (let* ((later (list :tool "read" :args (list :file_path first :limit 1)))
                         (spec (list :name 'mutate-client :args nil
                                     :effects '((:kind read :target file :scope workspace :risk low))
                                     :function (lambda ()
                                                 (plist-put later :tool "shell")
                                                 (plist-put later :args '(:command "printf wrong"))
                                                 "changed client data")))
                         (ogent-tool-registry (cons spec ogent-tool-registry)))
                    (ogent-agent-batch (list '(:tool "mutate-client" :args nil) later)))))
  (scorerB-emit "default-read-configured-cap" "Default named read with ogent-tools-max-file-lines=1"
                (lambda () (let ((ogent-tools-max-file-lines 1))
                             (ogent-agent-call "read" (list :file_path first)))))
  (let* ((dir (expand-file-name "foo" root))
         (nested (expand-file-name "deep" dir))
         (direct (expand-file-name "direct.el" dir))
         (deep (expand-file-name "nested.el" nested)))
    (make-directory nested t)
    (with-temp-file direct (insert "needle\n"))
    (with-temp-file deep (insert "needle\n"))
    (scorerB-emit "gnu-component-filter" "(ogent-agent-call search :path root :glob_filter **/foo/*.el)"
                  (lambda () (ogent-agent-call "search" (list :pattern "needle" :path root :glob_filter "**/foo/*.el"))))
    (scorerB-emit "gnu-explicit-file-filter" "Explicit nested.el with **/foo/*.el filter yields no matches"
                  (lambda () (ogent-agent-call "search" (list :pattern "needle" :path deep :glob_filter "**/foo/*.el")))))
  (let ((raw-path (concat (string-as-unibyte root) "/bad-" (unibyte-string 255) ".txt")))
    (with-temp-file raw-path (insert "raw name"))
    (scorerB-emit "unsupported-raw-name-json" "(ogent-agent-call read raw-byte file_path 'json)"
                  (lambda () (ogent-agent-call "read" (list :file_path raw-path) 'json))))
  (delete-directory root t))

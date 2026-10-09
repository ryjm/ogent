;;; task7_after_freeze.el --- Common batch-envelope verification -*- lexical-binding: t; -*-
(require 'json)
(require 'cl-lib)
(require 'ogent)
(setq ogent-tools-project-root "/work/")
(let* ((form '(ogent-agent-batch
               '[(:tool "files" :args (:pattern "**/*.el" :path "/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures/glob" :limit 5))
                 (:tool "search" :args (:pattern "needle" :path "/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures/search" :limit 5))
                 (:tool "read" :args (:file_path "README.org" :limit 7))]))
       (result (progn (princ (format "FORM %S\n" form)) (eval form t)))
       (data (plist-get result :data))
       (ok (and (equal (plist-get result :status) "ok")
                (= (plist-get data :requested) 3)
                (= (plist-get data :completed) 3)
                (= (length (plist-get data :results)) 3)
                (cl-every (lambda (x) (equal (plist-get x :status) "ok")) (plist-get data :results)))))
  (princ (format "RESULT %S\n" result))
  (princ (concat "TASK_SUMMARY "
                 (json-serialize
                  (list :task 7 :name "Compose glob/search/read in one batch"
                        :attempts 3 :roundtrips 3 :first_strategy_success :json-false
                        :success (if ok t :json-false) :requested (plist-get data :requested)
                        :completed (plist-get data :completed)
                        :failure_diagnosis "Original verifier expected the common :data envelope, but batch fields were top-level. A top-level retry passed. Parent aligned the unpublished batch API with the common envelope; this rerun uses that envelope.")
                  :null-object :json-null :false-object :json-false) "\n")))

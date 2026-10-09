;;; task7_retry.el --- Correct top-level batch verifier -*- lexical-binding: t; -*-
(require 'json)
(require 'cl-lib)
(require 'ogent)
(setq ogent-tools-project-root "/work/")
(let* ((form '(ogent-agent-batch
               '[(:tool "files" :args (:pattern "**/*.el" :path "/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures/glob" :limit 5))
                 (:tool "search" :args (:pattern "needle" :path "/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures/search" :limit 5))
                 (:tool "read" :args (:file_path "README.org" :limit 7))]))
       (result (progn (princ (format "FORM %S\n" form)) (eval form t)))
       (ok (and (equal (plist-get result :status) "ok")
                (= (plist-get result :requested) 3)
                (= (plist-get result :completed) 3)
                (= (length (plist-get result :results)) 3)
                (cl-every (lambda (x) (equal (plist-get x :status) "ok")) (plist-get result :results)))))
  (princ (format "RESULT %S\n" result))
  (princ (concat "TASK_SUMMARY "
                 (json-serialize
                  (list :task 7 :name "Compose glob/search/read in one batch"
                        :attempts 2 :roundtrips 2 :first_strategy_success :json-false
                        :success (if ok t :json-false) :requested (plist-get result :requested)
                        :completed (plist-get result :completed)
                        :failure_diagnosis "First verifier assumed batch fields inside :data; returned batch fields were top-level as guide states. No product change or source inspection was needed.")
                  :null-object :json-null :false-object :json-false) "\n")))

;;; ogent-agent-execution-tests.el --- Fluent tool API tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise structured execution through the real registry and policy owners.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-agent nil t)
(require 'ogent-tools)
(require 'ogent-ui-toolcalls)

(ert-deftest ogent-agent-execution-named-call-and-json ()
  "Named calls preserve values and return independently parseable JSON."
  (let ((ogent-tool-registry
         (list (list :name 'echo :function #'identity
                     :args '((:name "value" :type "string")))))
        (ogent-tool-require-approval nil))
    (let ((result (json-parse-string
                   (ogent-agent-call "echo" '(:value "Tool error: literal") 'json)
                   :object-type 'plist)))
      (should (equal (plist-get result :status) "ok"))
      (should (equal (plist-get (plist-get result :data) :value) "Tool error: literal"))
      (should (equal (plist-get result :contract_version) "1")))))

(ert-deftest ogent-agent-execution-validates-before-policy ()
  "Invalid arguments and formats cannot reach approval or execution."
  (let ((ogent-tool-registry
         (list (list :name 'echo :function #'identity
                     :args '((:name "value" :type "string")))))
        (calls 0))
    (cl-letf (((symbol-function 'ogent-tool-approval-check)
               (lambda (&rest _) (cl-incf calls) 'approved)))
      (should (equal (plist-get (plist-get (ogent-agent-call "echo" '(:value 5)) :error) :code)
                     "invalid_arguments"))
      (should-error (ogent-agent-call "echo" '(:value "x") 'yaml) :type 'user-error)
      (should (= calls 0)))))

(ert-deftest ogent-agent-execution-denial-and-approval-required ()
  "Denied and approval-required calls cannot mutate files or prompt."
  (let ((ogent-tool-registry (copy-tree ogent-tools-default-registry))
        (ogent-tool-allow-list nil)
        (ogent-tool--denied-tools nil)
        (ogent-tool-require-approval t)
        (root (ogent-test--provision-store-directory 'tools)))
    (cl-letf (((symbol-function 'ogent-tool--prompt-approval)
               (lambda (&rest _) (ert-fail "Programmatic calls must not prompt"))))
      (let ((file (expand-file-name "new.txt" root)))
        (should (equal (plist-get (ogent-agent-call "write_file" (list :file_path file :content "new")) :status)
                       "approval_required"))
        (should-not (file-exists-p file))
        (let ((ogent-tool--denied-tools '("write-file")))
          (should (equal (plist-get (ogent-agent-call "write_file" (list :file_path file :content "new")) :status)
                         "denied")))
        (should-not (file-exists-p file))))))

(ert-deftest ogent-agent-execution-failures-recorded ()
  "An execution failure is typed and records a failed ledger terminal."
  (let ((ogent-tool-registry
         (list (list :name 'fail :function (lambda () (user-error "Choose an existing file"))
                     :args nil)))
        (ogent-tool-require-approval nil)
        recorded)
    (cl-letf (((symbol-function 'ogent-ledger-record-tool-finish)
               (lambda (_call _result failure &rest _) (setq recorded failure))))
      (let ((result (ogent-agent-call "fail" nil)))
        (should (equal (plist-get result :status) "error"))
        (should (equal (plist-get (plist-get result :error) :code) "execution_failed"))
        (should (equal recorded "Choose an existing file"))))))

(provide 'ogent-agent-execution-tests)
;;; ogent-agent-execution-tests.el ends here

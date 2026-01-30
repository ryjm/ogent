;;; ogent-prompts-tests.el --- Tests for ogent-prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Test coverage for prompt registry, composition, validation, and project customization.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-prompts)

;;; Core Registry Tests

(ert-deftest ogent-prompt-struct-creation ()
  "Prompt struct can be created with all slots."
  (let ((prompt (make-ogent-prompt
                 :id "test-prompt"
                 :title "Test Prompt"
                 :content "Do the thing."
                 :required-context '(code)
                 :compose-order 10)))
    (should (equal (ogent-prompt-id prompt) "test-prompt"))
    (should (equal (ogent-prompt-title prompt) "Test Prompt"))
    (should (equal (ogent-prompt-content prompt) "Do the thing."))
    (should (equal (ogent-prompt-required-context prompt) '(code)))
    (should (equal (ogent-prompt-compose-order prompt) 10))))

(ert-deftest ogent-prompt-register-and-get ()
  "Prompts can be registered and retrieved."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "my-prompt"
                           :title "My Prompt"
                           :content "Instructions here.")
    (let ((prompt (ogent-prompt-get "my-prompt")))
      (should prompt)
      (should (equal (ogent-prompt-id prompt) "my-prompt"))
      (should (equal (ogent-prompt-title prompt) "My Prompt"))
      (should (equal (ogent-prompt-content prompt) "Instructions here.")))))

(ert-deftest ogent-prompt-get-returns-nil-for-unknown ()
  "Getting an unknown prompt returns nil."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (should (null (ogent-prompt-get "nonexistent")))))

(ert-deftest ogent-prompt-list-returns-all ()
  "List returns all registered prompts."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "alpha" :title "Alpha" :content "A")
    (ogent-prompt-register "beta" :title "Beta" :content "B")
    (let ((prompts (ogent-prompt-list)))
      (should (= (length prompts) 2))
      (should (cl-find-if (lambda (p) (equal (ogent-prompt-id p) "alpha")) prompts))
      (should (cl-find-if (lambda (p) (equal (ogent-prompt-id p) "beta")) prompts)))))

(ert-deftest ogent-prompt-unregister ()
  "Prompts can be unregistered."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "temp" :title "Temp" :content "T")
    (should (ogent-prompt-get "temp"))
    (ogent-prompt-unregister "temp")
    (should (null (ogent-prompt-get "temp")))))

;;; Composition Tests

(ert-deftest ogent-prompt-compose-single ()
  "Composing a single prompt returns its content."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "solo" :title "Solo" :content "Just me.")
    (should (equal (ogent-prompt-compose '("solo")) "Just me."))))

(ert-deftest ogent-prompt-compose-multiple ()
  "Composing multiple prompts concatenates content."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "first" :title "First" :content "Part one.")
    (ogent-prompt-register "second" :title "Second" :content "Part two.")
    (let ((composed (ogent-prompt-compose '("first" "second"))))
      (should (string-match-p "Part one" composed))
      (should (string-match-p "Part two" composed)))))

(ert-deftest ogent-prompt-compose-respects-order ()
  "Composition respects compose-order when specified."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "low" :title "Low" :content "LOW" :compose-order 10)
    (ogent-prompt-register "high" :title "High" :content "HIGH" :compose-order 1)
    ;; Even if passed in wrong order, should sort by compose-order
    (let ((composed (ogent-prompt-compose '("low" "high"))))
      ;; HIGH (order 1) should come before LOW (order 10)
      (should (< (string-match "HIGH" composed)
                 (string-match "LOW" composed))))))

(ert-deftest ogent-prompt-compose-skips-unknown ()
  "Unknown prompts are skipped during composition."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "known" :title "Known" :content "I exist.")
    (let ((composed (ogent-prompt-compose '("known" "unknown"))))
      (should (string-match-p "I exist" composed))
      (should-not (string-match-p "unknown" composed)))))

(ert-deftest ogent-prompt-parse-composition-syntax ()
  "Parse @a+@b syntax into prompt list."
  (should (equal (ogent-prompt-parse-composition "@code-review+@testing")
                 '("code-review" "testing")))
  (should (equal (ogent-prompt-parse-composition "@single")
                 '("single")))
  (should (equal (ogent-prompt-parse-composition "code-review+testing")
                 '("code-review" "testing"))))

(ert-deftest ogent-prompt-template-params-detects-defaults ()
  "Template parameter extraction returns names and defaults."
  (let ((params (ogent-prompt-template-params
                 "Hello {{name}} from {{project:ogent}} and {{name}}.")))
    (should (equal params
                   '((:name "name" :default nil)
                     (:name "project" :default "ogent"))))))

(ert-deftest ogent-prompt-render-replaces-params ()
  "Render replaces template parameters with provided values."
  (should (equal (ogent-prompt-render
                  "Hi {{name}} {{project:ogent}}"
                  '(("name" . "Jake")))
                 "Hi Jake ogent")))

(ert-deftest ogent-prompt-compose-renders-templates ()
  "Compose renders parameters across multiple templates."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "one" :title "One" :content "One {{foo}}")
    (ogent-prompt-register "two" :title "Two" :content "Two {{bar:baz}}")
    (should (equal (ogent-prompt-compose-rendered
                    '("one" "two")
                    '(("foo" . "1") ("bar" . "2")))
                   "One 1\n\nTwo 2"))))

;;; Validation Tests

(ert-deftest ogent-prompt-validate-no-requirements ()
  "Prompts without required-context always validate."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "simple" :title "Simple" :content "No requirements.")
    (let ((result (ogent-prompt-validate "simple" nil)))
      (should (plist-get result :valid))
      (should (null (plist-get result :missing))))))

(ert-deftest ogent-prompt-validate-with-context ()
  "Prompts validate when required context is present."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "needs-code"
                           :title "Needs Code"
                           :content "Review this."
                           :required-context '(code))
    (let ((result (ogent-prompt-validate "needs-code" '(:code "some code"))))
      (should (plist-get result :valid))
      (should (null (plist-get result :missing))))))

(ert-deftest ogent-prompt-validate-missing-context ()
  "Prompts fail validation when required context is missing."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "needs-code"
                           :title "Needs Code"
                           :content "Review this."
                           :required-context '(code))
    (let ((result (ogent-prompt-validate "needs-code" nil)))
      (should-not (plist-get result :valid))
      (should (member 'code (plist-get result :missing))))))

(ert-deftest ogent-prompt-validate-partial-context ()
  "Validation reports all missing context items."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "needs-both"
                           :title "Needs Both"
                           :content "Need code and tests."
                           :required-context '(code tests))
    (let ((result (ogent-prompt-validate "needs-both" '(:code "some code"))))
      (should-not (plist-get result :valid))
      (should (member 'tests (plist-get result :missing)))
      (should-not (member 'code (plist-get result :missing))))))

;;; Project Customization Tests

(ert-deftest ogent-prompt-project-file-loading ()
  "Project prompts can be loaded from a file."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal))
        (temp-file (make-temp-file "ogent-prompts" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "* Project Prompts\n")
            (insert ":PROPERTIES:\n:OGENT_ID: project-prompts\n:END:\n\n")
            (insert "** Custom Review\n")
            (insert ":PROPERTIES:\n:OGENT_ID: custom-review\n:END:\n")
            (insert "Review with project-specific rules.\n"))
          ;; Load prompts from the file
          (ogent-prompt-load-from-file temp-file)
          ;; Should have loaded the prompt
          (let ((prompt (ogent-prompt-get "custom-review")))
            (should prompt)
            (should (string-match-p "project-specific" (ogent-prompt-content prompt)))))
      (delete-file temp-file))))

(ert-deftest ogent-prompt-overrides-apply ()
  "Project overrides modify existing prompts."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal))
        (ogent-prompt-overrides '(("code-review" . (:content "Custom review rules.")))))
    (ogent-prompt-register "code-review"
                           :title "Code Review"
                           :content "Default review.")
    (ogent-prompt-apply-overrides)
    (let ((prompt (ogent-prompt-get "code-review")))
      (should (string-match-p "Custom review" (ogent-prompt-content prompt))))))

;;; Default Prompts Tests

(ert-deftest ogent-default-prompts-registered ()
  "Default prompts are registered on load."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register-defaults)
    ;; Should have at least the core prompts
    (should (ogent-prompt-get "code-review"))
    (should (ogent-prompt-get "refactoring"))
    (should (ogent-prompt-get "documentation"))
    (should (ogent-prompt-get "testing"))))

(ert-deftest ogent-default-prompts-have-content ()
  "Each default prompt has non-empty content."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register-defaults)
    (dolist (prompt (ogent-prompt-list))
      (should (> (length (ogent-prompt-content prompt)) 0)))))

(provide 'ogent-prompts-tests)
;;; ogent-prompts-tests.el ends here

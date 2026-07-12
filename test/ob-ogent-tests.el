;;; ob-ogent-tests.el --- Tests for ob-ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the ogent Org Babel backend.  The synchronous gptel call is
;; stubbed so no network is involved: the stub invokes the request
;; callback immediately, exercising the full execute path.

;;; Code:

(require 'ogent-test-helper)
(require 'ob-ogent)
;; Load before any cl-letf stub so the in-function (require 'ogent-context)
;; is a no-op and does not overwrite the stubbed resolver.
(require 'ogent-context)
(require 'cl-lib)

(defvar gptel--system-message nil)
(defvar gptel-model)

(defmacro ob-ogent-tests--with-stub-request (capture &rest body)
  "Run BODY with `gptel-request' stubbed to echo a canned response.
CAPTURE is set to the prompt string the executor sent."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'gptel-request)
              (lambda (prompt &rest args)
                (setq ,capture prompt)
                (funcall (plist-get args :callback)
                         "MODEL REPLY" '(:status "done"))))
             ((symbol-function 'ogent-models-ensure)
              (lambda (id) (list :id id :backend 'stub-backend)))
             ((symbol-function 'ogent-gptel-resolve-backend)
              (lambda (_model) 'stub-backend)))
     ,@body))

;;; Variable expansion

(ert-deftest ob-ogent-expand-vars-substitutes-placeholders ()
  "`${name}' placeholders are replaced by their values."
  (should (equal (ob-ogent--expand-vars "hello ${who}, you are ${n}"
                                        '((who . "world") (n . 42)))
                 "hello world, you are 42")))

(ert-deftest ob-ogent-expand-vars-no-vars-is-identity ()
  "Body with no vars is returned unchanged."
  (should (equal (ob-ogent--expand-vars "plain prompt" nil) "plain prompt")))

;;; Handle parsing

(ert-deftest ob-ogent-handle-list-parses-separators ()
  "Handles split on spaces and commas and lose the leading @."
  (should (equal (ob-ogent--handle-list "@a, @b c") '("a" "b" "c")))
  (should (null (ob-ogent--handle-list nil)))
  (should (null (ob-ogent--handle-list ""))))

;;; Context resolution

(ert-deftest ob-ogent-resolve-context-includes-resolved-content ()
  "Resolved handles contribute their content; missing ones are flagged."
  ;; Return a real `ogent-context-node' struct: the content accessor is
  ;; a cl-defsubst that callers may inline at load time, so stubbing it
  ;; with cl-letf is load-order dependent and breaks in CI.
  (cl-letf (((symbol-function 'ogent-context--dependency)
             (lambda (handle)
               (if (equal handle "good")
                   (list :node (make-ogent-context-node
                                :content "GOOD CONTENT")
                         :missing-p nil)
                 (list :node nil :missing-p t)))))
    (let ((preamble (ob-ogent--resolve-context '("good" "bad"))))
      (should (string-match-p "## @good" preamble))
      (should (string-match-p "GOOD CONTENT" preamble))
      (should (string-match-p "## @bad" preamble))
      (should (string-match-p "(unresolved)" preamble))
      (should (string-match-p "# Prompt" preamble)))))

(ert-deftest ob-ogent-resolve-context-nil-for-no-handles ()
  "No handles yields no preamble."
  (should (null (ob-ogent--resolve-context nil))))

;;; Full execute path

(ert-deftest ob-ogent-execute-returns-model-reply ()
  "Executing a block returns the model's response text."
  (let (sent)
    (ob-ogent-tests--with-stub-request sent
      (should (equal (org-babel-execute:ogent "Say hi" '((:model . "gpt-5.5")))
                     "MODEL REPLY"))
      (should (equal sent "Say hi")))))

(ert-deftest ob-ogent-execute-expands-vars-in-prompt ()
  "The prompt sent to the model has its ${vars} expanded."
  (let (sent)
    (ob-ogent-tests--with-stub-request sent
      (org-babel-execute:ogent
       "Summarize ${topic}"
       '((:model . "gpt-5.5") (:var . (topic . "kittens"))))
      (should (equal sent "Summarize kittens")))))

(ert-deftest ob-ogent-execute-prepends-context ()
  "Resolved :context is prepended to the prompt sent to the model."
  (let (sent)
    (cl-letf (((symbol-function 'ogent-context--dependency)
               (lambda (_h) (list :node (make-ogent-context-node
                                         :content "PLAN BODY")
                                  :missing-p nil))))
      (ob-ogent-tests--with-stub-request sent
        (org-babel-execute:ogent
         "Use the plan"
         '((:model . "gpt-5.5") (:context . "@plan")))
        (should (string-match-p "PLAN BODY" sent))
        (should (string-match-p "Use the plan" sent))))))

(ert-deftest ob-ogent-execute-empty-prompt-errors ()
  "An empty prompt body signals a user error before any request."
  (let (unused)
    (ob-ogent-tests--with-stub-request unused
      (should-error (org-babel-execute:ogent "   " '((:model . "gpt-5.5")))
                    :type 'user-error)
      (ignore unused))))

(ert-deftest ob-ogent-execute-defaults-to-default-model ()
  "Without :model, execution uses `ogent-default-model'."
  (let (captured-model)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (funcall (plist-get args :callback) "ok" '(:status "done"))))
              ((symbol-function 'ogent-models-ensure)
               (lambda (id) (setq captured-model id) (list :id id :backend 'b)))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_m) 'b))
              (ogent-default-model "claude-fable-5"))
      (org-babel-execute:ogent "hi" nil)
      (should (equal captured-model "claude-fable-5")))))

(ert-deftest ob-ogent-execute-resolves-role-designator ()
  "A :model @role header resolves through `ogent-model-roles'."
  (let (captured-model)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (funcall (plist-get args :callback) "ok" '(:status "done"))))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_m) 'b)))
      (let ((ogent-default-model "alpha")
            (ogent-model-registry '((:id "alpha" :backend b)
                                    (:id "beta" :backend b)))
            (ogent-model-roles '((deep . "beta"))))
        (cl-letf (((symbol-function 'ogent-models-ensure)
                   (lambda (id)
                     (setq captured-model id)
                     (list :id id :backend 'b))))
          (org-babel-execute:ogent "hi" '((:model . "@deep")))
          (should (equal captured-model "beta")))))))

(ert-deftest ob-ogent-execute-unknown-role-errors ()
  "A :model @role typo signals a user error instead of a silent fallback."
  (let ((ogent-default-model "alpha")
        (ogent-model-registry '((:id "alpha" :backend b)))
        (ogent-model-roles nil))
    (should-error (org-babel-execute:ogent "hi" '((:model . "@no-such-role")))
                  :type 'user-error)))

(ert-deftest ob-ogent-execute-unknown-model-errors ()
  "An unknown :model designator signals a user error."
  (let ((ogent-model-registry '((:id "alpha" :backend b)))
        (ogent-model-roles nil))
    (should-error (org-babel-execute:ogent "hi" '((:model . "nope")))
                  :type 'user-error)))

(ert-deftest ob-ogent-execute-honors-org-model-property ()
  "Without :model, an inherited OGENT_MODEL property picks the model."
  (let (captured-model)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (funcall (plist-get args :callback) "ok" '(:status "done"))))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_m) 'b)))
      (let ((ogent-default-model "alpha")
            (ogent-model-registry '((:id "alpha" :backend b)
                                    (:id "beta" :backend b)))
            (ogent-model-roles nil))
        (cl-letf (((symbol-function 'ogent-models-ensure)
                   (lambda (id)
                     (setq captured-model id)
                     (list :id id :backend 'b))))
          (with-temp-buffer
            (org-mode)
            (insert "* Block heading\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n")
            (goto-char (point-max))
            (org-babel-execute:ogent "hi" nil))
          (should (equal captured-model "beta")))))))

(ert-deftest ob-ogent-execute-ignores-session-model ()
  "Without :model, the transient gptel session model is skipped."
  (let (captured-model)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (funcall (plist-get args :callback) "ok" '(:status "done"))))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_m) 'b)))
      (let ((ogent-default-model "alpha")
            (ogent-model-registry '((:id "alpha" :backend b)
                                    (:id "beta" :backend b)))
            (ogent-model-roles nil)
            (gptel-model "beta"))
        (cl-letf (((symbol-function 'ogent-models-ensure)
                   (lambda (id)
                     (setq captured-model id)
                     (list :id id :backend 'b))))
          (org-babel-execute:ogent "hi" nil)
          (should (equal captured-model "alpha")))))))

(provide 'ob-ogent-tests)
;;; ob-ogent-tests.el ends here

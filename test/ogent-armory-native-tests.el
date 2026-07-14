;;; ogent-armory-native-tests.el --- Tests for the native gptel Armory runner -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for running Armory agents in-process through a gptel tool-use
;; loop.  All gptel traffic is stubbed via `cl-letf'; the conversation
;; lifecycle helpers are stubbed so no files are created.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory-adapter)
(require 'ogent-armory-runner)
(require 'ogent-armory-native)

(defvar ogent-armory-native-test--requests nil
  "Captured gptel request plists, oldest first.")

(defvar ogent-armory-native-test--finalized nil
  "Plist captured from the stubbed finalize path.")

(defvar ogent-armory-native-test--created nil
  "Non-nil once the stubbed conversation creation ran.")

(defvar ogent-armory-native-test--tool-log nil
  "Arguments the stub echo tool was invoked with, newest first.")

(defun ogent-armory-native-test--echo-tool (text)
  "Echo TEXT back, recording the invocation."
  (push text ogent-armory-native-test--tool-log)
  (format "echo: %s" text))

(defun ogent-armory-native-test--plan (&rest overrides)
  "Return a synthetic gptel-native plan with OVERRIDES prepended."
  (append overrides
          (list :adapter (ogent-armory-adapter-get "gptel-native")
                :adapter-id "gptel-native"
                :provider 'gptel
                :program nil
                :args nil
                :prompt "Do the task."
                :root temporary-file-directory
                :workspace temporary-file-directory
                :agent '(:slug "native-agent" :name "Native Agent")
                :job nil
                :conversation-id "native-test-conv"
                :model nil
                :runtime-mode 'native)))

(defun ogent-armory-native-test--tool-call (name args)
  "Return a canned gptel tool-call response for NAME with ARGS."
  (cons 'tool-call (list (list :name name :args args))))

(defmacro ogent-armory-native-test--with-stubs (rounds &rest body)
  "Run BODY with gptel and the conversation lifecycle stubbed.
ROUNDS evaluates to the canned callback invocations per request: a
list whose Nth element is a list of (RESPONSE . INFO) conses replayed
into the Nth request's callback, or a function of the request index
returning such a list.  Captures land in
`ogent-armory-native-test--requests' and
`ogent-armory-native-test--finalized'."
  (declare (indent 1) (debug t))
  `(let ((ogent-armory-native-test--requests nil)
         (ogent-armory-native-test--finalized nil)
         (ogent-armory-native-test--created nil)
         (ogent-armory-native-test--tool-log nil)
         (ogent-armory-runner-ensure-beads-redirect nil)
         (rounds ,rounds)
         (index -1))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (setq index (1+ index))
                  (setq ogent-armory-native-test--requests
                        (append ogent-armory-native-test--requests
                                (list (list :prompt prompt
                                            :model (and (boundp 'gptel-model)
                                                        gptel-model)
                                            :args args))))
                  (let ((invocations (if (functionp rounds)
                                         (funcall rounds index)
                                       (nth index rounds)))
                        (callback (plist-get args :callback)))
                    (when callback
                      (dolist (invocation invocations)
                        (funcall callback (car invocation)
                                 (cdr invocation)))))
                  'stub-handle))
               ((symbol-function 'ogent-armory-runner--create-conversation)
                (lambda (_plan _started)
                  (setq ogent-armory-native-test--created t)
                  "stub-conversation.org"))
               ((symbol-function 'ogent-armory-runner--finalize-conversation)
                (lambda (_plan output error-output exit-status)
                  (setq ogent-armory-native-test--finalized
                        (list :output output
                              :error error-output
                              :exit exit-status))
                  "stub-conversation.org"))
               ((symbol-function 'ogent-armory-runner--capture-actions)
                (lambda (&rest _) nil))
               ((symbol-function 'ogent-tool--prompt-approval)
                (lambda (name _args)
                  (error "Unexpected approval prompt for %s" name))))
       ,@body)))

(defmacro ogent-armory-native-test--with-echo-registry (&rest body)
  "Run BODY with a stub echo tool registry and quiet approval policy."
  (declare (indent 0) (debug t))
  `(let ((ogent-tool-registry
          '((:name echo
                   :function ogent-armory-native-test--echo-tool
                   :description "Echo test tool."
                   :args ((:name "text" :type "string"
                                 :description "Text to echo"))
                   :category "test"
                   :effects ((:kind read :target file :scope workspace
                                    :risk low)))))
         (ogent-tool-allow-list nil)
         (ogent-tool-require-approval t)
         (ogent-tool--denied-tools nil))
     ,@body))

;;; Adapter registration

(ert-deftest ogent-armory-native-adapter-registered ()
  "The gptel-native adapter is registered with honest capabilities."
  (let ((adapter (ogent-armory-adapter-get "gptel-native")))
    (should adapter)
    (should (equal (plist-get adapter :adapter-type) "gptel_native"))
    (should (equal (plist-get adapter :runtime-modes) '(native)))
    (should-not (plist-get adapter :supports-session-resume))
    (should-not (plist-get adapter :unsupported-reason))
    (should-not (ogent-armory-adapter-executable adapter))
    (should (eq (ogent-armory-adapter-get "gptel") adapter))
    (should (eq (ogent-armory-adapter-get "gptel_native") adapter))))

(ert-deftest ogent-armory-native-adapter-invocation-has-no-program ()
  "The gptel-native invocation is an in-process stub without a program."
  (let* ((adapter (ogent-armory-adapter-get "gptel-native"))
         (invocation (ogent-armory-adapter-build-invocation
                      adapter '(:prompt "hi" :runtime-mode native))))
    (should-not (plist-get invocation :program))
    (should-not (plist-get invocation :args))
    (should-not (plist-get invocation :stdin))
    (should (eq (plist-get invocation :runtime-mode) 'native))))

(ert-deftest ogent-armory-native-adapter-environment-tolerates-no-program ()
  "Environment probing works for the executable-less native adapter."
  (let ((status (ogent-armory-adapter-test-environment
                 (ogent-armory-adapter-get "gptel-native"))))
    (should (equal (plist-get status :status) "missing"))
    (should-not (plist-get status :available))))

;;; Native loop

(ert-deftest ogent-armory-native-single-shot-finalizes-with-text ()
  "A response without tool calls finalizes the run with that text."
  (ogent-armory-native-test--with-stubs '((("Final answer." . nil)))
    (let ((state (ogent-armory-native-start
                  (ogent-armory-native-test--plan))))
      (should (plist-get state :finished))
      (should ogent-armory-native-test--created)
      (should (= 1 (length ogent-armory-native-test--requests)))
      ;; A single-turn conversation is sent as a bare prompt string.
      (should (equal (plist-get (car ogent-armory-native-test--requests)
                                :prompt)
                     "Do the task."))
      (should (equal (plist-get ogent-armory-native-test--finalized :exit) 0))
      (should (equal (plist-get ogent-armory-native-test--finalized :output)
                     "Final answer.")))))

(ert-deftest ogent-armory-native-tool-round-trip ()
  "A tool call executes through the registry and results feed back."
  (ogent-armory-native-test--with-echo-registry
    (ogent-armory-native-test--with-stubs
        (list (list (cons (ogent-armory-native-test--tool-call
                           "echo" '(:text "hi"))
                          nil))
              '(("All done." . nil)))
      (let ((state (ogent-armory-native-start
                    (ogent-armory-native-test--plan))))
        (should (plist-get state :finished))
        ;; The stub tool really ran, through the registry :function.
        (should (equal ogent-armory-native-test--tool-log '("hi")))
        (should (= 2 (length ogent-armory-native-test--requests)))
        ;; Round two replays the conversation with the tool results.
        (let ((prompt (plist-get (nth 1 ogent-armory-native-test--requests)
                                 :prompt)))
          (should (listp prompt))
          (should (= 3 (length prompt)))
          (should (equal (nth 0 prompt) "Do the task."))
          (should (string-match-p "\\[tool-call\\] echo" (nth 1 prompt)))
          (should (string-match-p "echo: hi" (nth 2 prompt))))
        ;; Fabricated output carries the tool transcript then final text.
        (let ((output (plist-get ogent-armory-native-test--finalized
                                 :output)))
          (should (equal (plist-get ogent-armory-native-test--finalized
                                    :exit)
                         0))
          (should (string-match-p "\\[tool 1\\] echo" output))
          (should (string-match-p "=> echo: hi" output))
          (should (string-suffix-p "All done." output)))))))

(ert-deftest ogent-armory-native-round-text-precedes-tool-calls ()
  "Model text accompanying a tool round lands in the fabricated turns."
  (ogent-armory-native-test--with-echo-registry
    (ogent-armory-native-test--with-stubs
        (list (list (cons "Let me check." '(:tool-use t))
                    (cons (ogent-armory-native-test--tool-call
                           "echo" '(:text "hi"))
                          nil))
              '(("Done." . nil)))
      (ogent-armory-native-start (ogent-armory-native-test--plan))
      (should (= 2 (length ogent-armory-native-test--requests)))
      (let ((assistant (nth 1 (plist-get
                               (nth 1 ogent-armory-native-test--requests)
                               :prompt))))
        (should (equal assistant "Let me check.\n[tool-call] echo")))
      (let ((output (plist-get ogent-armory-native-test--finalized :output)))
        (should (string-match-p "Let me check\\." output))
        (should (string-suffix-p "Done." output))))))

(ert-deftest ogent-armory-native-iteration-cap-stops-tool-loop ()
  "A model that always calls tools stops at the iteration cap."
  (ogent-armory-native-test--with-echo-registry
    (ogent-armory-native-test--with-stubs
        (lambda (_index)
          (list (cons (ogent-armory-native-test--tool-call
                       "echo" '(:text "again"))
                      nil)))
      (let ((ogent-armory-native-max-iterations 3))
        (let ((state (ogent-armory-native-start
                      (ogent-armory-native-test--plan))))
          (should (plist-get state :finished))
          (should (= 3 (length ogent-armory-native-test--requests)))
          (should (= 3 (length ogent-armory-native-test--tool-log)))
          (should (equal (plist-get ogent-armory-native-test--finalized
                                    :exit)
                         1))
          (should (string-match-p
                   "iterations"
                   (plist-get ogent-armory-native-test--finalized
                              :error))))))))

(ert-deftest ogent-armory-native-denied-tool-is-not-executed ()
  "A tool the approval flow denies never runs; the denial feeds back."
  (ogent-armory-native-test--with-stubs
      (list (list (cons (ogent-armory-native-test--tool-call
                         "echo" '(:text "hi"))
                        nil))
            '(("Understood." . nil)))
    (let ((ogent-tool-registry
           '((:name echo
                    :function ogent-armory-native-test--echo-tool
                    :description "Echo test tool."
                    :args ((:name "text" :type "string"
                                  :description "Text to echo"))
                    :confirm t)))
          (ogent-tool-allow-list nil)
          (ogent-tool-require-approval t)
          (ogent-tool--denied-tools nil))
      (cl-letf (((symbol-function 'ogent-tool--prompt-approval)
                 (lambda (&rest _) 'deny)))
        (ogent-armory-native-start (ogent-armory-native-test--plan))
        (should-not ogent-armory-native-test--tool-log)
        (should (= 2 (length ogent-armory-native-test--requests)))
        (should (string-match-p
                 "denied by approval policy"
                 (nth 2 (plist-get
                         (nth 1 ogent-armory-native-test--requests)
                         :prompt))))))))

(ert-deftest ogent-armory-native-unknown-tool-reports-back ()
  "An unregistered tool feeds an error string back instead of crashing."
  (ogent-armory-native-test--with-stubs
      (list (list (cons (ogent-armory-native-test--tool-call
                         "no-such-tool" nil)
                        nil))
            '(("OK." . nil)))
    (let ((ogent-tool-registry nil))
      (ogent-armory-native-start (ogent-armory-native-test--plan))
      (should (= 2 (length ogent-armory-native-test--requests)))
      (should (string-match-p
               "Unknown tool: no-such-tool"
               (nth 2 (plist-get (nth 1 ogent-armory-native-test--requests)
                                 :prompt)))))))

(ert-deftest ogent-armory-native-nil-response-finalizes-failed ()
  "A nil gptel response finalizes the run as failed with the status."
  (ogent-armory-native-test--with-stubs
      '(((nil . (:status "401 unauthorized"))))
    (ogent-armory-native-start (ogent-armory-native-test--plan))
    (should (equal (plist-get ogent-armory-native-test--finalized :exit) 1))
    (should (string-match-p
             "401 unauthorized"
             (plist-get ogent-armory-native-test--finalized :error)))))

(ert-deftest ogent-armory-native-request-error-finalizes-failed ()
  "An error signaled while sending finalizes the run as failed."
  (ogent-armory-native-test--with-stubs nil
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (&rest _) (error "backend exploded"))))
      (let ((state (ogent-armory-native-start
                    (ogent-armory-native-test--plan))))
        (should (plist-get state :finished))
        (should (equal (plist-get ogent-armory-native-test--finalized :exit)
                       1))
        (should (string-match-p
                 "backend exploded"
                 (plist-get ogent-armory-native-test--finalized :error)))))))

;;; Model selection

(ert-deftest ogent-armory-native-honors-plan-model ()
  "The plan's model designator resolves through the ogent registry."
  (let ((ogent-model-registry (cons '(:id "native-test-model" :backend nil)
                                    ogent-model-registry)))
    (ogent-armory-native-test--with-stubs '((("ok" . nil)))
      (ogent-armory-native-start
       (ogent-armory-native-test--plan :model "native-test-model"))
      (should (equal (plist-get (car ogent-armory-native-test--requests)
                                :model)
                     "native-test-model")))))

(ert-deftest ogent-armory-native-falls-back-to-default-model ()
  "Without a plan model the run uses the session default model."
  (let* ((ogent-model-registry (cons '(:id "native-default-model"
                                           :backend nil)
                                     ogent-model-registry))
         (ogent-default-model "native-default-model")
         (ogent-model-roles nil))
    (ogent-armory-native-test--with-stubs '((("ok" . nil)))
      (ogent-armory-native-start (ogent-armory-native-test--plan))
      (should (equal (plist-get (car ogent-armory-native-test--requests)
                                :model)
                     "native-default-model")))))

;;; Runner dispatch

(ert-deftest ogent-armory-native-runner-start-dispatches-without-process ()
  "gptel-native plans route to the native loop; make-process never runs."
  (ogent-armory-native-test--with-stubs '((("Dispatched." . nil)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _)
                 (error "make-process must not run for native plans")))
              ((symbol-function 'make-term)
               (lambda (&rest _)
                 (error "make-term must not run for native plans"))))
      (let ((state (ogent-armory-runner-start
                    (ogent-armory-native-test--plan))))
        (should (plist-get state :finished))
        (should ogent-armory-native-test--created)
        (should (= 1 (length ogent-armory-native-test--requests)))
        (should (equal (plist-get ogent-armory-native-test--finalized
                                  :output)
                       "Dispatched."))))))

(provide 'ogent-armory-native-tests)

;;; ogent-armory-native-tests.el ends here

;;; ogent-armory-native-tests.el --- Tests for the native gptel Armory runner -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for running Armory agents in-process through a gptel tool-use
;; loop.  All gptel traffic is stubbed via `cl-letf'; the conversation
;; lifecycle helpers are stubbed so no files are created.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory-adapter)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)
(require 'ogent-armory-native)
(require 'ogent-ledger)
;; Load analytics up front: the runner soft-requires it at record
;; time, and a require AFTER cl-letf installs a stub would clobber it.
(require 'ogent-analytics)

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
    ;; Resume is honestly supported: native resume reloads stored turns
    ;; (see ogent-armory-native-resume-capability-matches-behavior).
    (should (plist-get adapter :supports-session-resume))
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

;;; Ledger and analytics

(defun ogent-armory-native-test--failing-tool (_text)
  "Signal an error like a broken tool implementation."
  (error "tool blew up"))

(ert-deftest ogent-armory-native-ledger-records-tool-events ()
  "Executed tools record ledger start and finish events with effects."
  (ogent-armory-native-test--with-echo-registry
    (ogent-armory-native-test--with-stubs
        (list (list (cons (ogent-armory-native-test--tool-call
                           "echo" '(:text "hi"))
                          nil))
              '(("Done." . nil)))
      (let ((ogent-ledger-enabled t)
            (events nil))
        (cl-letf (((symbol-function 'ogent-ledger-record)
                   (lambda (type data)
                     (push (cons type data) events)
                     data)))
          (ogent-armory-native-start (ogent-armory-native-test--plan))
          (should (equal ogent-armory-native-test--tool-log '("hi")))
          (let ((start (assq 'tool-start events))
                (finish (assq 'tool-finish events)))
            (should start)
            (should (equal (plist-get (cdr start) :name) "echo"))
            (should (plist-get (cdr start) :effects))
            (should finish)
            (should (equal (plist-get (cdr finish) :name) "echo"))
            (should (plist-get (cdr finish) :result-hash))
            (should (numberp (plist-get (cdr finish) :duration)))
            (should-not (plist-get (cdr finish) :error))))))))

(ert-deftest ogent-armory-native-ledger-records-tool-error-finish ()
  "A failing tool records an error finish and feeds the error back."
  (ogent-armory-native-test--with-stubs
      (list (list (cons (ogent-armory-native-test--tool-call
                         "boom" '(:text "hi"))
                        nil))
            '(("Understood." . nil)))
    (let ((ogent-tool-registry
           '((:name boom
                    :function ogent-armory-native-test--failing-tool
                    :description "Failing test tool."
                    :args ((:name "text" :type "string"
                                  :description "Ignored")))))
          (ogent-tool-allow-list nil)
          (ogent-tool-require-approval t)
          (ogent-tool--denied-tools nil)
          (ogent-ledger-enabled t)
          (events nil))
      (cl-letf (((symbol-function 'ogent-ledger-record)
                 (lambda (type data)
                   (push (cons type data) events)
                   data)))
        (ogent-armory-native-start (ogent-armory-native-test--plan))
        (let ((finish (assq 'tool-finish events)))
          (should finish)
          (should (string-match-p "tool blew up"
                                  (plist-get (cdr finish) :error)))
          (should-not (plist-get (cdr finish) :result-hash))
          (should (numberp (plist-get (cdr finish) :duration))))
        (should (string-match-p
                 "Tool error: tool blew up"
                 (nth 2 (plist-get
                         (nth 1 ogent-armory-native-test--requests)
                         :prompt))))))))

(ert-deftest ogent-armory-native-analytics-records-final-completion ()
  "A successful run records the final round in the analytics eval loop."
  (let ((recorded nil))
    (cl-letf (((symbol-function 'ogent-analytics-record-completion)
               (lambda (model prompt response &optional template)
                 (push (list model prompt response template) recorded))))
      ;; Success: model, prompt, and response are recorded once.
      (let ((ogent-model-registry (cons '(:id "native-test-model"
                                              :backend nil)
                                        ogent-model-registry)))
        (ogent-armory-native-test--with-stubs '((("Final answer." . nil)))
          (ogent-armory-native-start
           (ogent-armory-native-test--plan :model "native-test-model"))
          (should (equal recorded
                         '(("native-test-model" "Do the task."
                            "Final answer." nil))))))
      ;; Failure: analytics never records, mirroring the engine's
      ;; success-only close path.
      (setq recorded nil)
      (ogent-armory-native-test--with-stubs
          '(((nil . (:status "boom"))))
        (ogent-armory-native-start (ogent-armory-native-test--plan))
        (should-not recorded)))))

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

;;; Live round streaming and native resume

(defmacro ogent-armory-native-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-native-" t)))
     ,@body))

(defun ogent-armory-native-test--file-bytes (file)
  "Return FILE's contents as raw bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun ogent-armory-native-test--conversation-tree (root conversation-id)
  "Return sorted (RELATIVE-NAME . BYTES) pairs for CONVERSATION-ID under ROOT."
  (let ((dir (ogent-armory-conversation-directory root conversation-id)))
    (mapcar (lambda (file)
              (cons (file-relative-name file dir)
                    (ogent-armory-native-test--file-bytes file)))
            (sort (directory-files-recursively dir "") #'string<))))

(ert-deftest ogent-armory-native-streams-rounds-into-visiting-buffer ()
  "Round text streams into a visiting buffer; the file waits for finalize."
  (ogent-armory-native-test-with-temp-dir dir
    (let ((ogent-armory-runner-ensure-beads-redirect nil)
          (ogent-analytics-enabled nil)
          (callback nil))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest args)
                   (setq callback (plist-get args :callback))
                   'stub-handle)))
        (let* ((plan (ogent-armory-native-test--plan
                      :root dir :conversation-id "stream-conv"))
               (state (ogent-armory-native-start plan))
               (file (plist-get plan :conversation-file))
               (buffer (find-file-noselect file)))
          (unwind-protect
              (let ((before (ogent-armory-native-test--file-bytes file)))
                ;; Streaming must survive a read-only conversation buffer.
                (with-current-buffer buffer (setq buffer-read-only t))
                (funcall callback "Hello " '(:tool-pending t))
                (should (string-suffix-p
                         "Hello "
                         (with-current-buffer buffer (buffer-string))))
                ;; No per-chunk file write: bytes unchanged mid-run.
                (should (equal (ogent-armory-native-test--file-bytes file)
                               before))
                (funcall callback "world" '(:tool-pending t))
                ;; Chunks accumulate incrementally at the marker.
                (should (string-suffix-p
                         "Hello world"
                         (with-current-buffer buffer (buffer-string))))
                (should (equal (ogent-armory-native-test--file-bytes file)
                               before))
                (funcall callback "." nil)
                (should (plist-get state :finished))
                ;; Finalize alone rewrote the file.
                (should-not (equal (ogent-armory-native-test--file-bytes file)
                                   before))
                ;; The visiting buffer reverts onto the canonical record.
                (should (equal (with-current-buffer buffer (buffer-string))
                               (decode-coding-string
                                (ogent-armory-native-test--file-bytes file)
                                'utf-8)))
                ;; Echoing never dirties the buffer.
                (should-not (buffer-modified-p buffer)))
            (kill-buffer buffer)))))))

(ert-deftest ogent-armory-native-no-visiting-buffer-file-byte-identical ()
  "Without a visiting buffer the store is byte-identical to finalize-only."
  (ogent-armory-native-test-with-temp-dir native-root
    (ogent-armory-native-test-with-temp-dir manual-root
      (let ((ogent-armory-runner-ensure-beads-redirect nil)
            (ogent-analytics-enabled nil))
        (cl-letf (((symbol-function 'ogent-armory-runner--iso-now)
                   (lambda () "2026-07-16T12:00:00+0000"))
                  ((symbol-function 'float-time)
                   (lambda (&optional _specified-time) 1000.0)))
          ;; Native run with nothing visiting the conversation file.
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (_prompt &rest args)
                       (funcall (plist-get args :callback)
                                "Final answer." nil)
                       'stub-handle)))
            (let ((plan (ogent-armory-native-test--plan
                         :root native-root :conversation-id "ident-conv")))
              (ogent-armory-native-start plan)
              (should-not (get-file-buffer
                           (plist-get plan :conversation-file)))))
          ;; Today's behavior: create + finalize, no streaming code at all.
          (let ((plan (ogent-armory-native-test--plan
                       :root manual-root :conversation-id "ident-conv")))
            (plist-put plan :conversation-file
                       (ogent-armory-runner--create-conversation
                        plan (ogent-armory-runner--iso-now)))
            (plist-put plan :duration "0.00s")
            (ogent-armory-runner--finalize-conversation
             plan "Final answer." nil 0)))
        (should (equal (ogent-armory-native-test--conversation-tree
                        native-root "ident-conv")
                       (ogent-armory-native-test--conversation-tree
                        manual-root "ident-conv")))))))

(ert-deftest ogent-armory-native-resume-rebuilds-message-list ()
  "Resume reloads stored turns into the gptel message list (golden)."
  (ogent-armory-native-test-with-temp-dir dir
    (let ((ogent-armory-runner-ensure-beads-redirect nil)
          (ogent-analytics-enabled nil)
          (conversation-id "resume-conv")
          (captured nil)
          (state nil))
      (ogent-armory-conversation-create
       dir (list :id conversation-id :agent "native-agent"
                 :title "Fixture" :status "done"))
      (ogent-armory-conversation-append-turn
       dir conversation-id "user" "First question."
       :ts "2026-07-15T09:00:00Z")
      (ogent-armory-conversation-append-turn
       dir conversation-id "agent" "First answer."
       :ts "2026-07-15T09:00:05Z")
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (prompt &rest args)
                   (setq captured prompt)
                   (funcall (plist-get args :callback) "Second answer." nil)
                   'stub-handle)))
        (setq state (ogent-armory-native-start
                     (ogent-armory-native-test--plan
                      :root dir :conversation-id conversation-id
                      :prompt "Continue the task."))))
      ;; Golden message list: stored turns oldest first, new prompt last.
      (should (equal captured
                     '("First question." "First answer."
                       "Continue the task.")))
      ;; Fresh iteration budget: a resumed conversation is a new run.
      (should (= (plist-get state :iteration) 1))
      (should (plist-get state :finished))
      ;; Turn numbering continues from the stored turns.
      (should (equal (mapcar (lambda (turn)
                               (list (plist-get turn :turn)
                                     (plist-get turn :role)))
                             (ogent-armory-conversation-read-turns
                              dir conversation-id))
                     '((1 "user") (1 "agent") (2 "user") (2 "agent")))))))

(ert-deftest ogent-armory-native-resume-capability-matches-behavior ()
  "The registry resume flag is true and backed by working turn reload."
  (ogent-armory-native-test-with-temp-dir dir
    (should (plist-get (ogent-armory-adapter-get "gptel-native")
                       :supports-session-resume))
    ;; Fresh conversation: nothing to reload.
    (should-not (ogent-armory-native--resume-messages
                 (ogent-armory-native-test--plan
                  :root dir :conversation-id "fresh-conv")))
    ;; Stored conversation: turns come back for the message list.
    (ogent-armory-conversation-create
     dir '(:id "cap-conv" :agent "native-agent" :title "Cap" :status "done"))
    (ogent-armory-conversation-append-turn
     dir "cap-conv" "user" "Hi." :ts "2026-07-15T09:00:00Z")
    (should (equal (ogent-armory-native--resume-messages
                    (ogent-armory-native-test--plan
                     :root dir :conversation-id "cap-conv"))
                   '("Hi.")))))

(provide 'ogent-armory-native-tests)

;;; ogent-armory-native-tests.el ends here

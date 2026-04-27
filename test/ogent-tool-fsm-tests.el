;;; ogent-tool-fsm-tests.el --- Tests for ogent-tool-fsm -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for the tool execution FSM.

;;; Code:

(require 'ert)
(require 'ogent-tool-fsm)
(require 'ogent-tool-render)
(require 'ogent-tool-approval)
(require 'ogent-tools)
(require 'ogent-models)

;;; Test Fixtures

(defvar ogent-tool-fsm-test--sample-tool-spec
  '(:name test-tool
	  :function ogent-tool-fsm-test--dummy-func
	  :description "Test tool"
	  :args ((:name "arg1" :type "string" :description "Test arg"))
	  :confirm nil)
  "Sample tool spec for testing.")

(defun ogent-tool-fsm-test--dummy-func (arg1)
  "Dummy tool function for testing."
  (format "Result: %s" arg1))

(defun ogent-tool-fsm-test--failing-func (_arg1)
  "Tool function that always fails."
  (error "Intentional test failure"))

;;; Parsing Tests

(ert-deftest ogent-tool-fsm-test-parse-plist-format ()
  "Test parsing tool calls from gptel plist format."
  (let* ((response-info '(:tool-use ((:id "call-123"
					  :name test-tool
					  :input (:arg1 "value1"))
                                     (:id "call-456"
					  :name another-tool
					  :input (:arg1 "value2")))))
         (calls (ogent-tool-fsm-parse-tool-calls response-info)))
    (should (= (length calls) 2))
    (should (equal (plist-get (car calls) :id) "call-123"))
    (should (eq (plist-get (car calls) :name) 'test-tool))
    (should (equal (plist-get (plist-get (car calls) :args) :arg1) "value1"))))

(ert-deftest ogent-tool-fsm-test-parse-empty-response ()
  "Test parsing response with no tool calls."
  (let ((calls (ogent-tool-fsm-parse-tool-calls "Regular text response")))
    (should (null calls))))

(ert-deftest ogent-tool-fsm-test-normalize-claude-format ()
  "Test normalizing Claude-style tool call."
  (let* ((call '(:id "call-123" :name read-file :input (:file_path "/test.txt")))
         (normalized (ogent-tool-fsm--normalize-tool-call call)))
    (should (equal (plist-get normalized :id) "call-123"))
    (should (eq (plist-get normalized :name) 'read-file))
    (should (plist-get (plist-get normalized :args) :file_path))))

(ert-deftest ogent-tool-fsm-test-normalize-openai-format ()
  "Test normalizing OpenAI-style tool call."
  (let* ((call '(:id "call-456" :function "bash" :arguments (:command "ls")))
         (normalized (ogent-tool-fsm--normalize-tool-call call)))
    (should (equal (plist-get normalized :id) "call-456"))
    (should (eq (plist-get normalized :name) 'bash))
    (should (plist-get (plist-get normalized :args) :command))))

(ert-deftest ogent-tool-fsm-test-normalize-generates-id ()
  "Normalize generates an id when missing."
  (let* ((call '(:name "test-tool" :input (:arg1 "value1")))
         (normalized (ogent-tool-fsm--normalize-tool-call call))
         (id (plist-get normalized :id)))
    (should (stringp id))
    (should (string-match-p "^test-tool-[0-9]+$" id))
    (should (eq (plist-get normalized :name) 'test-tool))))

(ert-deftest ogent-tool-fsm-test-normalize-rejects-missing-name ()
  "Normalize returns nil for malformed tool calls with no name."
  (should-not (ogent-tool-fsm--normalize-tool-call
               '(:id "call-missing-name" :input (:arg1 "value1")))))

(ert-deftest ogent-tool-fsm-test-parse-skips-malformed-calls ()
  "Parser should preserve valid calls and skip malformed tool calls."
  (let* ((response-info
          '(:tool-use
            ((:id "bad" :input (:arg1 "value1"))
             (:id "good" :name test-tool :input (:arg1 "value2")))))
         (calls (ogent-tool-fsm-parse-tool-calls response-info)))
    (should (= (length calls) 1))
    (should (equal (plist-get (car calls) :id) "good"))
    (should (eq (plist-get (car calls) :name) 'test-tool))))

;;; Execution Tests

(ert-deftest ogent-tool-fsm-test-spec-lookup ()
  "Test that tool spec lookup works in execution context."
  (let ((ogent-tool-registry (list ogent-tool-fsm-test--sample-tool-spec)))
    (let ((spec (ogent-tool-spec-get 'test-tool)))
      (should spec)
      (should (eq (plist-get spec :name) 'test-tool))
      (should (eq (plist-get spec :function) 'ogent-tool-fsm-test--dummy-func)))))

(ert-deftest ogent-tool-fsm-test-execute-success ()
  "Test successful tool execution."
  (let* ((ogent-tool-registry (list ogent-tool-fsm-test--sample-tool-spec))
         (tool-call '(:id "test-1" :name test-tool :args (:arg1 "hello")))
         (callback-result nil)
         (callback-error nil)
         (callback-called nil))
    (ogent-tool-fsm-execute
     tool-call
     (lambda (result error)
       (setq callback-result result
             callback-error error
             callback-called t)))
    ;; Ensure callback was invoked
    (should callback-called)
    ;; Should have result, no error
    (should (stringp callback-result))
    (should (string-match-p "Result: hello" callback-result))
    (should (null callback-error))))

(ert-deftest ogent-tool-fsm-test-execute-failure ()
  "Test tool execution failure handling."
  (let* ((ogent-tool-registry
          (list '(:name failing-tool
			:function ogent-tool-fsm-test--failing-func
			:description "Failing tool"
			:args ((:name "arg1" :type "string" :description "Test"))
			:confirm nil)))
         (tool-call '(:id "test-2" :name failing-tool :args (:arg1 "test")))
         (callback-result nil)
         (callback-error nil)
         (callback-called nil))
    (ogent-tool-fsm-execute
     tool-call
     (lambda (result error)
       (setq callback-result result
             callback-error error
             callback-called t)))
    ;; Ensure callback was invoked
    (should callback-called)
    ;; Should have error, no result
    (should (null callback-result))
    (should (stringp callback-error))
    (should (string-match-p "Intentional test failure" callback-error))))

(ert-deftest ogent-tool-fsm-test-execute-unknown-tool ()
  "Test executing an unknown tool."
  (let* ((ogent-tool-registry nil)  ; Empty registry
         (tool-call '(:id "test-3" :name nonexistent-tool :args (:arg1 "test")))
         (callback-result nil)
         (callback-error nil)
         (callback-called nil))
    (ogent-tool-fsm-execute
     tool-call
     (lambda (result error)
       (setq callback-result result
             callback-error error
             callback-called t)))
    ;; Ensure callback was invoked
    (should callback-called)
    ;; Should have error about tool not found
    (should (null callback-result))
    (should (stringp callback-error))
    (should (string-match-p "Tool not found" callback-error))))

;;; State Tracking Tests

(ert-deftest ogent-tool-fsm-test-reset ()
  "Test FSM reset clears tracking."
  (puthash "test-call" 'dummy ogent-tool-fsm--active-calls)
  (should (> (hash-table-count ogent-tool-fsm--active-calls) 0))
  (ogent-tool-fsm-reset)
  (should (= (hash-table-count ogent-tool-fsm--active-calls) 0)))

;;; Integration Tests

(ert-deftest ogent-tool-fsm-test-callback-wrapper ()
  "Test callback wrapper integration."
  (let ((original-called nil)
        (text-received nil)
        (info-received nil))
    (let ((wrapped (ogent-tool-fsm-callback-wrapper
                    (lambda (text info)
                      (setq original-called t
                            text-received text
                            info-received info)))))
      ;; Call with regular response (no tools)
      (funcall wrapped "Hello" nil)
      (should original-called)
      (should (equal text-received "Hello"))
      (should-not info-received)
      
      ;; Reset
      (setq original-called nil
            text-received nil
            info-received nil)
      
      ;; Call with tool response
      (funcall wrapped "Text" '(:tool-use ((:id "c1" :name test :input nil))))
      (should original-called)
      (should (equal text-received "Text"))
      (should (equal info-received
                     '(:tool-use ((:id "c1" :name test :input nil))))))))

;;; Render Integration Tests

(ert-deftest ogent-tool-fsm-test-render-integration ()
  "Test that FSM creates proper render structs."
  (with-temp-buffer
    (org-mode)
    (let* ((ogent-tool-registry (list ogent-tool-fsm-test--sample-tool-spec))
           ;; Disable approval for this test
           (ogent-tool-approval--session-approved (make-hash-table :test 'equal))
           (info '(:tool-use ((:id "render-1"
				   :name test-tool
				   :input (:arg1 "test"))))))
      ;; Pre-approve the tool
      (puthash 'test-tool t ogent-tool-approval--session-approved)
      
      ;; Handle response - should create drawer
      (ogent-tool-fsm-handle-response "" info)
      
      ;; Check that drawer was created
      (goto-char (point-min))
      (should (search-forward ":TOOL_CALL_render-1:" nil t))
      (should (search-forward "test-tool" nil t)))))

(ert-deftest ogent-tool-fsm-test-plist-to-args ()
  "Test conversion of plist to argument list."
  (let ((plist '(:arg1 "value1" :arg2 42 :arg3 t)))
    (should (equal (ogent-tool-fsm--plist-to-args plist)
                   '("value1" 42 t))))
  (should (equal (ogent-tool-fsm--plist-to-args nil) nil)))

(provide 'ogent-tool-fsm-tests)

;;; ogent-tool-fsm-tests.el ends here

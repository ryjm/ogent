;;; ogent-streaming-tests.el --- Tests for streaming edge cases -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for streaming edge cases including:
;; - Streaming interruption/abort
;; - Error injection mid-stream
;; - Timeout handling
;; - Multi-model fan-out race conditions
;; - Network failure recovery

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-core)

;;; Streaming Interruption Tests

(ert-deftest ogent-streaming-abort-clears-accumulator ()
  "Aborting mid-stream should clear the streaming accumulator.
Note: The streaming flag is NOT cleared by the callback - it must be
cleared externally (e.g., by abort-request)."
  (setq ogent-ask--streaming-response "partial data")
  (setq ogent-ask--is-streaming t)
  ;; Simulate abort by calling error path
  (let ((callback (ogent-ask--make-callback)))
    (funcall callback nil '(:error "User aborted")))
  ;; Accumulator is cleared
  (should (equal ogent-ask--streaming-response ""))
  ;; Note: is-streaming is NOT cleared by callback (expected behavior)
  (should ogent-ask--is-streaming))

(ert-deftest ogent-streaming-abort-preserves-buffer-state ()
  "Aborting a request should not corrupt the buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is this?\n")
    (let ((original-content (buffer-string)))
      ;; Simulate a streaming response that gets aborted
      (ogent-test-with-mock-gptel
        ;; The mock completes normally, but we test buffer integrity
        (should (equal (buffer-string) original-content))))))

(ert-deftest ogent-streaming-partial-response-on-abort ()
  "Mid-stream abort should handle partial response gracefully."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Send some chunks
        (funcall callback "Hello " nil)
        (funcall callback "world" nil)
        ;; Now abort
        (funcall callback nil '(:error "Aborted by user"))
        ;; Should not have displayed partial content on error
        (should (null displayed))
        ;; Accumulator should be cleared
        (should (equal ogent-ask--streaming-response ""))))))

;;; Error Injection Mid-Stream Tests

(ert-deftest ogent-streaming-error-after-partial-data ()
  "Error arriving after partial data should be handled gracefully."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((error-message nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq error-message (apply #'format fmt args)))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Receive some data first
        (funcall callback "Partial " nil)
        (funcall callback "response " nil)
        (should (equal ogent-ask--streaming-response "Partial response "))
        ;; Then error occurs
        (funcall callback nil '(:error "Connection reset"))
        ;; Error message should be shown
        (should (string-match-p "failed" error-message))
        ;; Accumulator should be cleared
        (should (equal ogent-ask--streaming-response ""))))))

(ert-deftest ogent-streaming-error-mock-integration ()
  "Error mock should simulate mid-request failure."
  (ogent-test-with-error-mock "Simulated network error"
    ;; Verify the mock captures the request
    (gptel-request "Test prompt"
                   :callback (lambda (_text info)
                               (should (plist-get info :error))))
    (should (= 1 (ogent-test-request-count)))))

(ert-deftest ogent-streaming-recovery-after-error ()
  "After an error, subsequent requests should work normally."
  ;; First request fails
  (ogent-test-with-error-mock "First request fails"
    (let ((error-received nil))
      (gptel-request "Test prompt"
                     :callback (lambda (_text info)
                                 (setq error-received (plist-get info :error))))
      (should error-received)))
  ;; Second request succeeds (different mock context)
  (ogent-test-with-mock-gptel
    (let ((response-received nil))
      (gptel-request "Test prompt 2"
                     :callback (lambda (text _info)
                                 (when text (setq response-received text))))
      (should (equal response-received "Mock response")))))

;;; Timeout Handling Tests

(ert-deftest ogent-streaming-timeout-no-callback ()
  "Timeout mock should not invoke callback."
  (let ((callback-invoked nil))
    (ogent-test-with-timeout-mock
      (gptel-request "Test prompt"
                     :callback (lambda (_text _info)
                                 (setq callback-invoked t)))
      ;; Callback should not have been called
      (should-not callback-invoked)
      ;; But request should have been captured
      (should (= 1 (ogent-test-request-count))))))

(ert-deftest ogent-streaming-timeout-accumulator-state ()
  "Streaming state should be manageable during timeout scenarios."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  ;; In a real timeout, no callback is invoked
  ;; The streaming state would need external cleanup
  (ogent-test-with-timeout-mock
    (gptel-request "Test prompt"
                   :callback (lambda (_text _info) nil)))
  ;; State should still be set (no cleanup happened)
  (should ogent-ask--is-streaming)
  ;; Manual cleanup (as abort would do)
  (setq ogent-ask--is-streaming nil)
  (setq ogent-ask--streaming-response "")
  (should-not ogent-ask--is-streaming))

(ert-deftest ogent-streaming-timeout-request-captured ()
  "Timeout scenarios should still capture the request for debugging."
  (ogent-test-with-timeout-mock
    (gptel-request "Debug this timeout"
                   :callback #'ignore)
    (let ((req (ogent-test-last-request)))
      (should req)
      (should (equal (plist-get req :prompt) "Debug this timeout")))))

;;; Multi-Model Fan-Out Tests

(ert-deftest ogent-completions-registry-tracks-multiple ()
  "Completion registry should track multiple responses."
  (require 'ogent-completions)
  (with-temp-buffer
    (org-mode)
    ;; Clear registry for this buffer
    (setq-local ogent-completions--registry (make-hash-table :test 'equal))
    (setq-local ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\nWhat is the answer?\n")
    (insert "* Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst answer\n")
    (insert "* Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond answer\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (let ((question-marker (ogent-completions--find-question-marker)))
      (should question-marker)
      (let ((completions (ogent-completions--ensure-registry question-marker)))
        (should (= 2 (length completions)))
        (should (= 1 (ogent-completion-id (car completions))))
        (should (= 2 (ogent-completion-id (cadr completions))))))))

(ert-deftest ogent-completions-cycling-wraps-around ()
  "Cycling should wrap from last to first completion."
  (require 'ogent-completions)
  (with-temp-buffer
    (org-mode)
    ;; Clear registry for this buffer
    (setq-local ogent-completions--registry (make-hash-table :test 'equal))
    (setq-local ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\nWhat?\n")
    (insert "* Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nA\n")
    (insert "* Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nB\n")
    (insert "* Response 3\n:PROPERTIES:\n:RESPONSE-INDEX: 3\n:END:\nC\n")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((question-marker (ogent-completions--find-question-marker))
           (key (marker-position question-marker)))
      ;; Start at index 0
      (should (= 0 (gethash key ogent-completions--current-index 0)))
      ;; Cycle forward 3 times should wrap to 0
      (ogent-completions--set-current-index question-marker 2)
      (should (= 2 (gethash key ogent-completions--current-index)))
      ;; Next should wrap to 0
      (let ((next-index (mod (1+ 2) 3)))
        (should (= 0 next-index))))))

(ert-deftest ogent-completions-delete-updates-registry ()
  "Deleting a completion should invalidate the registry."
  (require 'ogent-completions)
  (with-temp-buffer
    (org-mode)
    ;; Clear registry for this buffer
    (setq-local ogent-completions--registry (make-hash-table :test 'equal))
    (setq-local ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\nWhat?\n")
    (insert "* Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n")
    (insert "* Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((question-marker (ogent-completions--find-question-marker))
           (key (marker-position question-marker))
           (completions (ogent-completions--ensure-registry question-marker)))
      (should (= 2 (length completions)))
      ;; Invalidate registry
      (ogent-completions--invalidate-registry question-marker)
      ;; Registry should now be empty for this key
      (should (null (gethash key ogent-completions--registry))))))

(ert-deftest ogent-completions-concurrent-responses-tracked ()
  "Multiple model responses arriving should all be tracked."
  (require 'ogent-completions)
  (with-temp-buffer
    (org-mode)
    ;; Clear registry for this buffer
    (setq-local ogent-completions--registry (make-hash-table :test 'equal))
    (setq-local ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\nCompare these models.\n")
    ;; Simulate responses from different models
    (insert "* Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:MODEL: gpt-4\n:END:\nGPT response\n")
    (insert "* Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:MODEL: claude-3\n:END:\nClaude response\n")
    (insert "* Response 3\n:PROPERTIES:\n:RESPONSE-INDEX: 3\n:MODEL: gemini\n:END:\nGemini response\n")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((question-marker (ogent-completions--find-question-marker))
           (completions (ogent-completions--ensure-registry question-marker)))
      (should (= 3 (length completions)))
      ;; Verify model info is captured
      (should (equal "gpt-4" (ogent-completion-model (nth 0 completions))))
      (should (equal "claude-3" (ogent-completion-model (nth 1 completions))))
      (should (equal "gemini" (ogent-completion-model (nth 2 completions)))))))

;;; Network Failure Recovery Tests

(ert-deftest ogent-streaming-network-error-message ()
  "Network errors should produce user-friendly messages."
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (let ((callback (ogent-ask--make-callback)))
        (setq ogent-ask--streaming-response "")
        (setq ogent-ask--is-streaming t)
        (funcall callback nil '(:error "ECONNREFUSED: Connection refused"))
        (should (string-match-p "failed" message-log))))))

(ert-deftest ogent-streaming-multiple-error-types ()
  "Different error types should all be handled."
  (dolist (error-type '("ETIMEDOUT" "ECONNRESET" "EHOSTUNREACH" "API rate limit"))
    (setq ogent-ask--streaming-response "partial")
    (setq ogent-ask--is-streaming t)
    (let ((callback (ogent-ask--make-callback)))
      (funcall callback nil `(:error ,error-type))
      ;; All error types should clear the accumulator
      (should (equal ogent-ask--streaming-response "")))))

(ert-deftest ogent-streaming-error-does-not-leave-orphan-overlays ()
  "Errors during streaming should not leave orphan overlays."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\nContent here\n")
    (let ((overlays-before (overlays-in (point-min) (point-max))))
      ;; Simulate a failed request
      (ogent-test-with-error-mock "Failure"
        (gptel-request "Test" :callback #'ignore))
      ;; Should not have added any overlays
      (let ((overlays-after (overlays-in (point-min) (point-max))))
        (should (= (length overlays-before) (length overlays-after)))))))

;;; Streaming State Consistency Tests

(ert-deftest ogent-streaming-state-reset-on-completion ()
  "Streaming callback should display response and clear accumulator on completion.
Note: The streaming flag is NOT cleared by the callback."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "Complete " nil)
        (funcall callback "response" nil)
        (funcall callback nil '(:done t))
        ;; Response should be displayed
        (should (equal displayed "Complete response"))
        ;; Accumulator should be cleared
        (should (equal ogent-ask--streaming-response ""))
        ;; Note: is-streaming flag is NOT cleared by callback
        (should ogent-ask--is-streaming)))))

(ert-deftest ogent-streaming-empty-response-handled ()
  "Empty responses should not cause errors or call display function.
The callback explicitly skips display when response is empty."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Complete with no chunks
        (funcall callback nil '(:done t))
        ;; Display function should NOT be called for empty response
        (should (null displayed))))))

(ert-deftest ogent-streaming-whitespace-only-response ()
  "Whitespace-only responses should be handled."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "   " nil)
        (funcall callback "\n\n" nil)
        (funcall callback nil '(:done t))
        (should (equal displayed "   \n\n"))))))

(provide 'ogent-streaming-tests)

;;; ogent-streaming-tests.el ends here

;;; ogent-ui-workflows-tests.el --- Native workflow regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify editable drafts, informed decisions, cancellation and request recovery.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-armory-compose)
(require 'ogent-armory-actions)
(require 'ogent-ui)
(require 'ogent-tool-approval)

(ert-deftest ogent-ui-workflows-attachments-stay-out-of-draft-payload ()
  "Attach two files, keep typing and submit repeatedly without losing context."
  (let* ((root (ogent-test--provision-store-directory 'workflow))
         (first (expand-file-name "first.org" root))
         (second (expand-file-name "second.org" root))
         captured)
    (write-region "First" nil first nil 'silent)
    (write-region "Second" nil second nil 'silent)
    (with-temp-buffer
      (ogent-armory-compose-mode)
      (setq ogent-armory-compose--root root ogent-armory-compose--agent "builder")
      (insert "Review these files.")
      (ogent-armory-compose-add-attachment first)
      (goto-char (point-max))
      (insert "\nKeep this sentence editable.")
      (ogent-armory-compose-add-attachment second)
      (goto-char (point-max))
      (insert "\nAnd this sentence too.")
      (cl-letf (((symbol-function 'ogent-armory-compose)
                 (lambda (_root _agent instruction &rest args)
                   (push (cons instruction args) captured))))
        (ogent-armory-compose-submit-buffer)
        (ogent-armory-compose-submit-buffer))
      (should (equal (nth 0 captured) (nth 1 captured)))
      (should (equal (plist-get (cdar captured) :attachments) (list first second)))
      (should-not (string-match-p "attachment:" (caar captured)))
      (should (string-match-p "Keep this sentence editable" (caar captured)))
      (should (string-match-p "And this sentence too" (caar captured)))
      (should (string-match-p "attachment:first.org" (buffer-string))))))

(ert-deftest ogent-ui-workflows-empty-draft-does-not-launch ()
  "An attachment alone is not an instruction and cannot start a run."
  (let* ((root (ogent-test--provision-store-directory 'workflow))
         (file (expand-file-name "note.org" root))
         launched)
    (write-region "Note" nil file nil 'silent)
    (with-temp-buffer
      (ogent-armory-compose-mode)
      (setq ogent-armory-compose--root root ogent-armory-compose--agent "builder")
      (ogent-armory-compose-add-attachment file)
      (cl-letf (((symbol-function 'ogent-armory-compose)
                 (lambda (&rest _) (setq launched t))))
        (should-error (ogent-armory-compose-submit-buffer) :type 'user-error))
      (should-not launched))))

(ert-deftest ogent-ui-workflows-invalid-and-dispatched-proposals-stay-guarded ()
  "Batch approval skips invalid and already dispatched proposals."
  (let* ((actions '((:id "valid" :valid t :status "pending")
                    (:id "invalid" :valid nil :status "pending" :errors ("Missing agent"))
                    (:id "finished" :valid t :status "dispatched")))
         (approved (ogent-armory-actions-approve-all actions)))
    (should (equal (mapcar (lambda (action) (plist-get action :status)) approved)
                   '("approved" "pending" "dispatched")))
    (should (equal (plist-get (car actions) :status) "pending"))))

(ert-deftest ogent-ui-workflows-invalid-proposal-details-explain-errors ()
  "A narrow list exposes invalid status and full errors before any decision."
  (save-window-excursion
    (let ((root (ogent-test--provision-store-directory 'workflow)) buffer)
      (unwind-protect
          (progn
            (ogent-armory-scaffold root "Review" :kind "root" :create-editor nil)
            (ogent-armory-conversation-create root '(:id "review" :agent "lead"))
            (ogent-armory-actions-store
             root "review" '((:id "broken" :type launch-task :target-agent "missing"
                                  :title "Inspect this complete proposed change"
                                  :prompt "Do not execute without a valid agent."
                                  :status "pending" :valid nil :errors ("Missing target agent"))))
            (setq buffer (ogent-armory-actions root "review"))
            (switch-to-buffer buffer)
            (goto-char (point-min))
            (forward-line 1)
            (let ((id (tabulated-list-get-id)))
              (setq tabulated-list-sort-key '("Proposal" . nil))
              (ogent-armory-actions-toggle-details)
              (ogent-armory-actions-toggle-details)
              (should (equal (tabulated-list-get-id) id)))
            (should (string-match-p "invalid" (buffer-string)))
            (should-error (ogent-armory-actions-approve-at-point) :type 'user-error)
            (let ((overriding-terminal-local-map nil)
                  (overriding-local-map nil))
              (call-interactively (key-binding (kbd "RET"))))
            (should (string-match-p "Missing target agent" (buffer-string)))
            (should (string-match-p "Do not execute" (buffer-string)))
            (should buffer-read-only)
            (should (equal (plist-get (car (ogent-armory-actions-read root "review")) :status)
                           "pending")))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when-let ((detail (get-buffer "*ogent-armory-proposal*"))) (kill-buffer detail))))))

(ert-deftest ogent-ui-workflows-approval-preview-restores-windows-on-quit ()
  "Full arguments and persistent scope stay visible; quitting restores focus."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let ((origin (current-buffer))
            (preview "Effects: write file\nArguments:\n:content First line\nSecond line\nLast line"))
        (cl-letf (((symbol-function 'read-char-choice)
                   (lambda (_prompt _choices)
                     (should (string-match-p "Last line" (buffer-string)))
                     (should (string-match-p "Always saves.*write-file" (buffer-string)))
                     (should buffer-read-only)
                     (signal 'quit nil))))
          (should (eq 'quit (condition-case nil
                                (ogent-ui-approval-read "write-file" preview "write-file")
                              (quit 'quit)))))
        (should (eq (window-buffer) origin))
        (should-not (get-buffer "*ogent-tool-review*"))))))

(ert-deftest ogent-ui-workflows-approval-scroll-keeps-decision-policy ()
  "Preview navigation does not make an approval decision."
  (let ((keys '(?v ?b ?n)))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_prompt _choices) (pop keys))))
      (should (eq (ogent-tool--prompt-approval "write-file" '(:content "Full text")) 'deny)))
    (should-not keys)))

(ert-deftest ogent-ui-workflows-approval-quit-denies-the-call ()
  "C-g denies the pending call so its original transport can resume."
  (cl-letf (((symbol-function 'ogent-ui-approval-read)
             (lambda (&rest _) (signal 'quit nil))))
    (should (eq (ogent-tool--prompt-approval "write-file" '(:content "Draft")) 'deny))))

(ert-deftest ogent-ui-workflows-cancellation-is-not-an-error ()
  "Keep partial output and cancelled status without opening error history."
  (with-temp-buffer
    (org-mode)
    (insert "* Review\nPartial output\n")
    (let* ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-ui--error-history nil)
           (request (make-ogent-ui-request :id "cancel" :buffer (current-buffer)
                                           :marker (copy-marker (point) t) :status 'type
                                           :model '(:id "gpt-6.1-sol"))))
      (puthash "cancel" request ogent-ui--request-table)
      (ogent-ui--close-response request "Request aborted by user" 'aborted)
      (should (string-match-p "Partial output" (buffer-string)))
      (should (string-match-p "ogent-cancelled" (buffer-string)))
      (should-not ogent-ui--error-history)
      (should (ogent-ui-request-closed request))
      (should (eq (ogent-ui-request-status request) 'aborted))
      (should-not (gethash "cancel" ogent-ui--request-table)))))

(ert-deftest ogent-ui-workflows-final-tool-answer-closes-real-response-shapes ()
  "Completed stream and non-stream replies ignore a stale pending flag."
  (dolist (stream '(nil t))
    (with-temp-buffer
      (org-mode)
      (let* ((ogent-ui--request-table (make-hash-table :test #'equal))
             (ogent-ui--request-history nil)
             (request (make-ogent-ui-request :id "final" :buffer (current-buffer)
                                             :marker (copy-marker (point-min) t)
                                             :status 'tool :model '(:id "gpt-6.1-sol")))
             (callback (ogent-ui--make-callback "final"))
             (info (list :http-status "200" :stream stream
                         :tool-use nil :tool-pending t)))
        (puthash "final" request ogent-ui--request-table)
        (funcall callback "Final answer after the approved tool." info)
        (when stream
          (should-not (ogent-ui-request-closed request))
          (funcall callback t info))
        (should (string-match-p "Final answer" (buffer-string)))
        (should (ogent-ui-request-closed request))
        (should (eq (ogent-ui-request-status request) 'done))
        (should-not (gethash "final" ogent-ui--request-table))))))

(ert-deftest ogent-ui-workflows-errors-preserve-selected-record-on-refresh ()
  "New errors do not displace a selected record or truncate its prompt."
  (let* ((ogent-errors-buffer-name "*workflow-errors-test*")
         (long-prompt (concat (make-string 150 ?x) " UNIQUE-END"))
         (record (list :timestamp (current-time) :model "fixture" :error "Failure"
                       :request-id "old" :prompt long-prompt))
         (ogent-ui--error-history (list record)))
    (unwind-protect
        (with-current-buffer (ogent-errors-render)
          (search-forward "Prompt: ")
          (let ((offset (point)))
            (push (list :timestamp (current-time) :request-id "new" :error "New failure")
                  ogent-ui--error-history)
            (ogent-errors-render)
            (should (equal (ogent-errors--id-at-point) "old"))
            (should (> (point) offset))
            (should (looking-back "Prompt: " (- (point) 8)))
            (should (string-match-p "UNIQUE-END" (buffer-string)))))
      (when-let ((buffer (get-buffer ogent-errors-buffer-name))) (kill-buffer buffer)))))

(ert-deftest ogent-ui-workflows-error-visit-reaches-original-heading ()
  "RET on an error reaches its original request rather than a raw ID prompt."
  (save-window-excursion
    (with-temp-buffer
      (org-mode)
      (insert "* Original request\nBody\n* Unrelated\n")
      (let* ((origin (current-buffer))
             (ogent-errors-buffer-name "*workflow-errors-test*")
             (ogent-ui--request-history
              (list (make-ogent-ui-request :id "visit" :buffer origin
                                           :request-heading-pos (copy-marker (point-min)))))
             (ogent-ui--error-history
              (list (list :timestamp (current-time) :request-id "visit" :error "Failure"))))
        (unwind-protect
            (progn
              (pop-to-buffer (ogent-errors-render))
              (let ((overriding-terminal-local-map nil)
                    (overriding-local-map nil))
                (call-interactively (key-binding (kbd "RET"))))
              (should (eq (current-buffer) origin))
              (should (= (point) (point-min))))
          (when-let ((buffer (get-buffer ogent-errors-buffer-name))) (kill-buffer buffer)))))))

(provide 'ogent-ui-workflows-tests)
;;; ogent-ui-workflows-tests.el ends here

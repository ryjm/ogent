;;; ogent-ui-toolcalls-tests.el --- Tool completion ledger recovery tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise real storage failures after a streaming tool has already started.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-models)
(require 'ogent-ui-toolcalls)

(ert-deftest ogent-ui-toolcalls-streaming-ledger-failure-finalizes-drawer ()
  "Real finish write failure preserves streamed output and clears markers."
  (let* ((root (ogent-test--provision-store-directory 'ui-ledger))
         (file (expand-file-name "ledger.org" root))
         (effect (expand-file-name "effect.txt" root))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-tools--active-processes nil)
         (ogent-ledger-enabled t) (ogent-ledger-file file))
    (with-temp-buffer
      (org-mode)
      (let* ((drawer (ogent-ui--execute-tool-async
                      "bash" (list :command
                                   (format "sleep 0.05; printf effect >> %s; printf complete"
                                           (shell-quote-argument effect))
                                   :timeout 1)))
             (process (caar ogent-tools--active-processes))
             (deadline (+ (float-time) 3)))
        (should (processp process))
        (should (file-exists-p file))
        (setq ogent-ledger-file root)
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.01))
        (should-not (process-live-p process))
        (accept-process-output nil 0.05)
        (should (string-match-p "complete" (buffer-string)))
        (should (string-match-p "Ledger warning: Tool has already completed" (buffer-string)))
        (should (string-match-p "Do not rerun" (buffer-string)))
        (should (string-match-p "Exit code: 0" (buffer-string)))
        (should (eq (get-text-property (point-min) 'ogent-tool-status) 'success))
        (dolist (marker (list (ogent-streaming-drawer-drawer-start drawer)
                              (ogent-streaming-drawer-result-start drawer)
                              (ogent-streaming-drawer-result-end drawer)
                              (ogent-streaming-drawer-status-marker drawer)))
          (should-not (marker-buffer marker)))
        (should-not ogent-tools--active-processes)
        (should (equal (with-temp-buffer (insert-file-contents effect) (buffer-string)) "effect"))
        (should-not (string-match-p "tool-finish"
                                    (with-temp-buffer (insert-file-contents file) (buffer-string))))))))

(ert-deftest ogent-ui-toolcalls-streaming-duplicate-terminal-ignored ()
  "A repeated streaming terminal cannot write or clean up a drawer twice."
  (let* ((root (ogent-test--provision-store-directory 'ui-ledger))
         (file (expand-file-name "ledger.org" root))
         (ogent-ledger-enabled t) (ogent-ledger-file file)
         callback
         (spec (list :name 'stream-fixture :args nil
                     :async-function 'ogent-ui-toolcalls-tests--start))
         (ogent-tool-registry (list spec)))
    (cl-letf (((symbol-function 'ogent-ui-toolcalls-tests--start)
               (lambda (complete) (setq callback complete))))
      (with-temp-buffer
        (org-mode)
        (ogent-ui--execute-tool-async "stream-fixture" nil)
        (should (file-exists-p file))
        (setq ogent-ledger-file root)
        (funcall callback 'stdout "complete")
        (funcall callback 'done 0)
        (let ((terminal (buffer-string)))
          (funcall callback 'done 0)
          (funcall callback 'stdout "late output")
          (should (equal terminal (buffer-string))))))))

(ert-deftest ogent-ui-toolcalls-sync-text-ledger-failure-retains-output ()
  "A sync text result includes output and an actionable ledger warning."
  (let* ((root (ogent-test--provision-store-directory 'ui-ledger))
         (file (expand-file-name "ledger.org" root))
         (ogent-ledger-enabled t) (ogent-ledger-file file)
         (runs 0)
         (ogent-tool-registry
          (list (list :name 'text-complete :args nil
                      :function (lambda ()
                                  (cl-incf runs)
                                  (should (file-exists-p file))
                                  (setq ogent-ledger-file root)
                                  "completed output"))))
         (result (ogent-ui--execute-tool 'text-complete nil)))
    (should (= runs 1))
    (should (string-prefix-p "completed output\n[Ledger warning:" result))
    (should (string-match-p "already completed" result))
    (should (string-match-p "Do not rerun" result))))

(provide 'ogent-ui-toolcalls-tests)
;;; ogent-ui-toolcalls-tests.el ends here

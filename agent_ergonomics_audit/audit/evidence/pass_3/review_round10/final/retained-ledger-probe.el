;;; retained-ledger-probe.el --- Independent round 10 probe -*- lexical-binding: t; -*-

(require 'ogent-agent)
(require 'ogent-tool-process)
(require 'ogent-ui-toolcalls)

(defun round10-read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun round10-count (file type)
  (with-temp-buffer
    (insert-file-contents file)
    (how-many (concat ":OGENT_LEDGER_TYPE: " type "$"))))

(ert-deftest round10-real-failed-process-retains-captured-ledger-and-future-config ()
  "Retain real failed process output while old ledger fails and future settings work."
  (let* ((root (make-temp-file "ogent-round10-" t))
         (origin (file-name-as-directory (expand-file-name "origin" root)))
         (ambient (file-name-as-directory (expand-file-name "ambient" root)))
         (ledger (expand-file-name "origin-ledger.org" origin))
         (configured (copy-sequence ledger))
         (started (concat ledger ".started"))
         (future (expand-file-name "future.org" ambient))
         (effect (expand-file-name "effect.txt" origin))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-tool-allow-list '("bash"))
         (ogent-tool--denied-tools nil)
         (ogent-tools--active-processes nil)
         (ogent-tools-show-progress nil)
         (ogent-ledger-enabled t)
         (ogent-ledger-file configured)
         (callbacks 0) result seen process)
    (unwind-protect
        (progn
          (make-directory origin t)
          (make-directory ambient t)
          (let ((default-directory origin))
            (setq process
                  (ogent-agent-call-async
                   "shell"
                   (list :working_directory origin :timeout 2
                         :command (format "printf effect >> %s; printf retained; printf failed >&2; sleep 0.1; exit 9"
                                          (shell-quote-argument effect)))
                   (lambda (terminal)
                     (cl-incf callbacks)
                     (setq result terminal
                           seen (list default-directory ogent-ledger-enabled ogent-ledger-file))))))
          (should (processp process))
          (should (file-exists-p ledger))
          (rename-file ledger started)
          (make-directory ledger)
          ;; Absolute configuration strings are mutable; the captured
          ;; destination must preserve the original content independently.
          (aset configured 1 ?X)
          (setq ogent-ledger-enabled nil ogent-ledger-file "future.org")
          (let ((default-directory ambient)
                (ogent-tools-project-root ambient)
                (deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline) (= callbacks 0))
              (accept-process-output nil 0.02))
            (should (= callbacks 1))
            (should (equal seen (list ambient nil "future.org")))
            (should (equal (plist-get result :status) "error"))
            (let ((data (plist-get result :data))
                  (error-data (plist-get result :error)))
              (should (equal (plist-get data :stdout) "retained"))
              (should (equal (plist-get data :stderr) "failed"))
              (should (= (plist-get data :exit_code) 9))
              (should (equal (plist-get error-data :code) "ledger_write_failed"))
              (should (equal (plist-get (plist-get error-data :tool_error) :code)
                             "command_failed"))
              (should (string-match-p "Do not rerun" (plist-get error-data :recovery))))
            (should (equal (round10-read effect) "effect"))
            (should (= (round10-count started "tool-start") 1))
            (should (= (round10-count started "tool-finish") 0))
            (should-not (file-exists-p configured))
            (should-not (file-exists-p future))
            (should-not (process-live-p process))
            (should-not (ogent-tool-process-cancel process))
            (should-not ogent-tools--active-processes)
            (accept-process-output nil 0.05)
            (should (= callbacks 1))
            ;; A subsequent call uses current configuration, with real
            ;; ledger append IO and a real structured read result.
            (setq ogent-ledger-enabled t)
            (let ((next (ogent-agent-call "read" (list :file_path effect))))
              (should (equal (plist-get next :status) "ok"))
              (should (equal (plist-get (plist-get next :data) :content) "effect")))
            (should (= (round10-count future "tool-start") 1))
            (should (= (round10-count future "tool-finish") 1))
            (should (equal ogent-ledger-file "future.org"))
            (should ogent-ledger-enabled)))
      (when (and process (process-live-p process))
        (ogent-tool-process-cancel process))
      (delete-directory root t))))

(ert-run-tests-batch-and-exit "^round10-")

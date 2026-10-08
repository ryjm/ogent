;;; tiebreaker_probe.el --- Original-SHA probes -*- lexical-binding: t; -*-
(require 'package)
(setq package-user-dir "/tmp/ogent-fixdeps/30.2/elpa")
(package-initialize)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(setq load-prefer-newer t)
(let ((base "/work/agent_ergonomics_audit/audit/partial/tiebreaker-baseline/lisp"))
  (add-to-list 'load-path (concat base "/ui"))
  (add-to-list 'load-path base)
  (load (concat base "/ogent-tools.el") nil t)
  (load (concat base "/ogent-doctor.el") nil t))
(setq ogent-tools-show-progress nil)
(defun tiebreaker-probe (id fn)
  (princ (json-encode
          (condition-case err
              (list :probe id :result (prin1-to-string (funcall fn)))
            (error (list :probe id :error_type (symbol-name (car err))
                         :error (error-message-string err))))))
  (princ "\n"))
(defun tiebreaker-async (command timeout)
  (let (events terminal proc)
    (setq proc (ogent-tool--bash-async
                command nil timeout
                (lambda (type data)
                  (push (list type data) events)
                  (when (memq type '(done error)) (setq terminal t)))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (not terminal) (< (float-time) deadline))
        (accept-process-output nil 0.01)))
    (when (and (processp proc) (process-live-p proc)) (delete-process proc))
    (accept-process-output nil 0.03)
    (nreverse events)))
(let* ((fixture (make-temp-file "ogent-tiebreaker-" t))
       (default-directory (file-name-as-directory fixture))
       (ogent-tools-project-root default-directory))
  (unwind-protect
      (progn
        (tiebreaker-probe "bash-first" (lambda () (ogent-tool--bash "printf hello; printf diagnostic >&2; exit 7" nil 2)))
        (tiebreaker-probe "bash-repeat" (lambda () (ogent-tool--bash "printf hello; printf diagnostic >&2; exit 7" nil 2)))
        (tiebreaker-probe "bash-bad-timeout" (lambda () (ogent-tool--bash "true" nil "bad")))
        (tiebreaker-probe "bash-async-first" (lambda () (tiebreaker-async "printf hello; printf diagnostic >&2; exit 7" 2)))
        (tiebreaker-probe "bash-async-repeat" (lambda () (tiebreaker-async "printf hello; printf diagnostic >&2; exit 7" 2)))
        (tiebreaker-probe "bash-async-timeout" (lambda () (tiebreaker-async "sleep 0.2" 0.03)))
        (tiebreaker-probe "bash-async-bad-timeout" (lambda () (tiebreaker-async "true" "bad")))
        (let ((ogent-doctor-checks
               '((:id good :label "Good fixture" :category environment
                      :fn (lambda () '(ok . "healthy")) :remediation "No action")
                 (:id broken :label "Broken fixture" :category transport
                      :fn (lambda () (error "Fixture crash"))
                      :remediation "Set `fixture-enabled' to t")
                 (:id opt-in :label "Opt-in fixture" :category environment :opt-in t
                      :fn (lambda () (error "Opt-in must remain excluded"))))))
          (tiebreaker-probe "doctor-run-first" #'ogent-doctor-run)
          (tiebreaker-probe "doctor-run-repeat" #'ogent-doctor-run)
          (tiebreaker-probe "doctor-batch-first"
                            (lambda () (with-temp-buffer
                                         (let* ((standard-output (current-buffer))
                                                (code (ogent-doctor-batch)))
                                           (list :exit-code code :report (buffer-string))))))
          (tiebreaker-probe "doctor-batch-repeat"
                            (lambda () (with-temp-buffer
                                         (let* ((standard-output (current-buffer))
                                                (code (ogent-doctor-batch)))
                                           (list :exit-code code :report (buffer-string)))))))
        (dolist (fn '(ogent-doctor-run ogent-doctor-batch ogent-tool--bash ogent-tool--bash-async))
          (tiebreaker-probe (concat "doc-" (symbol-name fn))
                            (lambda () (documentation fn)))))
    (ogent-tools-cancel-all)
    (delete-directory fixture t)))

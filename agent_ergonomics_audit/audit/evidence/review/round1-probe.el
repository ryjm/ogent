;;; probe.el --- Fresh eyes evidence -*- lexical-binding: t; -*-

(require 'ogent-tools)
(require 'ogent-models)
(require 'ogent-ui-toolcalls)
(require 'ogent-agent)

(defconst ogent-review-root
  "/work/agent_ergonomics_audit/audit/partial/review_round1/")

(defun ogent-review-print (key value)
  (message "%s=%S" key value))

;; Default preview path and its accept command must enforce the new contract.
(let* ((file (expand-file-name "ambiguous.txt" ogent-review-root))
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-ui-edit-preview-style 'diff-block)
       (ogent-ui--pending-diffs (make-hash-table :test #'equal))
       (args (list :file_path file :old_string "same" :new_string "new"
                   :replace_all :json-false)))
  (with-temp-file file (insert "same\nsame\n"))
  (with-temp-buffer
    (org-mode)
    (let* ((id (ogent-ui--show-diff-for-tool "edit-file" args))
           (info (gethash id ogent-ui--pending-diffs)))
      (ogent-review-print "ambiguous-preview-created" id)
      (ogent-review-print "ambiguous-preview-text" (plist-get info :diff-text))
      (goto-char (point-min))
      (ogent-diff-accept)
      (ogent-review-print "accept-status" (plist-get info :status))
      (ogent-review-print "accept-result" (plist-get info :result))
      (ogent-review-print "file-after-accept"
                          (with-temp-buffer (insert-file-contents file) (buffer-string))))))

;; Ensure discovery does not claim an ambiguous registered wire alias.
(let ((ogent-tool-registry '((:name custom-name :args nil)
                             (:name custom_name :args nil))))
  (ogent-review-print "alias-collision-metadata" (ogent-agent-capabilities 'json)))

;; Repeated process completion probes: all output must precede one terminal.
(let ((ogent-tools-show-progress nil)
      (file (expand-file-name "grep-data.txt" ogent-review-root))
      grep-failures bash-failures)
  (with-temp-file file (dotimes (_ 400) (insert "needle\n")))
  (dotimes (iteration 20)
    (let (events proc)
      (setq proc (ogent-tool--grep-async
                  "needle" file nil nil
                  (lambda (type data) (push (list type data) events))))
      (let ((deadline (+ (float-time) 5)))
        (while (and (< (float-time) deadline)
                    (not (seq-find (lambda (event) (memq (car event) '(done error))) events)))
          (accept-process-output proc 0.01)))
      (dotimes (_ 3) (accept-process-output nil 0.01))
      (let ((ordered (reverse events)))
        (unless (and (= 400 (cl-count 'match ordered :key #'car))
                     (= 1 (cl-count 'done ordered :key #'car))
                     (eq 'done (caar (last ordered))))
          (push (list iteration (length ordered) (car (last ordered))) grep-failures)))))
  (dotimes (iteration 20)
    (let (events proc)
      (setq proc (ogent-tool--bash-async
                  "printf stdout-final; printf stderr-final >&2" nil 5
                  (lambda (type data) (push (list type data) events))))
      (let ((deadline (+ (float-time) 5)))
        (while (and (< (float-time) deadline)
                    (not (seq-find (lambda (event) (memq (car event) '(done error))) events)))
          (accept-process-output proc 0.01)))
      (dotimes (_ 3) (accept-process-output nil 0.01))
      (let ((ordered (reverse events)))
        (unless (and (equal "stdout-final" (mapconcat #'cadr (seq-filter (lambda (event) (eq (car event) 'stdout)) ordered) ""))
                     (equal "stderr-final" (mapconcat #'cadr (seq-filter (lambda (event) (eq (car event) 'stderr)) ordered) ""))
                     (= 1 (cl-count 'done ordered :key #'car))
                     (eq 'done (caar (last ordered))))
          (push (list iteration ordered) bash-failures)))))
  (ogent-review-print "grep-completion-failures" grep-failures)
  (ogent-review-print "bash-completion-failures" bash-failures))

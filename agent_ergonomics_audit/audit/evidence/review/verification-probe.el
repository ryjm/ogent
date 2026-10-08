;;; current-probe.el --- Fixed-source review probes -*- lexical-binding: t; -*-

(require 'ogent-tools)
(require 'ogent-models)
(require 'ogent-ui-toolcalls)
(require 'ogent-mcp)
(require 'ogent-agent)

(defconst ogent-review-current-root
  "/work/agent_ergonomics_audit/audit/partial/review_round1/")

(make-directory ogent-review-current-root t)

(defun ogent-review-current-print (key value)
  (princ (format "%s=%S\n" key value)))

(let* ((file (expand-file-name "current-edit.txt" ogent-review-current-root))
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-ui-edit-preview-style 'diff-block)
       (ogent-ui--pending-diffs (make-hash-table :test #'equal)))
  (with-temp-file file (insert "same\nsame\n"))
  (with-temp-buffer
    (org-mode)
    (dolist (old '("same" ""))
      (ogent-review-current-print
       (concat "preview-rejects-" old)
       (condition-case err
           (ogent-ui--show-diff-for-tool
            "edit-file" (list :file_path file :old_string old :new_string "new"
                              :replace_all :json-false))
         (error (error-message-string err)))))
    (unless (zerop (hash-table-count ogent-ui--pending-diffs))
      (error "Invalid preview was stored"))
    (let* ((id (ogent-ui--show-diff-for-tool
                "edit-file" (list :file_path file :old_string "same"
                                  :new_string "new" :replace_all t)))
           (info (gethash id ogent-ui--pending-diffs)))
      (with-temp-file file (insert "changed after preview\n"))
      (goto-char (point-min))
      (ogent-diff-accept)
      (ogent-review-current-print "changed-file-accept-status" (plist-get info :status))
      (unless (eq (plist-get info :status) 'error)
        (error "Failed execution was labeled applied"))
      (ogent-accept-all-diffs)
      (unless (eq (plist-get info :status) 'error)
        (error "Bulk failed execution was labeled applied")))))

;; Stub only the MCP request boundary, then inspect the actual serialized args.
(let* ((ogent-tool-registry nil)
       (ogent--tools-registered nil)
       (ogent--tool-specs-registered nil)
       (ogent-tool-require-approval nil)
       (conn (make-ogent-mcp-connection :name "fresh"))
       (properties '((flag . ((type . "boolean")))
                     (nullable . ((type . "null")))
                     (payload . ((type . "object")))))
       (optional `((name . "optional") (inputSchema . ((properties . ,properties)))))
       (required `((name . "required")
                   (inputSchema . ((properties . ,properties)
                                   (required . ["flag" "nullable" "payload"])))))
       captured)
  (unwind-protect
      (progn
        (ogent-mcp--register-tools conn (list optional required))
        (cl-letf (((symbol-function 'ogent-mcp--request-sync)
                   (lambda (_conn _method params &optional _timeout)
                     (setq captured (alist-get 'arguments params))
                     '(((content . [((type . "text") (text . "ok"))])) . nil))))
          (let ((wrapper (ogent-tool-execution-wrapper
                          (ogent-tool-spec-get 'mcp-fresh-optional))))
            (funcall wrapper :json-false :null '(:nested [:false :null (:label "ok")]))
            (ogent-review-current-print "mcp-optional-false-null-nested" (json-encode captured))
            (unless (eq (alist-get 'flag captured) :json-false)
              (error "Explicit optional false was lost"))
            (funcall wrapper nil nil nil)
            (ogent-review-current-print "mcp-optional-omission" (json-encode captured))
            (unless (and (hash-table-p captured) (zerop (hash-table-count captured)))
              (error "Omitted optional arguments were sent")))
          (let ((wrapper (ogent-tool-execution-wrapper
                          (ogent-tool-spec-get 'mcp-fresh-required))))
            (funcall wrapper nil :null '(:nested [:false :null (:label "ok")]))
            (ogent-review-current-print "mcp-required-false-null-nested" (json-encode captured))
            (unless (eq (alist-get 'flag captured) :json-false)
              (error "Required native nil failed to serialize false")))))
    (ogent-mcp--unregister-tools "fresh")))

(let ((ogent-tool-registry '((:name custom-name :args nil)
                             (:name custom_name :args nil))))
  (let ((metadata (plist-get (ogent-agent-capabilities) :tools)))
    (unless (seq-every-p (lambda (tool) (equal [] (plist-get tool :aliases))) metadata)
      (error "Discovery claimed a colliding alias"))
    (ogent-review-current-print "discovery-collision-aliases" "both empty")))

;; A bounded completion probe waits on nil after a process exits to service
;; all pending sentinels; never busy-poll an already exited process object.
(let ((ogent-tools-show-progress nil)
      (ogent-tools-grep-max-count 1000)
      (file (expand-file-name "current-grep.txt" ogent-review-current-root)))
  (with-temp-file file (dotimes (_ 400) (insert "needle\n")))
  (dolist (kind '(grep bash))
    (dotimes (iteration 3)
      (let (events proc)
        (setq proc
              (if (eq kind 'grep)
                  (ogent-tool--grep-async
                   "needle" file nil nil
                   (lambda (type data) (push (list type data) events)))
                (ogent-tool--bash-async
                 "printf stdout-final; printf stderr-final >&2" nil 5
                 (lambda (type data) (push (list type data) events)))))
        (let ((deadline (+ (float-time) 5)))
          (while (and (< (float-time) deadline)
                      (not (seq-find (lambda (event) (memq (car event) '(done error))) events)))
            (accept-process-output (and (process-live-p proc) proc) 0.01)))
        (dotimes (_ 3) (accept-process-output nil 0.01))
        (let ((ordered (reverse events)))
          (unless (and (= 1 (cl-count 'done ordered :key #'car))
                       (eq 'done (caar (last ordered))))
            (error "%s terminal count/order failure: %S" kind ordered))
          (if (eq kind 'grep)
              (unless (= 400 (cl-count 'match ordered :key #'car))
                (error "Grep lost matches: %d" (cl-count 'match ordered :key #'car)))
            (unless (and (equal "stdout-final" (mapconcat #'cadr (seq-filter (lambda (event) (eq (car event) 'stdout)) ordered) ""))
                         (equal "stderr-final" (mapconcat #'cadr (seq-filter (lambda (event) (eq (car event) 'stderr)) ordered) "")))
              (error "Shell lost final stdout/stderr"))))))
    (ogent-review-current-print (format "%s-completion" kind) "3/3 ordered and complete")))

(ogent-review-current-print "probe-verdict" "CLEAN for covered behavior")

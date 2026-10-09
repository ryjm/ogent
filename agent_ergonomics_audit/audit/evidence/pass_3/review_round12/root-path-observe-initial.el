;;; root-path-observe.el --- Record the raw target format mismatch -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tools)
(let* ((parent (make-temp-file "review12-observe-" t))
       (raw-root (concat parent "/" (decode-coding-string (unibyte-string 255) 'utf-8-unix)))
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-ledger-enabled nil) records)
  (unwind-protect
      (progn
        (make-directory raw-root)
        (dolist (tool '("files" "search"))
          (dolist (format '(plist json))
            (dolist (async '(nil t))
              (let* ((args (list :pattern (if (equal tool "files") "*.el" "needle") :path raw-root))
                     (calls 0) result)
                (if async
                    (progn
                      (ogent-agent-call-async tool args
                                              (lambda (r) (cl-incf calls) (setq result r)) format)
                      (let ((deadline (+ (float-time) 3)))
                        (while (and (= calls 0) (< (float-time) deadline))
                          (accept-process-output nil 0.01))))
                  (setq result (ogent-agent-call tool args format)))
                (when (eq format 'json) (setq result (json-parse-string result :object-type 'plist)))
                (let ((path (plist-get (plist-get result :data) :path)))
                  (push (list :tool tool :format (symbol-name format) :async (if async t :json-false)
                              :callbacks calls :status (plist-get result :status)
                              :error_code (or (plist-get (plist-get result :error) :code) :json-null)
                              :data_path_json_representable
                              (if (condition-case nil (progn (json-serialize path) t) (error nil))
                                  t :json-false)) records)))))
        (princ (json-serialize (list :emacs emacs-version :observations (vconcat (nreverse records)))
                               :false-object :json-false :null-object :json-null))
        (terpri))
    (delete-directory parent t)))

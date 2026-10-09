;;; filter-observe.el --- Observe retained raw filter arguments -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tool-process)
(let* ((root (make-temp-file "review13-filter-" t))
       (raw (decode-coding-string (unibyte-string 255) 'utf-8-unix))
       (filter (concat "[a" raw "]*.el"))
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-ledger-enabled nil))
  (unwind-protect
      (progn
        (with-temp-file (expand-file-name "a.el" root) (insert "needle\nneedle\n"))
        (dolist (format '(plist json))
          (dolist (async '(nil t))
            (let* ((value (review13--call "search" (list :pattern "needle" :path root :glob_filter filter :limit 1) format async))
                   (result (if (eq format 'json)
                               (json-parse-string value :object-type 'plist
                                                  :null-object :json-null :false-object :json-false)
                             value)))
              (princ (json-serialize
                      (list :format (symbol-name format) :async (if async t :json-false)
                            :status (plist-get result :status)
                            :error_code (if (listp (plist-get result :error))
                                            (plist-get (plist-get result :error) :code) :json-null)
                            :representable (if (review13--json-p result) t :json-false)
                            :next_count (length (plist-get result :next)))
                      :null-object :json-null :false-object :json-false))
              (princ "\n")))))
    (delete-directory root t)))

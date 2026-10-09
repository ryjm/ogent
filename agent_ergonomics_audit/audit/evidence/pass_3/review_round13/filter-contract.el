;;; filter-contract.el --- Pin reflected filter representability -*- lexical-binding: t; -*-
(defun review13--raw-filter-contract (async)
  "Require raw retained filters to fail consistently with ASYNC delivery."
  (let* ((root (make-temp-file "review13-raw-filter-" t))
         (filter (concat "[a" (decode-coding-string (unibyte-string 255) 'utf-8-unix) "]*.el"))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.el" root) (insert "needle\nneedle\n"))
          (let* ((args (list :pattern "needle" :path root :glob_filter filter :limit 1))
                 (native (review13--call "search" args 'plist async))
                 (json (json-parse-string (review13--call "search" args 'json async)
                                          :object-type 'plist :null-object :json-null
                                          :false-object :json-false)))
            (should (review13--json-p native))
            (should (equal (plist-get native :status) (plist-get json :status)))
            (should (equal (plist-get native :status) "error"))
            (should (equal (plist-get (plist-get native :error) :code) "unsupported_output"))))
      (delete-directory root t))))
(ert-deftest review13-retained-raw-filter-sync ()
  "Keep native synchronous structured search envelopes representable as JSON."
  (review13--raw-filter-contract nil))
(ert-deftest review13-retained-raw-filter-async ()
  "Keep native asynchronous structured search envelopes representable as JSON."
  (review13--raw-filter-contract t))

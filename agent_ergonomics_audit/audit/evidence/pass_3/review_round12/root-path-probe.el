;;; root-path-probe.el --- Empty raw search roots preserve contracts -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tools)

(ert-deftest review12-structured-glob-empty-raw-root ()
  "Reject a raw root path even when no file matches the query."
  (let* ((parent (make-temp-file "review12-root-" t))
         (raw-root (concat parent "/" (decode-coding-string (unibyte-string 255) 'utf-8-unix)))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil))
    (unwind-protect
        (progn
          (make-directory raw-root)
          (should (file-directory-p raw-root))
          (dolist (format '(plist json))
            (let ((result (ogent-agent-call "files" (list :pattern "*.el" :path raw-root) format)))
              (when (eq format 'json) (setq result (json-parse-string result :object-type 'plist)))
              (should (equal (plist-get (plist-get result :error) :code) "unsupported_output")))))
      (delete-directory parent t))))

(ert-deftest review12-structured-grep-empty-raw-root ()
  "Reject a raw search target even when candidate selection is empty."
  (let* ((parent (make-temp-file "review12-root-" t))
         (raw-root (concat parent "/" (decode-coding-string (unibyte-string 255) 'utf-8-unix)))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil))
    (unwind-protect
        (progn
          (make-directory raw-root)
          (should (file-directory-p raw-root))
          (dolist (format '(plist json))
            (let ((result (ogent-agent-call "search" (list :pattern "needle" :path raw-root) format)))
              (when (eq format 'json) (setq result (json-parse-string result :object-type 'plist)))
              (should (equal (plist-get (plist-get result :error) :code) "unsupported_output")))))
      (delete-directory parent t))))

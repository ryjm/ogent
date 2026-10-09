;;; probe_binary_selection.el --- Independent bounded GNU search checks -*- lexical-binding: t; -*-
(require 'ogent-tools)
(require 'ogent-agent)
(require 'json)
(setq coding-system-for-write 'utf-8-unix)
(defun scorerB-search-emit (name function)
  (let ((result (condition-case error
                    (list :status "returned" :value (funcall function))
                  (error (list :status "signalled" :condition (format "%s" (car error))
                               :message (error-message-string error))))))
    (princ (concat (json-serialize (list :probe name :result result)
                                   :null-object :json-null :false-object :json-false) "\n"))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (real (expand-file-name "real" root))
       (normal (expand-file-name "normal.el" real))
       (ogent-tools-project-root root)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry)))
  (make-directory real)
  (with-temp-file normal (insert "needle is valid text\n"))
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-file (expand-file-name "late-nul.el" root)
      (set-buffer-multibyte nil)
      (insert "needle before late NUL\n" (make-string 70000 ?x) (unibyte-string 0) "hidden\n"))
    (with-temp-file (expand-file-name "bom-binary.el" root)
      (set-buffer-multibyte nil)
      (insert (unibyte-string 255 254 110 0 101 0 101 0 100 0 108 0 101 0 10 0))))
  (scorerB-search-emit
   "late-nul-and-bom-skipped"
   (lambda () (ogent-agent-call "search" (list :pattern "needle" :path root :glob_filter "**/*.el"))))
  (make-symbolic-link normal (expand-file-name "link.el" root))
  (make-symbolic-link real (expand-file-name "linked-directory" root))
  (scorerB-search-emit
   "ordinary-symlink-file-selected"
   (lambda () (ogent-agent-call "search" (list :pattern "needle" :path root :glob_filter "link.el"))))
  (scorerB-search-emit
   "directory-symlink-not-traversed"
   (lambda () (ogent-agent-call "search" (list :pattern "needle" :path root))))
  (let ((raw-name (concat (string-as-unibyte root) "/excluded-" (unibyte-string 255) ".bin")))
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file raw-name (set-buffer-multibyte nil) (insert "needle\n")))
    (scorerB-search-emit
     "excluded-invalid-utf8-name-unread"
     (lambda () (ogent-agent-call "search" (list :pattern "needle" :path root :glob_filter "link.el"))))
    (scorerB-search-emit
     "selected-invalid-utf8-name-refused"
     (lambda () (ogent-agent-call "search" (list :pattern "needle" :path raw-name) 'json))))
  (delete-directory root t))

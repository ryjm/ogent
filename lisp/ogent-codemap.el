;;; ogent-codemap.el --- Repository map generation for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds an Org "Codemap" buffer summarizing ogent modules and symbols.

;;; Code:

(require 'cl-lib)
(require 'org)

;; Forward declarations for optional project.el integration
(declare-function project-root "project")
(declare-function project-current "project")

(defcustom ogent-codemap-source-directories '("lisp")
  "Relative directories scanned when building the codemap."
  :type '(repeat directory)
  :group 'ogent)

(defcustom ogent-codemap-buffer-name "*ogent-codemap*"
  "Name of the buffer that displays the codemap contents."
  :type 'string
  :group 'ogent)

(defun ogent-codemap--project-root ()
  "Return the project root, using project.el when available.
Falls back to locating README.md or the current directory."
  (or
   ;; Try project.el (built-in since Emacs 28)
   (when (fboundp 'project-current)
     (when-let ((proj (project-current)))
       (project-root proj)))
   ;; Fallback: locate README.md
   (locate-dominating-file default-directory "README.md")
   ;; Last resort: current directory
   default-directory))

(defun ogent-codemap--source-files ()
  "Return every Emacs Lisp file under the configured directories."
  (let ((root (ogent-codemap--project-root)))
    (cl-loop for dir in ogent-codemap-source-directories
             for abs = (expand-file-name dir root)
             when (file-directory-p abs)
             append (directory-files-recursively abs "\\.el\\'"))))

(defconst ogent-codemap--definition-rx
  (rx "(def" (or "un" "custom" "macro" "var")
      (+ space)
      (group "ogent-" (+ (not (any space "(" ")")))))
  "Regexp matching elisp definitions with ogent- prefix.
Captures the symbol name in group 1.")

(defun ogent-codemap--definitions (file)
  "Return a list of public ogent definitions discovered in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (defs)
      (goto-char (point-min))
      (while (re-search-forward ogent-codemap--definition-rx nil t)
        (push (match-string-no-properties 1) defs))
      (nreverse (cl-remove-duplicates defs :test #'string=)))))

(defun ogent-codemap--insert-file (buffer file)
  "Insert FILE entries into BUFFER."
  (with-current-buffer buffer
    (let* ((root (ogent-codemap--project-root))
           (relative (file-relative-name file root))
           (defs (ogent-codemap--definitions file)))
      ;; Use concat+insert pattern for 6x speedup (see elisp-handbook.org)
      (insert
       (apply #'concat
              (format "** [[file:%s][%s]]\n" relative relative)
              (mapcar (lambda (def)
                        (format "*** [[file:%s::%s][%s]]\n" relative def def))
                      defs))))))

(defun ogent-codemap--render ()
  "Assemble the codemap buffer and return it."
  (let ((buffer (get-buffer-create ogent-codemap-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "* Codemap\n")
        (dolist (file (ogent-codemap--source-files))
          (ogent-codemap--insert-file buffer file))
        (org-mode)
        (goto-char (point-min))))
    buffer))

;;;###autoload
(defun ogent-codemap-buffer ()
  "Display the latest codemap buffer."
  (interactive)
  (display-buffer (ogent-codemap--render)))

;;;###autoload
(defun ogent-codemap-refresh ()
  "Rebuild the codemap buffer and return it."
  (interactive)
  (ogent-codemap--render))

(provide 'ogent-codemap)

;;; ogent-codemap.el ends here

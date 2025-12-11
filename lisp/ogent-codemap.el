;;; ogent-codemap.el --- Repository map generation for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds an Org "Codemap" buffer summarizing ogent modules, tests, and documentation.

;;; Code:

(require 'cl-lib)
(require 'org)

;; Forward declarations for optional project.el integration
(declare-function project-root "project")
(declare-function project-current "project")

(defcustom ogent-codemap-source-directories '("lisp" "test" "specs" "docs")
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

(defconst ogent-codemap--definition-rx
  (rx "(def" (or "un" "custom" "macro" "var")
      (+ space)
      (group "ogent-" (+ (not (any space "(" ")")))))
  "Regexp matching elisp definitions with ogent- prefix.
Captures the symbol name in group 1.")

(defconst ogent-codemap--test-rx
  (rx "(ert-deftest"
      (+ space)
      (group (+ (not (any space "(" ")")))))
  "Regexp matching ert-deftest definitions.
Captures the test name in group 1.")

(defconst ogent-codemap--org-heading-rx
  (rx line-start
      (group (repeat 1 3 "*"))
      " "
      (group (+ nonl)))
  "Regexp matching Org headings (levels 1-3).
Group 1 is stars, group 2 is heading text.")

(defconst ogent-codemap--md-heading-rx
  (rx line-start
      (group (repeat 1 3 "#"))
      " "
      (group (+ nonl)))
  "Regexp matching Markdown headings (levels 1-3).
Group 1 is hashes, group 2 is heading text.")

(defun ogent-codemap--definitions (file)
  "Return a list of public ogent definitions discovered in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (defs)
      (goto-char (point-min))
      (while (re-search-forward ogent-codemap--definition-rx nil t)
        (push (match-string-no-properties 1) defs))
      (nreverse (cl-remove-duplicates defs :test #'string=)))))

(defun ogent-codemap--test-definitions (file)
  "Return a list of test definitions discovered in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (defs)
      (goto-char (point-min))
      (while (re-search-forward ogent-codemap--test-rx nil t)
        (push (match-string-no-properties 1) defs))
      (nreverse (cl-remove-duplicates defs :test #'string=)))))

(defun ogent-codemap--org-headings (file)
  "Return a list of (LEVEL . HEADING) for Org headings in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (headings)
      (goto-char (point-min))
      (while (re-search-forward ogent-codemap--org-heading-rx nil t)
        (push (cons (length (match-string-no-properties 1))
                    (match-string-no-properties 2))
              headings))
      (nreverse headings))))

(defun ogent-codemap--md-headings (file)
  "Return a list of (LEVEL . HEADING) for Markdown headings in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (headings)
      (goto-char (point-min))
      (while (re-search-forward ogent-codemap--md-heading-rx nil t)
        (push (cons (length (match-string-no-properties 1))
                    (match-string-no-properties 2))
              headings))
      (nreverse headings))))

(defun ogent-codemap--file-type (file)
  "Return the type of FILE: `elisp', `elisp-test', `org', `markdown', or nil."
  (let ((ext (file-name-extension file))
        (name (file-name-nondirectory file)))
    (cond
     ((and (string= ext "el") (string-match-p "-tests?\\.el$" name)) 'elisp-test)
     ((string= ext "el") 'elisp)
     ((string= ext "org") 'org)
     ((string= ext "md") 'markdown)
     (t nil))))

(defun ogent-codemap--source-files ()
  "Return every supported file under the configured directories."
  (let ((root (ogent-codemap--project-root)))
    (cl-loop for dir in ogent-codemap-source-directories
             for abs = (expand-file-name dir root)
             when (file-directory-p abs)
             append (cl-remove-if-not
                     #'ogent-codemap--file-type
                     (directory-files-recursively abs "\\(\\.el\\|\\.org\\|\\.md\\)\\'")))))

(defun ogent-codemap--insert-file (buffer file)
  "Insert FILE entries into BUFFER."
  (with-current-buffer buffer
    (let* ((root (ogent-codemap--project-root))
           (relative (file-relative-name file root))
           (file-type (ogent-codemap--file-type file)))
      (pcase file-type
        ('elisp
         (let ((defs (ogent-codemap--definitions file)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (def defs)
             (insert (format "*** [[file:%s::%s][%s]]\n" relative def def)))))
        ('elisp-test
         (let ((tests (ogent-codemap--test-definitions file)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (test tests)
             (insert (format "*** [[file:%s::%s][%s]]\n" relative test test)))))
        ('org
         (let ((headings (ogent-codemap--org-headings file)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (h headings)
             (let ((level (car h))
                   (text (cdr h)))
               ;; Map org levels 1-3 to codemap levels 3-5
               (insert (format "%s [[file:%s::*%s][%s]]\n"
                               (make-string (+ level 2) ?*)
                               relative text text))))))
        ('markdown
         (let ((headings (ogent-codemap--md-headings file)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (h headings)
             (let ((level (car h))
                   (text (cdr h)))
               ;; Map md levels 1-3 to codemap levels 3-5
               (insert (format "%s [[file:%s][%s]]\n"
                               (make-string (+ level 2) ?*)
                               relative text))))))))))

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

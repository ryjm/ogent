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

;;; File Cache
;;
;; Cache parsed file data with modification times to avoid rescanning unchanged files.

(defvar ogent-codemap--file-cache (make-hash-table :test 'equal)
  "Hash table mapping file paths to cached parse results.
Each entry is a plist with :mtime and :data keys.")

(defun ogent-codemap--cache-file (file data)
  "Cache DATA for FILE with current modification time."
  (let ((mtime (file-attribute-modification-time (file-attributes file))))
    (puthash file (list :mtime mtime :data data) ogent-codemap--file-cache)))

(defun ogent-codemap--cache-stale-p (file)
  "Return non-nil if cache for FILE is stale or missing."
  (let ((entry (gethash file ogent-codemap--file-cache)))
    (or (null entry)
        (let ((cached-mtime (plist-get entry :mtime))
              (current-mtime (file-attribute-modification-time (file-attributes file))))
          (not (equal cached-mtime current-mtime))))))

(defun ogent-codemap--get-cached (file)
  "Return cached data for FILE, or nil if stale/missing."
  (unless (ogent-codemap--cache-stale-p file)
    (plist-get (gethash file ogent-codemap--file-cache) :data)))

(defun ogent-codemap--get-cached-or-scan (file file-type)
  "Return cached data for FILE or scan and cache it.
FILE-TYPE is one of `elisp', `elisp-test', `org', `markdown'."
  (or (ogent-codemap--get-cached file)
      (let ((data (pcase file-type
                    ('elisp (ogent-codemap--definitions file))
                    ('elisp-test (ogent-codemap--test-definitions file))
                    ('org (ogent-codemap--org-headings file))
                    ('markdown (ogent-codemap--md-headings file)))))
        (ogent-codemap--cache-file file data)
        data)))

(defun ogent-codemap-clear-cache ()
  "Clear the file cache, forcing a full rescan on next refresh."
  (interactive)
  (clrhash ogent-codemap--file-cache))

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

;;; Cross-linking
;;
;; Link source files to their test files and vice versa.

(defun ogent-codemap--find-test-file (source-file)
  "Find the test file corresponding to SOURCE-FILE.
Returns the relative path to the test file, or nil if not found."
  (let* ((root (ogent-codemap--project-root))
         (name (file-name-sans-extension (file-name-nondirectory source-file)))
         ;; Try both test/name-tests.el and test/ui/name-tests.el patterns
         (candidates (list
                      (expand-file-name (format "test/%s-tests.el" name) root)
                      (expand-file-name (format "test/ui/%s-tests.el" name) root))))
    (cl-loop for candidate in candidates
             when (file-exists-p candidate)
             return (file-relative-name candidate root))))

(defun ogent-codemap--find-source-file (test-file)
  "Find the source file corresponding to TEST-FILE.
Returns the relative path to the source file, or nil if not found."
  (let* ((root (ogent-codemap--project-root))
         (name (file-name-nondirectory test-file))
         ;; Strip -tests.el or -test.el suffix
         (base-name (if (string-match "\\(.+\\)-tests?\\.el$" name)
                        (match-string 1 name)
                      nil)))
    (when base-name
      (let ((candidates (list
                         (expand-file-name (format "lisp/%s.el" base-name) root)
                         (expand-file-name (format "lisp/ui/%s.el" base-name) root))))
        (cl-loop for candidate in candidates
                 when (file-exists-p candidate)
                 return (file-relative-name candidate root))))))

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
         (let ((defs (ogent-codemap--get-cached-or-scan file 'elisp))
               (test-file (ogent-codemap--find-test-file relative)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (when test-file
             (insert (format "Tests: [[file:%s][%s]]\n" test-file test-file)))
           (dolist (def defs)
             (insert (format "*** [[file:%s::%s][%s]]\n" relative def def)))))
        ('elisp-test
         (let ((tests (ogent-codemap--get-cached-or-scan file 'elisp-test))
               (source-file (ogent-codemap--find-source-file relative)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (when source-file
             (insert (format "Tests for: [[file:%s][%s]]\n" source-file source-file)))
           (dolist (test tests)
             (insert (format "*** [[file:%s::%s][%s]]\n" relative test test)))))
        ('org
         (let ((headings (ogent-codemap--get-cached-or-scan file 'org)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (h headings)
             (let ((level (car h))
                   (text (cdr h)))
               ;; Map org levels 1-3 to codemap levels 3-5
               (insert (format "%s [[file:%s::*%s][%s]]\n"
                               (make-string (+ level 2) ?*)
                               relative text text))))))
        ('markdown
         (let ((headings (ogent-codemap--get-cached-or-scan file 'markdown)))
           (insert (format "** [[file:%s][%s]]\n" relative relative))
           (dolist (h headings)
             (let ((level (car h))
                   (text (cdr h)))
               ;; Map md levels 1-3 to codemap levels 3-5
               (insert (format "%s [[file:%s][%s]]\n"
                               (make-string (+ level 2) ?*)
                               relative text))))))))))

;;; Incremental Refresh
;;
;; Parse existing codemap sections and preserve manual annotations.

(defun ogent-codemap--parse-sections ()
  "Parse the current buffer into a hash table of file -> section content.
Returns a hash table mapping relative file paths to their section text,
including any manual annotations."
  (let ((sections (make-hash-table :test 'equal)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*\\* \\[\\[file:\\([^]]+\\)\\]" nil t)
        (let* ((file (match-string 1))
               (section-start (line-beginning-position))
               (section-end (save-excursion
                              (if (re-search-forward "^\\*\\* " nil t)
                                  (line-beginning-position)
                                (point-max)))))
          (puthash file (buffer-substring-no-properties section-start section-end)
                   sections))))
    sections))

(defun ogent-codemap--extract-annotations (section-text)
  "Extract manual annotations from SECTION-TEXT.
Returns a list of annotation lines (lines starting with # or not matching
standard codemap patterns)."
  (let ((lines (split-string section-text "\n" t))
        (annotations nil))
    (dolist (line lines)
      ;; Keep lines that are comments or don't match standard patterns
      (when (and (not (string-match-p "^\\*+ \\[\\[file:" line))
                 (not (string-match-p "^Tests\\( for\\)?: \\[\\[file:" line))
                 (not (string-empty-p (string-trim line))))
        (push line annotations)))
    (nreverse annotations)))

(defun ogent-codemap--render ()
  "Assemble the codemap buffer and return it.
Uses incremental refresh to preserve manual annotations."
  (let ((buffer (get-buffer-create ogent-codemap-buffer-name)))
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             ;; Parse existing sections before erasing
             (old-sections (when (> (buffer-size) 0)
                             (ogent-codemap--parse-sections)))
             (files (ogent-codemap--source-files)))
        (erase-buffer)
        (insert "* Codemap\n")
        (dolist (file files)
          (let* ((root (ogent-codemap--project-root))
                 (relative (file-relative-name file root))
                 (old-section (when old-sections
                                (gethash relative old-sections)))
                 (annotations (when old-section
                                (ogent-codemap--extract-annotations old-section))))
            ;; Insert the file section
            (ogent-codemap--insert-file buffer file)
            ;; Re-insert any annotations after the file heading
            (when annotations
              (save-excursion
                ;; Go back to find the file heading we just inserted
                (re-search-backward (format "^\\*\\* \\[\\[file:%s\\]"
                                            (regexp-quote relative))
                                    nil t)
                (forward-line 1)
                ;; Skip the Tests: line if present
                (when (looking-at "^Tests\\( for\\)?: ")
                  (forward-line 1))
                ;; Insert annotations
                (dolist (ann annotations)
                  (insert ann "\n"))))))
        (org-mode)
        (goto-char (point-min))))
    buffer))

;;;###autoload
(defun ogent-codemap-buffer ()
  "Display the latest codemap buffer in a side window."
  (interactive)
  (display-buffer (ogent-codemap--render)
                  '((display-buffer-in-side-window)
                    (side . right)
                    (window-width . 0.4))))

;;;###autoload
(defun ogent-codemap-refresh ()
  "Rebuild the codemap buffer and return it."
  (interactive)
  (ogent-codemap--render))

;;; Handle Integration
;;
;; Support @codemap handle in prompts to include the codemap content.

(defun ogent-codemap--as-content ()
  "Return the codemap content as a string.
Generates the codemap if needed."
  (with-current-buffer (ogent-codemap--render)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ogent-codemap-handle-p (handle)
  "Return non-nil if HANDLE is a codemap handle."
  (string-match-p "^codemap\\(-.*\\)?$" handle))

(defun ogent-codemap-resolve-handle (handle)
  "Resolve a codemap HANDLE, returning content for the prompt.
Supports:
  @codemap - full codemap
  @codemap-lisp - only lisp/ section
  @codemap-test - only test/ section
  @codemap-specs - only specs/ section
  @codemap-docs - only docs/ section"
  (when (ogent-codemap-handle-p handle)
    (let ((content (ogent-codemap--as-content))
          (section (when (string-match "^codemap-\\(.+\\)$" handle)
                     (match-string 1 handle))))
      (if section
          ;; Extract specific section
          (ogent-codemap--extract-section content section)
        ;; Full codemap
        content))))

(defun ogent-codemap--extract-section (content section)
  "Extract SECTION from codemap CONTENT.
SECTION should match a directory name (lisp, test, specs, docs)."
  (let ((section-rx (format "^\\*\\* \\[\\[file:%s/.*" (regexp-quote section))))
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (let ((start nil)
            (end nil))
        ;; Find first file in section
        (when (re-search-forward section-rx nil t)
          (beginning-of-line)
          (setq start (point))
          ;; Find next top-level file heading from different section or end
          (forward-line 1)
          (if (re-search-forward "^\\*\\* \\[\\[file:\\([^/]+\\)/" nil t)
              (let ((next-dir (match-string 1)))
                (unless (string= next-dir section)
                  (beginning-of-line)
                  (setq end (point))))
            (setq end (point-max))))
        (if (and start end)
            (buffer-substring-no-properties start end)
          (format "No %s/ section found in codemap" section))))))

(provide 'ogent-codemap)

;;; ogent-codemap.el ends here

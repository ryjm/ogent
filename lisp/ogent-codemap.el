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

(defvar ogent-codemap--last-file-snapshot nil
  "Snapshot of files and mtimes from last refresh.
Alist of (FILE . MTIME) used to detect changes.")

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
  (clrhash ogent-codemap--file-cache)
  (setq ogent-codemap--last-file-snapshot nil))

;;; Change Detection
;;
;; Detect added, modified, and removed files since last refresh.

(defun ogent-codemap--get-file-mtime (file)
  "Return modification time of FILE, or nil if it doesn't exist."
  (when (file-exists-p file)
    (file-attribute-modification-time (file-attributes file))))

(defun ogent-codemap--snapshot-files ()
  "Create a snapshot of current files and their mtimes.
Returns an alist of (FILE . MTIME)."
  (let ((files (ogent-codemap--source-files)))
    (mapcar (lambda (f)
              (cons f (ogent-codemap--get-file-mtime f)))
            files)))

(defun ogent-codemap--detect-changes ()
  "Detect changes since last refresh.
Returns a plist with :added :modified :removed :unchanged file lists.
Each list contains absolute file paths."
  (let* ((current-files (ogent-codemap--source-files))
         (old-snapshot (or ogent-codemap--last-file-snapshot '()))
         (old-files (mapcar #'car old-snapshot))
         (added nil)
         (modified nil)
         (removed nil)
         (unchanged nil))
    ;; Find added and modified
    (dolist (file current-files)
      (let* ((old-entry (assoc file old-snapshot))
             (old-mtime (cdr old-entry))
             (new-mtime (ogent-codemap--get-file-mtime file)))
        (cond
         ((null old-entry)
          (push file added))
         ((not (equal old-mtime new-mtime))
          (push file modified))
         (t
          (push file unchanged)))))
    ;; Find removed
    (dolist (file old-files)
      (unless (member file current-files)
        (push file removed)))
    (list :added (nreverse added)
          :modified (nreverse modified)
          :removed (nreverse removed)
          :unchanged (nreverse unchanged))))

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
;; Parse existing codemap sections, preserve manual annotations, and
;; update only changed sections.

(defun ogent-codemap--section-bounds (buffer relative-path)
  "Find the bounds of the section for RELATIVE-PATH in BUFFER.
Returns (START . END) positions, or nil if not found."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((pattern (format "^\\*\\* \\[\\[file:%s\\]"
                             (regexp-quote relative-path))))
        (when (re-search-forward pattern nil t)
          (let ((start (line-beginning-position))
                (end (save-excursion
                       (forward-line 1)
                       (if (re-search-forward "^\\*\\* " nil t)
                           (line-beginning-position)
                         (point-max)))))
            (cons start end)))))))

(defun ogent-codemap--remove-section (buffer relative-path)
  "Remove the section for RELATIVE-PATH from BUFFER.
Returns t if section was found and removed, nil otherwise."
  (when-let ((bounds (ogent-codemap--section-bounds buffer relative-path)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (delete-region (car bounds) (cdr bounds))))
    t))

(defun ogent-codemap--update-section (buffer file)
  "Update or insert the section for FILE in BUFFER.
Preserves any manual annotations. FILE is an absolute path."
  (let* ((root (ogent-codemap--project-root))
         (relative (file-relative-name file root))
         (bounds (ogent-codemap--section-bounds buffer relative))
         (old-annotations nil))
    ;; Extract annotations from old section if it exists
    (when bounds
      (with-current-buffer buffer
        (let ((old-text (buffer-substring-no-properties (car bounds) (cdr bounds))))
          (setq old-annotations (ogent-codemap--extract-annotations old-text)))))
    ;; Remove old section
    (when bounds
      (ogent-codemap--remove-section buffer relative))
    ;; Generate new content
    (let ((new-content
           (with-temp-buffer
             (ogent-codemap--insert-file (current-buffer) file)
             (buffer-string))))
      ;; Find insertion point (maintain sorted order by path)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (insert-point nil))
          (save-excursion
            (goto-char (point-min))
            ;; Find first file section that should come after this one
            (while (and (not insert-point)
                        (re-search-forward "^\\*\\* \\[\\[file:\\([^]]+\\)\\]" nil t))
              (let ((other-path (match-string 1)))
                (when (string> other-path relative)
                  (setq insert-point (line-beginning-position)))))
            ;; If no insertion point found, append at end
            (unless insert-point
              (goto-char (point-max))
              (setq insert-point (point))))
          ;; Insert new content
          (goto-char insert-point)
          (insert new-content)
          ;; Re-insert annotations after the heading line
          (when old-annotations
            (goto-char insert-point)
            (forward-line 1)
            ;; Skip Tests: line if present
            (when (looking-at "^Tests\\( for\\)?: ")
              (forward-line 1))
            (dolist (ann old-annotations)
              (insert ann "\n"))))))))

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

(defun ogent-codemap--render-full ()
  "Do a full render of the codemap buffer.
Erases buffer and rebuilds from scratch, preserving annotations."
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
    ;; Update snapshot after full render
    (setq ogent-codemap--last-file-snapshot (ogent-codemap--snapshot-files))
    buffer))

(defun ogent-codemap--render-incremental ()
  "Do an incremental render, updating only changed sections.
Returns the codemap buffer, or nil if full render is needed."
  (let ((buffer (get-buffer ogent-codemap-buffer-name)))
    ;; Need existing buffer with content for incremental
    (when (and buffer
               (buffer-live-p buffer)
               (> (buffer-size buffer) 0)
               ogent-codemap--last-file-snapshot)
      (let* ((changes (ogent-codemap--detect-changes))
             (added (plist-get changes :added))
             (modified (plist-get changes :modified))
             (removed (plist-get changes :removed))
             (root (ogent-codemap--project-root)))
        ;; If nothing changed, just return the buffer
        (if (and (null added) (null modified) (null removed))
            buffer
          ;; Apply incremental updates
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              ;; Remove deleted files
              (dolist (file removed)
                (let ((relative (file-relative-name file root)))
                  (ogent-codemap--remove-section buffer relative)))
              ;; Update modified files (preserves annotations)
              (dolist (file modified)
                (ogent-codemap--update-section buffer file))
              ;; Add new files
              (dolist (file added)
                (ogent-codemap--update-section buffer file))))
          ;; Update snapshot
          (setq ogent-codemap--last-file-snapshot (ogent-codemap--snapshot-files))
          ;; Report what changed
          (when (called-interactively-p 'any)
            (message "Codemap: %d added, %d modified, %d removed"
                     (length added) (length modified) (length removed)))
          buffer)))))

(defun ogent-codemap--render ()
  "Assemble the codemap buffer and return it.
Uses incremental refresh when possible, falls back to full render."
  (or (ogent-codemap--render-incremental)
      (ogent-codemap--render-full)))

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
  "Rebuild the codemap buffer and return it.
Uses incremental refresh when possible."
  (interactive)
  (ogent-codemap--render))

;;;###autoload
(defun ogent-codemap-refresh-full ()
  "Force a full rebuild of the codemap, ignoring cache."
  (interactive)
  (ogent-codemap-clear-cache)
  (ogent-codemap--render-full))

;;;###autoload
(defun ogent-codemap-changes ()
  "Show what files have changed since last codemap refresh.
Returns a summary of added, modified, and removed files."
  (interactive)
  (let ((changes (ogent-codemap--detect-changes)))
    (if (called-interactively-p 'any)
        (let ((added (plist-get changes :added))
              (modified (plist-get changes :modified))
              (removed (plist-get changes :removed))
              (root (ogent-codemap--project-root)))
          (if (and (null added) (null modified) (null removed))
              (message "No changes since last refresh")
            (with-output-to-temp-buffer "*codemap-changes*"
              (princ "Codemap Changes\n")
              (princ "===============\n\n")
              (when added
                (princ (format "Added (%d):\n" (length added)))
                (dolist (f added)
                  (princ (format "  + %s\n" (file-relative-name f root)))))
              (when modified
                (princ (format "\nModified (%d):\n" (length modified)))
                (dolist (f modified)
                  (princ (format "  ~ %s\n" (file-relative-name f root)))))
              (when removed
                (princ (format "\nRemoved (%d):\n" (length removed)))
                (dolist (f removed)
                  (princ (format "  - %s\n" (file-relative-name f root))))))))
      changes)))

;;; Handle Integration
;;
;; Support @codemap handle in prompts to include the codemap content.

(defun ogent-codemap--as-content ()
  "Return the codemap content as a string.
Generates the codemap if needed."
  (with-current-buffer (ogent-codemap--render)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ogent-codemap-handle-p (handle)
  "Return non-nil if HANDLE is a static codemap handle.
Returns nil for task-scoped handles like codemap-task:..."
  (and (string-match-p "^codemap\\(-[a-z]+\\)?$" handle)
       (not (string-match-p "^codemap-task:" handle))))

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
  (let ((section-rx (format "^\\*\\* \\[\\[file:%s/" (regexp-quote section))))
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
          ;; Keep searching until we find a file from a different section
          (while (and (not end)
                      (re-search-forward "^\\*\\* \\[\\[file:\\([^/]+\\)/" nil t))
            (let ((next-dir (match-string 1)))
              (if (string= next-dir section)
                  ;; Same section, continue searching
                  (forward-line 1)
                ;; Different section, mark end
                (beginning-of-line)
                (setq end (point)))))
          ;; If we didn't find a different section, use end of buffer
          (unless end
            (setq end (point-max))))
        (if (and start end)
            (buffer-substring-no-properties start end)
          (format "No %s/ section found in codemap" section))))))

;;; LLM-Powered Task-Scoped Codemap
;;
;; Generate intelligent, task-focused codemaps using LLM analysis.
;; These codemaps are scoped to a specific question/task and identify
;; relevant files, functions, and data flows.

;; Forward declarations for gptel
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(defvar gptel-model)

(defcustom ogent-codemap-llm-model nil
  "Model to use for codemap generation. nil means use gptel default."
  :type '(choice (const :tag "Use gptel default" nil)
                 (string :tag "Model identifier"))
  :group 'ogent)

(defcustom ogent-codemap-cache-directory
  (expand-file-name "codemap-cache" user-emacs-directory)
  "Directory for storing cached task codemaps."
  :type 'directory
  :group 'ogent)

(defcustom ogent-codemap-cache-ttl 3600
  "Time-to-live for cached codemaps in seconds."
  :type 'integer
  :group 'ogent)

(defvar ogent-codemap--task-cache (make-hash-table :test 'equal)
  "In-memory cache for task codemaps.
Keys are (task-hash . file-hash), values are plists with
:content and :timestamp.")

(defvar ogent-codemap--pending-requests (make-hash-table :test 'equal)
  "Track pending LLM requests by task hash to avoid duplicates.")

;;; Task Hash Generation

(defun ogent-codemap--task-hash (task)
  "Generate a hash for TASK string."
  (md5 (downcase (string-trim task))))

(defun ogent-codemap--files-hash ()
  "Generate a hash of all source file modification times.
Used to invalidate cache when files change."
  (let ((files (ogent-codemap--source-files))
        (mtimes nil))
    (dolist (file files)
      (when-let ((attrs (file-attributes file)))
        (push (format "%s:%s" file (file-attribute-modification-time attrs))
              mtimes)))
    (md5 (string-join (sort mtimes #'string<) "\n"))))

(defun ogent-codemap--cache-key (task)
  "Generate cache key for TASK."
  (let ((task-hash (ogent-codemap--task-hash task))
        (files-hash (ogent-codemap--files-hash)))
    (format "%s:%s" task-hash (substring files-hash 0 8))))

;;; Cache Management

(defun ogent-codemap--cache-get (cache-key)
  "Get cached codemap for CACHE-KEY if valid."
  (when-let ((entry (gethash cache-key ogent-codemap--task-cache)))
    (let ((timestamp (plist-get entry :timestamp))
          (now (float-time)))
      (when (< (- now timestamp) ogent-codemap-cache-ttl)
        (plist-get entry :content)))))

(defun ogent-codemap--cache-put (cache-key content)
  "Store CONTENT in cache with CACHE-KEY."
  (puthash cache-key
           (list :content content :timestamp (float-time))
           ogent-codemap--task-cache))

(defun ogent-codemap-clear-task-cache ()
  "Clear the task codemap cache."
  (interactive)
  (clrhash ogent-codemap--task-cache)
  (message "Task codemap cache cleared"))

;;; File Summary Generation

(defun ogent-codemap--file-summary (file)
  "Generate a brief summary of FILE for the LLM prompt."
  (let* ((root (ogent-codemap--project-root))
         (relative (file-relative-name file root))
         (file-type (ogent-codemap--file-type file)))
    (pcase file-type
      ('elisp
       (let ((defs (ogent-codemap--get-cached-or-scan file 'elisp)))
         (format "- %s (elisp): %s"
                 relative
                 (if defs
                     (string-join (seq-take defs 5) ", ")
                   "no ogent- functions"))))
      ('elisp-test
       (let ((tests (ogent-codemap--get-cached-or-scan file 'elisp-test)))
         (format "- %s (test): %d tests"
                 relative
                 (length tests))))
      ('org
       (format "- %s (org doc)" relative))
      ('markdown
       (format "- %s (markdown doc)" relative))
      (_ (format "- %s" relative)))))

(defun ogent-codemap--all-file-summaries ()
  "Generate summaries for all project files."
  (let ((files (ogent-codemap--source-files)))
    (mapconcat #'ogent-codemap--file-summary files "\n")))

;;; LLM Prompt Construction

(defconst ogent-codemap--system-prompt
  "You are a code analysis assistant. Given a task and a list of project files,
identify which files and functions are most relevant to the task.

Output format: Org-mode with the following structure:

* Codemap: <brief task summary>
** Overview
<1-2 sentence summary of how the task relates to the codebase>

** Key Files
List the most relevant files with brief explanations:
*** [[file:path/to/file.el][filename.el]]
Why this file is relevant to the task.

** Key Functions
List the most important functions:
*** [[file:path/to/file.el::function-name][function-name]]
Brief description of what it does and why it matters for this task.

** Data Flow
If relevant, describe how data flows through the system for this task.

** Dependencies
Note any important dependencies or related components.

Rules:
- Only include genuinely relevant files (aim for 3-7 key files)
- Use Org file: links for navigation
- Keep descriptions concise (1-2 sentences each)
- Focus on the \"why\" - how each item relates to the task"
  "System prompt for codemap generation.")

(defun ogent-codemap--build-prompt (task)
  "Build the LLM prompt for TASK."
  (let ((file-summaries (ogent-codemap--all-file-summaries)))
    (format "Task: %s

Project files:
%s

Generate a task-focused codemap identifying the most relevant files and functions for this task."
            task file-summaries)))

;;; LLM Request

(defun ogent-codemap--generate-async (task callback)
  "Generate codemap for TASK asynchronously, calling CALLBACK with result.
CALLBACK receives (content error) where error is nil on success."
  (unless (require 'gptel nil 'noerror)
    (funcall callback nil "gptel is required for LLM codemap generation"))
  
  (let* ((cache-key (ogent-codemap--cache-key task))
         (cached (ogent-codemap--cache-get cache-key)))
    ;; Check cache first
    (if cached
        (funcall callback cached nil)
      ;; Check for pending request
      (if (gethash cache-key ogent-codemap--pending-requests)
          (funcall callback nil "Request already pending for this task")
        ;; Make LLM request
        (puthash cache-key t ogent-codemap--pending-requests)
        (let ((prompt (ogent-codemap--build-prompt task))
              (accumulated ""))
          (gptel-request prompt
                         :system ogent-codemap--system-prompt
                         :stream t
                         :callback
                         (lambda (text info)
                           (cond
                            ;; Error
                            ((and (listp info) (plist-get info :error))
                             (remhash cache-key ogent-codemap--pending-requests)
                             (funcall callback nil (plist-get info :error)))
                            ;; Streaming content
                            ((stringp text)
                             (setq accumulated (concat accumulated text)))
                            ;; Complete
                            ((or (and (listp info)
                                      (or (plist-get info :done)
                                          (plist-get info :final)
                                          (equal (plist-get info :status) "success")))
                                 (and (not (stringp text)) (listp info) info))
                             (remhash cache-key ogent-codemap--pending-requests)
                             (when (> (length accumulated) 0)
                               (ogent-codemap--cache-put cache-key accumulated))
                             (funcall callback accumulated nil))))))))))

;;; Interactive Commands

(defvar ogent-codemap--task-buffer-name "*ogent-codemap-task*"
  "Buffer name for task-scoped codemaps.")

(defvar ogent-codemap--current-task nil
  "The current task for which codemap was generated.")

;;;###autoload
(defun ogent-codemap-generate (task)
  "Generate an LLM-powered codemap for TASK.
TASK is a question or description of what you want to understand.
The codemap identifies relevant files, functions, and data flows.

Interactively, prompts for the task description."
  (interactive "sWhat do you want to understand? ")
  (when (string-empty-p (string-trim task))
    (user-error "Task description cannot be empty"))
  
  (message "Generating codemap for: %s..." (truncate-string-to-width task 50))
  
  (ogent-codemap--generate-async
   task
   (lambda (content error)
     (if error
         (message "Codemap generation failed: %s" error)
       (ogent-codemap--display-task-codemap task content)))))

(defun ogent-codemap--display-task-codemap (task content)
  "Display CONTENT as the codemap for TASK."
  (let ((buf (get-buffer-create ogent-codemap--task-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (org-mode)
        (setq-local ogent-codemap--current-task task)
        (setq buffer-read-only t)))
    (display-buffer buf '((display-buffer-in-side-window)
                          (side . right)
                          (window-width . 0.4)))
    (message "Codemap generated for: %s" (truncate-string-to-width task 50))))

;;;###autoload
(defun ogent-codemap-regenerate ()
  "Regenerate the codemap for the current task, bypassing cache."
  (interactive)
  (unless ogent-codemap--current-task
    (user-error "No current task codemap to regenerate"))
  (let ((task ogent-codemap--current-task))
    ;; Remove from cache
    (let ((cache-key (ogent-codemap--cache-key task)))
      (remhash cache-key ogent-codemap--task-cache))
    ;; Regenerate
    (ogent-codemap-generate task)))

;;; Task Handle Integration
;;
;; Support @codemap-task:<description> handles in prompts.
;; The handle triggers async generation and includes the result.

(defvar ogent-codemap--task-handles (make-hash-table :test 'equal)
  "Registry of task handles to their generated content.
Keys are handle strings, values are content strings or nil if pending.")

(defun ogent-codemap-task-handle-p (handle)
  "Return non-nil if HANDLE is a task-scoped codemap handle.
Matches @codemap-task:<task-description> pattern."
  (string-match-p "^codemap-task:" handle))

(defun ogent-codemap--extract-task-from-handle (handle)
  "Extract the task description from a codemap-task HANDLE."
  (when (string-match "^codemap-task:\\(.+\\)$" handle)
    (match-string 1 handle)))

(defun ogent-codemap-resolve-task-handle (handle)
  "Resolve a task-scoped codemap HANDLE.
Returns cached content if available, or triggers generation and returns placeholder."
  (when (ogent-codemap-task-handle-p handle)
    (let* ((task (ogent-codemap--extract-task-from-handle handle))
           (cache-key (ogent-codemap--cache-key task))
           (cached (ogent-codemap--cache-get cache-key)))
      (if cached
          cached
        ;; Return placeholder and trigger async generation
        (ogent-codemap--generate-async
         task
         (lambda (content _error)
           (when content
             (puthash handle content ogent-codemap--task-handles))))
        (format "* Codemap: %s\n[Generating task-focused codemap...]\n" task)))))

;;; Enhanced Handle Resolution

(defun ogent-codemap-resolve-handle-enhanced (handle)
  "Resolve any codemap HANDLE (static or task-scoped).
Supports:
  @codemap - full static codemap
  @codemap-lisp - only lisp/ section
  @codemap-task:<desc> - LLM-generated task-focused codemap"
  (cond
   ((ogent-codemap-task-handle-p handle)
    (ogent-codemap-resolve-task-handle handle))
   ((ogent-codemap-handle-p handle)
    (ogent-codemap-resolve-handle handle))
   (t nil)))

(provide 'ogent-codemap)

;;; ogent-codemap.el ends here

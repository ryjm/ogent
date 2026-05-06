;;; ogent-cabinet-data.el --- Cabinet data browser and page operations -*- lexical-binding: t; -*-

;;; Commentary:
;; Org-native page creation, movement, export, viewer dispatch, and a dense
;; data browser over Cabinet files.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'org)
(require 'org-element)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'time-date)
(require 'browse-url)
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)

(defgroup ogent-cabinet-data nil
  "Cabinet data browser and page operations."
  :group 'ogent-cabinet)

(defcustom ogent-cabinet-data-buffer-name-format "*ogent-cabinet-data:%s*"
  "Format string used for Cabinet data browser buffers."
  :type 'string
  :group 'ogent-cabinet-data)

(defvar-local ogent-cabinet-data--root nil
  "Cabinet root shown by the current data browser.")

(defun ogent-cabinet-data--root (directory)
  "Return the Cabinet root for DIRECTORY."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (or (ogent-cabinet-find-root candidate) candidate)))
    (directory-file-name
     (file-truename (ogent-cabinet--directory root)))))

(defun ogent-cabinet-data--hidden-file-p (root file)
  "Return non-nil when FILE is transient Cabinet or editor state."
  (let ((name (file-name-nondirectory file)))
    (or (member name '("." ".."))
        (string-prefix-p ".#" name)
        (string-suffix-p "~" name)
        (ogent-cabinet--hidden-path-p root file))))

(defun ogent-cabinet-data--source-extension-p (extension)
  "Return non-nil when EXTENSION is commonly opened as source text."
  (member extension
          '("el" "lisp" "scm" "clj" "cljs" "ts" "tsx" "js" "jsx" "css"
            "scss" "html" "json" "toml" "yaml" "yml" "rs" "py" "rb" "go"
            "java" "c" "h" "cpp" "hpp" "sh" "zsh" "fish" "sql" "md"
            "org" "txt")))

(defun ogent-cabinet-data-file-kind (file)
  "Return the Cabinet data kind for FILE."
  (cond
   ((file-directory-p file) 'directory)
   ((string-equal (file-name-extension file) "org") 'page)
   ((member (downcase (or (file-name-extension file) ""))
            '("png" "jpg" "jpeg" "gif" "webp" "svg" "tif" "tiff"))
    'image)
   ((string-equal (downcase (or (file-name-extension file) "")) "pdf")
    'pdf)
   ((member (downcase (or (file-name-extension file) ""))
            '("csv" "tsv"))
    'csv)
   ((member (downcase (or (file-name-extension file) ""))
            '("mp3" "wav" "m4a" "mp4" "mov" "webm" "ogg"))
    'media)
   ((member (downcase (or (file-name-extension file) ""))
            '("html" "htm"))
    'html)
   ((ogent-cabinet-data--source-extension-p
     (downcase (or (file-name-extension file) "")))
    'source)
   (t 'file)))

(defun ogent-cabinet-data-files (directory)
  "Return durable data files under DIRECTORY."
  (let* ((root (ogent-cabinet-data--root directory))
         (files nil))
    (dolist (file (directory-files-recursively root directory-files-no-dot-files-regexp))
      (when (and (file-regular-p file)
                 (not (ogent-cabinet-data--hidden-file-p root file)))
        (push file files)))
    (seq-sort #'string< files)))

(defun ogent-cabinet-data--file-title (file)
  "Return a friendly title for FILE."
  (if (and (file-readable-p file)
           (string-equal (file-name-extension file) "org"))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file nil 0 nil)
            (ogent-cabinet--org-mode)
            (let* ((keywords (org-collect-keywords '("TITLE")))
                   (title (cadr (assoc "TITLE" keywords))))
              (or (ogent-cabinet--blank-to-nil title)
                  (ogent-cabinet--first-heading-title)
                  (file-name-base file))))
        (error (file-name-base file)))
    (file-name-nondirectory file)))

(defun ogent-cabinet-data-records (directory)
  "Return file records for the Cabinet data browser under DIRECTORY."
  (let ((root (ogent-cabinet-data--root directory)))
    (mapcar
     (lambda (file)
       (let* ((attrs (file-attributes file))
              (relative (file-relative-name file root)))
         (list :path file
               :relative relative
               :kind (ogent-cabinet-data-file-kind file)
               :title (ogent-cabinet-data--file-title file)
               :modified (format-time-string
                          "%Y-%m-%d %H:%M"
                          (file-attribute-modification-time attrs))
               :size (file-attribute-size attrs))))
     (ogent-cabinet-data-files root))))

(defun ogent-cabinet-page--target-file (root title path)
  "Return the target Org file under ROOT for TITLE and optional PATH."
  (let ((target (or path
                    (concat (ogent-cabinet--slug title "page") ".org"))))
    (if (file-name-absolute-p target)
        target
      (expand-file-name target root))))

(defun ogent-cabinet-page--iso-now ()
  "Return the current time as an ISO-like timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

;;;###autoload
(cl-defun ogent-cabinet-page-create
    (directory title &key path kind tags body)
  "Create an Org Cabinet page under DIRECTORY with TITLE.
PATH is relative to the Cabinet root unless absolute."
  (interactive
   (let ((root (or (ogent-cabinet-find-root)
                   (read-directory-name "Cabinet root: "))))
     (list root (read-string "Page title: "))))
  (let* ((root (ogent-cabinet-data--root directory))
         (file (ogent-cabinet-page--target-file root title path))
         (relative-dir (file-relative-name (file-name-directory file) root))
         (now (ogent-cabinet-page--iso-now)))
    (when (file-exists-p file)
      (user-error "Cabinet page already exists: %s" file))
    (make-directory (file-name-directory file) t)
    (ogent-cabinet--write-file
     file
     (concat
      (format "#+title: %s\n\n" title)
      (format "* %s\n" title)
      (ogent-cabinet--format-properties
       `(("OGENT_PAGE" . t)
         ("OGENT_TITLE" . ,title)
         ("OGENT_KIND" . ,(or kind "page"))
         ("OGENT_DIR" . ,(if (string-prefix-p "." relative-dir)
                             ""
                           (directory-file-name relative-dir)))
         ("OGENT_TAGS" . ,tags)
         ("OGENT_CREATED_AT" . ,now)
         ("OGENT_UPDATED_AT" . ,now)))
      "\n"
      (when body
        (concat (string-trim body) "\n"))))
    file))

(defun ogent-cabinet-page-read (file)
  "Read Cabinet page metadata from FILE."
  (unless (file-readable-p file)
    (user-error "Cabinet page not readable: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (ogent-cabinet--org-mode)
    (let ((heading (condition-case nil
                       (ogent-cabinet--first-heading-title)
                     (error nil))))
      (list :path file
            :title (or (ogent-cabinet--blank-to-nil
                        (org-entry-get nil "OGENT_TITLE"))
                       (ogent-cabinet-data--file-title file)
                       heading)
            :kind (ogent-cabinet--blank-to-nil
                   (org-entry-get nil "OGENT_KIND"))
            :dir (ogent-cabinet--blank-to-nil
                  (org-entry-get nil "OGENT_DIR"))
            :tags (ogent-cabinet--tags-from-string
                   (org-entry-get nil "OGENT_TAGS"))
            :created-at (ogent-cabinet--blank-to-nil
                         (org-entry-get nil "OGENT_CREATED_AT"))
            :updated-at (ogent-cabinet--blank-to-nil
                         (org-entry-get nil "OGENT_UPDATED_AT"))
            :body (ogent-cabinet--heading-body)))))

(defun ogent-cabinet-page--set-title (file title)
  "Set FILE title metadata and first Org heading to TITLE."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (org-mode)
      (goto-char (point-min))
      (if (re-search-forward "^#\\+title:.*$" nil t)
          (replace-match (format "#+title: %s" title) t t)
        (goto-char (point-min))
        (insert (format "#+title: %s\n\n" title)))
      (goto-char (point-min))
      (unless (re-search-forward org-heading-regexp nil t)
        (goto-char (point-max))
        (insert (format "\n* %s\n" title)))
      (org-back-to-heading t)
      (org-edit-headline title)
      (org-entry-put nil "OGENT_TITLE" title)
      (org-entry-put nil "OGENT_UPDATED_AT" (ogent-cabinet-page--iso-now))
      (save-buffer))))

(defun ogent-cabinet-page--rewrite-links (root old-file new-file)
  "Rewrite Org file links from OLD-FILE to NEW-FILE under ROOT."
  (let ((old-relative (file-relative-name old-file root))
        (new-relative (file-relative-name new-file root)))
    (dolist (file (ogent-cabinet-org-files root))
      (when (file-readable-p file)
        (let ((buffer (find-file-noselect file)))
          (with-current-buffer buffer
            (goto-char (point-min))
            (org-element-map (org-element-parse-buffer) 'link
              (lambda (link)
                (when (and (equal (org-element-property :type link) "file")
                           (equal (org-element-property :path link)
                                  old-relative))
                  (goto-char (org-element-property :begin link))
                  (let ((end (or (org-element-property :contents-begin link)
                                 (org-element-property :end link))))
                    (when (search-forward old-relative end t)
                      (replace-match new-relative t t))))))
            (when (buffer-modified-p)
              (save-buffer))))))))

;;;###autoload
(cl-defun ogent-cabinet-page-rename
    (directory file title &key keep-file-name)
  "Rename Cabinet page FILE under DIRECTORY to TITLE.
When KEEP-FILE-NAME is non-nil, only page title metadata changes."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (file (ogent-cabinet-data--read-file root "Rename page: " 'page)))
     (list root file (read-string "New title: "))))
  (let* ((root (ogent-cabinet-data--root directory))
         (old-file (expand-file-name file root))
         (new-file (if keep-file-name
                       old-file
                     (expand-file-name
                      (concat (ogent-cabinet--slug title "page") ".org")
                      (file-name-directory old-file)))))
    (unless (file-exists-p old-file)
      (user-error "Cabinet page not found: %s" old-file))
    (unless (equal old-file new-file)
      (when (file-exists-p new-file)
        (user-error "Target page already exists: %s" new-file))
      (rename-file old-file new-file)
      (ogent-cabinet-page--rewrite-links root old-file new-file))
    (ogent-cabinet-page--set-title new-file title)
    new-file))

;;;###autoload
(defun ogent-cabinet-page-move (directory file target-directory)
  "Move Cabinet page FILE under DIRECTORY into TARGET-DIRECTORY."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (file (ogent-cabinet-data--read-file root "Move page: " 'page)))
     (list root file (read-directory-name "Target directory: " root))))
  (let* ((root (ogent-cabinet-data--root directory))
         (old-file (expand-file-name file root))
         (target-dir (if (file-name-absolute-p target-directory)
                         target-directory
                       (expand-file-name target-directory root)))
         (new-file (expand-file-name (file-name-nondirectory old-file)
                                     target-dir)))
    (unless (file-exists-p old-file)
      (user-error "Cabinet page not found: %s" old-file))
    (make-directory target-dir t)
    (when (file-exists-p new-file)
      (user-error "Target page already exists: %s" new-file))
    (rename-file old-file new-file)
    (ogent-cabinet-page--rewrite-links root old-file new-file)
    (ogent-cabinet--update-first-heading-property
     new-file
     "OGENT_DIR"
     (file-relative-name target-dir root))
    (ogent-cabinet--update-first-heading-property
     new-file
     "OGENT_UPDATED_AT"
     (ogent-cabinet-page--iso-now))
    new-file))

;;;###autoload
(cl-defun ogent-cabinet-page-delete (directory file &key hard)
  "Delete Cabinet page FILE under DIRECTORY.
By default the page is moved to `.cabinet-state/trash/'.  HARD removes it."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (file (ogent-cabinet-data--read-file root "Delete page: " 'page)))
     (list root file)))
  (let* ((root (ogent-cabinet-data--root directory))
         (path (expand-file-name file root)))
    (unless (file-exists-p path)
      (user-error "Cabinet page not found: %s" path))
    (if hard
        (progn
          (delete-file path)
          nil)
      (let* ((trash-dir (expand-file-name ".cabinet-state/trash" root))
             (target (expand-file-name
                      (format "%s-%s"
                              (format-time-string "%Y%m%dT%H%M%S")
                              (file-name-nondirectory path))
                      trash-dir)))
        (make-directory trash-dir t)
        (rename-file path target)
        target))))

;;;###autoload
(cl-defun ogent-cabinet-page-export (file format &optional output)
  "Export Org page FILE as FORMAT to OUTPUT.
FORMAT may be `html', `md', `text', or `org'."
  (interactive
   (let* ((file (read-file-name "Org page: " nil nil t nil
                                (lambda (path)
                                  (string-suffix-p ".org" path))))
          (format (intern
                   (completing-read "Format: "
                                    '("html" "md" "text" "org")
                                    nil t))))
     (list file format nil)))
  (let* ((backend (pcase format
                    ('html (require 'ox-html) 'html)
                    ('md (require 'ox-md) 'md)
                    ('text (require 'ox-ascii) 'ascii)
                    ('org nil)
                    (_ (user-error "Unsupported export format: %s" format))))
         (extension (pcase format
                      ('html ".html")
                      ('md ".md")
                      ('text ".txt")
                      ('org ".org")))
         (target (or output
                     (concat (file-name-sans-extension file) extension))))
    (if backend
        (with-current-buffer (find-file-noselect file)
          (org-mode)
          (org-export-to-file backend target nil nil nil t))
      (copy-file file target t)
      target)))

;;;###autoload
(defun ogent-cabinet-open-file (file)
  "Open FILE with an Emacs-native or browser viewer and return the dispatch."
  (interactive "fOpen Cabinet file: ")
  (if (string-match-p "\\`https?://" file)
      (progn
        (browse-url file)
        'url)
    (let* ((path (expand-file-name file))
           (extension (downcase (or (file-name-extension path) ""))))
      (cond
       ((file-directory-p path)
        (dired path)
        'directory)
       ((member extension '("html" "htm"))
        (browse-url-of-file path)
        'html)
       ((member extension '("png" "jpg" "jpeg" "gif" "webp" "svg" "pdf" "csv"
                            "tsv" "mp3" "wav" "m4a" "mp4" "mov" "webm" "ogg"))
        (find-file path)
        'file)
       (t
        (find-file path)
        'file)))))

(defun ogent-cabinet-data--read-file (directory prompt &optional kind)
  "Read a Cabinet file under DIRECTORY with PROMPT.
When KIND is non-nil, only records of that kind are offered."
  (let* ((root (ogent-cabinet-data--root directory))
         (records (seq-filter
                   (lambda (record)
                     (or (null kind)
                         (eq (plist-get record :kind) kind)))
                   (ogent-cabinet-data-records root)))
         (choices (mapcar (lambda (record)
                            (plist-get record :relative))
                          records))
         (choice (completing-read prompt choices nil t)))
    (expand-file-name choice root)))

(defvar ogent-cabinet-data-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-data-open))
    (define-key map "c" #'ogent-cabinet-data-create-page)
    (define-key map "r" #'ogent-cabinet-data-rename-page)
    (define-key map "m" #'ogent-cabinet-data-move-page)
    (define-key map "D" #'ogent-cabinet-data-delete-page)
    (define-key map "e" #'ogent-cabinet-data-export-page)
    (define-key map "g" #'ogent-cabinet-data-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-data-mode'.")

(define-derived-mode ogent-cabinet-data-mode tabulated-list-mode
  "Cabinet-Data"
  "Major mode for Cabinet data browsing."
  :group 'ogent-cabinet-data
  (setq-local tabulated-list-format
              [("Kind" 12 t)
               ("Title" 28 t)
               ("Modified" 18 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Path" . nil))
  (setq-local revert-buffer-function #'ogent-cabinet-data-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-data--entry (record)
  "Return a tabulated entry for RECORD."
  (list
   record
   (vector
    (symbol-name (plist-get record :kind))
    (or (plist-get record :title) "")
    (or (plist-get record :modified) "")
    (plist-get record :relative))))

(defun ogent-cabinet-data--entries ()
  "Return tabulated entries for the current data browser."
  (mapcar #'ogent-cabinet-data--entry
          (ogent-cabinet-data-records ogent-cabinet-data--root)))

;;;###autoload
(defun ogent-cabinet-data (&optional directory)
  "Open the Cabinet data browser for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-data--root directory))
         (buffer (get-buffer-create
                  (format ogent-cabinet-data-buffer-name-format
                          (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (ogent-cabinet-data-mode)
      (setq ogent-cabinet-data--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-data--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-data-refresh (&rest _)
  "Refresh the current Cabinet data browser."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-data--item ()
  "Return the data record at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet data record at point")))

(defun ogent-cabinet-data-open ()
  "Open the Cabinet data record at point."
  (interactive)
  (ogent-cabinet-open-file (plist-get (ogent-cabinet-data--item) :path)))

(defun ogent-cabinet-data-create-page ()
  "Create a Cabinet page from the current data browser."
  (interactive)
  (let ((file (ogent-cabinet-page-create
               ogent-cabinet-data--root
               (read-string "Page title: "))))
    (ogent-cabinet-data-refresh)
    (find-file file)))

(defun ogent-cabinet-data-rename-page ()
  "Rename the page at point."
  (interactive)
  (let ((item (ogent-cabinet-data--item)))
    (unless (eq (plist-get item :kind) 'page)
      (user-error "Selected data record is not an Org page"))
    (ogent-cabinet-page-rename
     ogent-cabinet-data--root
     (plist-get item :path)
     (read-string "New title: " (plist-get item :title)))
    (ogent-cabinet-data-refresh)))

(defun ogent-cabinet-data-move-page ()
  "Move the page at point."
  (interactive)
  (let ((item (ogent-cabinet-data--item)))
    (unless (eq (plist-get item :kind) 'page)
      (user-error "Selected data record is not an Org page"))
    (ogent-cabinet-page-move
     ogent-cabinet-data--root
     (plist-get item :path)
     (read-directory-name "Target directory: " ogent-cabinet-data--root))
    (ogent-cabinet-data-refresh)))

(defun ogent-cabinet-data-delete-page ()
  "Move the page at point to Cabinet trash."
  (interactive)
  (let ((item (ogent-cabinet-data--item)))
    (unless (eq (plist-get item :kind) 'page)
      (user-error "Selected data record is not an Org page"))
    (when (yes-or-no-p (format "Delete page %s? " (plist-get item :relative)))
      (ogent-cabinet-page-delete
       ogent-cabinet-data--root
       (plist-get item :path))
      (ogent-cabinet-data-refresh))))

(defun ogent-cabinet-data-export-page ()
  "Export the page at point."
  (interactive)
  (let ((item (ogent-cabinet-data--item)))
    (unless (eq (plist-get item :kind) 'page)
      (user-error "Selected data record is not an Org page"))
    (message "Exported %s"
             (ogent-cabinet-page-export
              (plist-get item :path)
              (intern (completing-read "Format: "
                                       '("html" "md" "text" "org")
                                       nil t))))))

(defun ogent-cabinet-data--evil-local-keys ()
  "Install local Evil keys for Cabinet data."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-data-mode-map))

(defun ogent-cabinet-data--setup-evil ()
  "Set up Evil integration for Cabinet data."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-data-mode
   ogent-cabinet-data-mode-map
   'ogent-cabinet-data-mode-hook
   #'ogent-cabinet-data--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-data--setup-evil))

(provide 'ogent-cabinet-data)

;;; ogent-cabinet-data.el ends here

;;; ogent-tool-results.el --- Structured file tool results -*- lexical-binding: t; -*-

;;; Commentary:
;; Return bounded pages with explicit positions and snapshot identities.
;; Keep source data separate from legacy human-readable tool rendering.

;;; Code:

(require 'json)
(require 'ogent-tools)

(defun ogent-tool-results-format (data format)
  "Return DATA as a plist or serialize it according to FORMAT."
  (pcase format
    ('plist data)
    ('json (concat (json-serialize data :null-object :json-null
                                   :false-object :json-false) "\n"))
    (_ (user-error "Use (quote plist) or (quote json) for structured tool results"))))

(defun ogent-tool-results-read (file-path &optional offset limit column)
  "Return a bounded structured page from FILE-PATH at OFFSET and COLUMN.
Count lines from one and columns from one.  LIMIT defaults to 200 lines.
Preserve a continuation position even when a single line exceeds the output
budget.  Snapshot the decoded content so callers can detect changed pages."
  (unless (and (stringp file-path) (not (string-empty-p file-path)))
    (user-error "Provide a nonempty file_path; use glob to discover files"))
  (let* ((path (ogent-tools--resolve-path file-path))
         (offset (or offset 1)) (limit (or limit 200)) (column (or column 1))
         (budget ogent-tools-max-output-chars))
    (dolist (position (list offset column))
      (unless (and (integerp position) (> position 0))
        (user-error "Use positive integer offset and column positions starting at 1")))
    (unless (and (integerp limit) (> limit 0) (<= limit ogent-tools-max-file-lines))
      (user-error "Use a positive limit no larger than %d lines" ogent-tools-max-file-lines))
    (unless (and (integerp budget) (> budget 0))
      (user-error "Set ogent-tools-max-output-chars to a positive integer"))
    (unless (and (file-regular-p path) (file-readable-p path))
      (user-error "File not readable: %s; use glob to choose a readable regular file" path))
    (with-temp-buffer
      (insert-file-contents path)
      (when (search-forward "\0" nil t)
        (user-error "Binary file detected: %s; choose a text file" path))
      (let* ((content (buffer-string))
             (lines (unless (string-empty-p content) (split-string content "\n")))
             (snapshot (secure-hash 'sha256 content))
             page (used 0) (line-number offset) (next-column column))
        (when (string-suffix-p "\n" content) (setq lines (butlast lines)))
        (unless (or (and (null lines) (= offset 1) (= column 1))
                    (and (<= offset (length lines))
                         (<= column (1+ (length (nth (1- offset) lines))))))
          (user-error "Position exceeds file contents; restart with offset=1 and column=1"))
        (while (and (<= line-number (length lines))
                    (< (length page) limit) (< used budget))
          (let* ((line (nth (1- line-number) lines))
                 (start (1- next-column))
                 (available (- budget used))
                 (text (substring line start (min (length line) (+ start available))))
                 (partial (< (+ start (length text)) (length line))))
            (push (list :number line-number :column next-column :text text
                        :partial (if partial t :json-false)) page)
            (cl-incf used (length text))
            (if partial
                (setq next-column (+ next-column (length text)) used budget)
              (cl-incf line-number)
              (setq next-column 1)
              ;; Account for separators included in the content string.
              (when (< used budget) (cl-incf used)))))
        (setq page (nreverse page))
        (let ((more (<= line-number (length lines))))
          (list :path path :snapshot snapshot :total_lines (length lines)
                :offset offset :column column :limit limit
                :lines (vconcat page)
                :content (mapconcat (lambda (line) (plist-get line :text)) page "\n")
                :has_more (if more t :json-false)
                :next_offset (if more line-number :json-null)
                :next_column (if more next-column :json-null)))))))

(provide 'ogent-tool-results)
;;; ogent-tool-results.el ends here

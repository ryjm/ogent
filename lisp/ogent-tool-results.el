;;; ogent-tool-results.el --- Structured file tool results -*- lexical-binding: t; -*-

;;; Commentary:
;; Return bounded pages with explicit positions and snapshot identities.
;; Keep source data separate from legacy human-readable tool rendering.

;;; Code:

(require 'json)
(require 'ogent-tools)
(require 'ogent-tool-contract)

(define-error 'ogent-tool-results-output-error "Unsupported file output" 'user-error)

(defun ogent-tool-results--unicode (text)
  "Return TEXT when JSON can represent it as Unicode, otherwise signal."
  (condition-case nil (when (json-serialize text) text)
    (error (signal 'ogent-tool-results-output-error
                   '("Use a Unicode filename and a supported text encoding; raw bytes cannot be represented in structured results")))))

(defun ogent-tool-results-format (data format)
  "Return DATA as a plist or serialize it according to FORMAT."
  (pcase format
    ('plist data)
    ('json (ogent-tool-contract--json-text
            (concat (json-serialize data :null-object :json-null
                                    :false-object :json-false) "\n")))
    (_ (user-error "Use (quote plist) or (quote json) for structured tool results"))))

(defun ogent-tool-results-read (file-path &optional offset limit column)
  "Return a bounded structured page from FILE-PATH at OFFSET and COLUMN.
Count lines from one and columns from one.  LIMIT defaults to 200 lines.
Preserve a continuation position even when a single line exceeds the output
budget.  Snapshot the decoded content so callers can detect changed pages."
  (unless (and (stringp file-path) (not (string-empty-p file-path)))
    (user-error "Provide a nonempty file_path; use glob to discover files"))
  (let* ((path (ogent-tools--resolve-path file-path))
         (offset (or offset 1))
         (limit (or limit (min 200 ogent-tools-max-file-lines)))
         (column (or column 1))
         (budget ogent-tools-max-output-chars))
    (ogent-tool-results--unicode path)
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
      (let* ((content (ogent-tool-results--unicode (buffer-string)))
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
                :ends_with_newline (if (string-suffix-p "\n" content) t :json-false)
                :has_more (if more t :json-false)
                :next_offset (if more line-number :json-null)
                :next_column (if more next-column :json-null)))))))

(defun ogent-tool-results-glob (pattern &optional path offset limit)
  "Return a structured page of files matching PATTERN under PATH.
Sort by absolute path.  OFFSET starts at zero; LIMIT defaults to 100 and
must not exceed 200.  Report the total count and a snapshot of file metadata."
  (let ((offset (or offset 0)) (limit (or limit 100)))
    (unless (and (integerp offset) (>= offset 0))
      (user-error "Use a non-negative integer offset, starting at 0"))
    (unless (and (integerp limit) (> limit 0) (<= limit 200))
      (user-error "Use an integer limit between 1 and 200"))
    (let* ((root (ogent-tool-results--unicode (ogent-tools--resolve-path (or path "."))))
           (pattern (ogent-tool-results--unicode pattern))
           (files (sort (ogent-tools--glob-files pattern root #'ogent-tool-results--unicode) #'string<))
           (metadata (mapcar
                      (lambda (file)
                        (ogent-tool-results--unicode file)
                        (let ((attributes (file-attributes file)))
                          (list :path file :size (file-attribute-size attributes)
                                :modified (format "%S" (file-attribute-modification-time attributes)))))
                      files))
           (total (length files))
           (end (min total (+ offset limit))))
      (when (> offset total)
        (user-error "Offset %d exceeds %d files; restart with offset=0" offset total))
      (list :path root :pattern pattern :offset offset :limit limit
            :files (vconcat (seq-subseq metadata offset end))
            :total_files total :snapshot (secure-hash 'sha256 (prin1-to-string metadata))
            :has_more (if (< end total) t :json-false)
            :next_offset (if (< end total) end :json-null)))))

(provide 'ogent-tool-results)
;;; ogent-tool-results.el ends here

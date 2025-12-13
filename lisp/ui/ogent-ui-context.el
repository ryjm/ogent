;;; ogent-ui-context.el --- Interactive context preview for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Replaces static context formatting with interactive Org structure.
;; Provides clickable links, folding sections, and token/char counts.

;;; Code:

(require 'org)
(require 'ogent-context)

(defun ogent-ui-context--estimate-tokens (text)
  "Estimate the number of tokens in TEXT.
Uses ~4 characters per token approximation for English text."
  (if (or (null text) (string-empty-p text))
      0
    (ceiling (/ (float (length text)) 4.0))))

(defun ogent-ui-context--char-count (text)
  "Return character count of TEXT, handling nil."
  (if (or (null text) (string-empty-p text))
      0
    (length text)))

(defun ogent-ui-context--format-node-link (node)
  "Format NODE as an Org link with file:line reference.
Returns a string like: [[file:path.org::LINE][TITLE]] (id: ID)"
  (if (null node)
      "(no node)"
    (let* ((title (or (ogent-context-node-title node) "<untitled>"))
           (id (ogent-context-node-id node))
           (buffer (ogent-context-node-buffer node))
           (begin (ogent-context-node-begin node))
           (file (when buffer (buffer-file-name buffer)))
           (line (when (and buffer begin)
                   (with-current-buffer buffer
                     (line-number-at-pos begin)))))
      (if (and file line)
          (format "[[file:%s::%d][%s]] (id: %s)" file line title id)
        (format "%s (id: %s)" title id)))))

(defun ogent-ui-context--format-source-section (source-ctx)
  "Format SOURCE-CTX as an Org section with char count.
Returns a plist with :heading and :content."
  (let* ((file (or (ogent-source-context-file source-ctx) "(unsaved)"))
         (mode (ogent-source-context-mode source-ctx))
         (content (ogent-source-context-content source-ctx))
         (region-start (ogent-source-context-region-start source-ctx))
         (region-end (ogent-source-context-region-end source-ctx))
         (char-count (ogent-ui-context--char-count content))
         (region-info (if (and region-start region-end)
                          (format "Selected region (lines %d-%d)"
                                  (line-number-at-pos region-start)
                                  (line-number-at-pos region-end))
                        "Full buffer"))
         (heading (format "* Source Context [%d chars]" char-count))
         (body (format "File: %s\nMode: %s\n%s\n#+begin_src %s\n%s\n#+end_src"
                       (file-name-nondirectory file)
                       mode
                       region-info
                       (replace-regexp-in-string "-mode$" "" mode)
                       content)))
    (list :heading heading :content body :chars char-count)))

(defun ogent-ui-context--format-root-section (root)
  "Format ROOT node as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null root)
      (list :heading "* Root" :content "(no root node)" :chars 0)
    (let* ((content-text (or (ogent-context-node-content root) ""))
           (char-count (+ (ogent-ui-context--char-count content-text)
                          (ogent-ui-context--char-count
                           (ogent-context-node-title root))))
           (heading (format "* Root [%d chars]" char-count))
           (body (format "%s\n\n%s"
                         (ogent-ui-context--format-node-link root)
                         content-text)))
      (list :heading heading :content body :chars char-count))))

(defun ogent-ui-context--format-ancestors-section (ancestors)
  "Format ANCESTORS as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null ancestors)
      (list :heading "* Ancestors" :content "(none)" :chars 0)
    (let* ((lines (mapcar (lambda (node)
                            (concat "- " (ogent-ui-context--format-node-link node)))
                          ancestors))
           (body (string-join lines "\n"))
           (char-count (apply #'+ (mapcar (lambda (node)
                                            (+ (ogent-ui-context--char-count
                                                (ogent-context-node-title node))
                                               (ogent-ui-context--char-count
                                                (ogent-context-node-content node))))
                                          ancestors)))
           (heading (format "* Ancestors [%d chars]" char-count)))
      (list :heading heading :content body :chars char-count))))

(defun ogent-ui-context--format-dependencies-section (dependencies)
  "Format DEPENDENCIES as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null dependencies)
      (list :heading "* Dependencies" :content "(none)" :chars 0)
    (let* ((total-chars 0)
           (dep-strings
            (mapcar (lambda (dep)
                      (let* ((handle (plist-get dep :handle))
                             (missing-p (plist-get dep :missing-p))
                             (node (plist-get dep :node))
                             (dep-str (if missing-p
                                          (format "** @%s (missing)" handle)
                                        (let ((content (or (ogent-context-node-content node) "")))
                                          (setq total-chars (+ total-chars
                                                               (ogent-ui-context--char-count content)
                                                               (ogent-ui-context--char-count
                                                                (ogent-context-node-title node))))
                                          (format "** @%s\n%s\n\n%s"
                                                  handle
                                                  (ogent-ui-context--format-node-link node)
                                                  content)))))
                        dep-str))
                    dependencies))
           (body (string-join dep-strings "\n"))
           (heading (format "* Dependencies [%d chars]" total-chars)))
      (list :heading heading :content body :chars total-chars))))

;;;###autoload
(defun ogent-ui-context-format (context)
  "Format CONTEXT plist as interactive Org structure.
Returns an Org-formatted string with:
- Clickable file:line links to source locations
- Collapsible sections (Root, Ancestors, Dependencies)
- Character and token counts per section and total

CONTEXT is a plist with keys:
  :source-context - ogent-source-context struct (optional)
  :root           - ogent-context-node struct
  :ancestors      - list of ogent-context-node structs
  :dependencies   - list of plists with :handle, :missing-p, :node"
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         
         ;; Build sections
         (source-section (when source-ctx
                          (ogent-ui-context--format-source-section source-ctx)))
         (root-section (ogent-ui-context--format-root-section root))
         (ancestors-section (ogent-ui-context--format-ancestors-section ancestors))
         (deps-section (ogent-ui-context--format-dependencies-section dependencies))
         
         ;; Calculate totals
         (total-chars (+ (if source-section (plist-get source-section :chars) 0)
                         (plist-get root-section :chars)
                         (plist-get ancestors-section :chars)
                         (plist-get deps-section :chars)))
         (total-tokens (ogent-ui-context--estimate-tokens
                        (number-to-string total-chars)))
         
         ;; Build output parts
         (parts (list (format "#+title: Context Preview\nTotal: %d chars (~%d tokens)\n"
                              total-chars total-tokens))))
    
    ;; Add sections
    (when source-section
      (push (format "%s\n%s\n"
                    (plist-get source-section :heading)
                    (plist-get source-section :content))
            parts))
    
    (push (format "%s\n%s\n"
                  (plist-get root-section :heading)
                  (plist-get root-section :content))
          parts)
    
    (push (format "%s\n%s\n"
                  (plist-get ancestors-section :heading)
                  (plist-get ancestors-section :content))
          parts)
    
    (push (format "%s\n%s\n"
                  (plist-get deps-section :heading)
                  (plist-get deps-section :content))
          parts)
    
    ;; Return concatenated result
    (string-join (nreverse parts) "")))

(provide 'ogent-ui-context)
;;; ogent-ui-context.el ends here

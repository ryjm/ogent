;;; ox-ogent.el --- Export ogent conversations to shareable formats -*- lexical-binding: t; -*-

;;; Commentary:
;; Org export backends that turn an ogent conversation subtree (the
;; "Request: ..." / "Response (MODEL)" trees written by ogent-ui) into
;; clean, shareable output:
;;
;;   - `ogent-md'   derived from `md':   transcript-style Markdown where
;;     every request renders as "## User", every response as
;;     "## MODEL", and src blocks stay fenced (GFM style).
;;   - `ogent-html' derived from `html': same conversation cleanup,
;;     stock HTML rendering.
;;
;; Both backends share one parse-tree filter that strips the OGENT_*
;; property drawers and internal keywords ogent persists for replay and
;; bookkeeping, and relabels exchange headlines with readable role
;; titles.
;;
;; `ogent-export-conversation' is the single interactive entry point:
;; it climbs from point to the enclosing conversation headline and
;; exports that subtree to a buffer, or, with a prefix argument, to a
;; .md file beside the Org file.

;;; Code:

(require 'org)
(require 'subr-x)
(require 'ox)
(require 'ox-md)
(require 'ox-html)

(defconst ox-ogent--request-headline-regexp "\\`Request:"
  "Regexp matching the request headline text ogent writes.")

(defconst ox-ogent--response-headline-regexp "\\`Response (\\([^)]*\\))"
  "Regexp matching the response headline text ogent writes.
Group 1 captures the model id recorded on the headline.")

(defconst ox-ogent--export-buffer-name "*ogent-conversation-export*"
  "Name of the buffer receiving interactive conversation exports.")

;;; Shared parse-tree filter

(defun ox-ogent--internal-keyword-p (keyword)
  "Return non-nil when KEYWORD element is ogent-internal.
Internal keywords are any \"#+OGENT...\" keyword and \"#+PROPERTY:\"
lines that declare an OGENT_* Org property."
  (let ((key (or (org-element-property :key keyword) ""))
        (value (or (org-element-property :value keyword) "")))
    (or (string-prefix-p "OGENT" key t)
        (and (string-equal key "PROPERTY")
             (string-prefix-p "OGENT_" value t)))))

(defun ox-ogent--relabel-headline (headline)
  "Give exchange HEADLINE a readable role title.
Rename \"Request: ...\" headlines to \"User\" and
\"Response (MODEL)\" headlines to MODEL (or \"Assistant\" when the
model id is empty), recording the new title in the `:ogent-role'
element property so backend transcoders can recognize exchange
headlines after the rename."
  (let ((raw (or (org-element-property :raw-value headline) "")))
    (cond
     ((string-match-p ox-ogent--request-headline-regexp raw)
      (ox-ogent--set-headline-title headline "User"))
     ((string-match ox-ogent--response-headline-regexp raw)
      (let ((model (string-trim (match-string 1 raw))))
        (ox-ogent--set-headline-title
         headline
         (if (string-empty-p model) "Assistant" model)))))))

(defun ox-ogent--set-headline-title (headline title)
  "Set HEADLINE title to the plain string TITLE.
Also record TITLE under the `:ogent-role' element property."
  (org-element-put-property headline :ogent-role title)
  (org-element-put-property headline :raw-value title)
  (org-element-put-property headline :title (list title)))

(defun ox-ogent--filter-parse-tree (tree _backend info)
  "Strip ogent-internal bookkeeping from parse TREE before export.
Remove OGENT_* node properties (and property drawers left empty by
that), drop internal keywords, and relabel request/response
headlines with readable role titles.  INFO is the export
communication channel.  Return the modified TREE."
  (org-element-map tree 'node-property
    (lambda (property)
      (when (string-prefix-p "OGENT_"
                             (or (org-element-property :key property) "")
                             t)
        (org-element-extract-element property)))
    info)
  (org-element-map tree 'property-drawer
    (lambda (drawer)
      (unless (org-element-contents drawer)
        (org-element-extract-element drawer)))
    info)
  (org-element-map tree 'keyword
    (lambda (keyword)
      (when (ox-ogent--internal-keyword-p keyword)
        (org-element-extract-element keyword)))
    info)
  (org-element-map tree 'headline #'ox-ogent--relabel-headline info)
  tree)

;;; Markdown backend

(defun ox-ogent--md-headline (headline contents info)
  "Transcode HEADLINE for the ogent Markdown backend.
Render request/response headlines as fixed-level \"## ROLE\"
transcript sections and delegate every other headline to the stock
Markdown transcoder.  CONTENTS is the transcoded body and INFO the
export communication channel."
  (let ((role (org-element-property :ogent-role headline)))
    (if role
        (concat "## " role "\n\n" (or contents ""))
      (org-export-with-backend 'md headline contents info))))

(defun ox-ogent--md-src-block (src-block _contents info)
  "Transcode SRC-BLOCK into a fenced Markdown code block.
Vanilla `md' export indents code by four spaces; shareable
transcripts want GFM-style fences instead.  INFO is the export
communication channel."
  (let ((language (or (org-element-property :language src-block) ""))
        (code (org-export-format-code-default src-block info)))
    (concat "```" language "\n" code "```")))

(org-export-define-derived-backend 'ogent-md 'md
  :menu-entry '(?g "Export ogent conversation"
                   ((?m "As Markdown buffer" ox-ogent-export-conversation-md)
                    (?h "As HTML buffer" ox-ogent-export-conversation-html)))
  :filters-alist '((:filter-parse-tree . ox-ogent--filter-parse-tree))
  :translate-alist '((headline . ox-ogent--md-headline)
                     (src-block . ox-ogent--md-src-block)))

(defun ox-ogent--export-conversation-to-buffer (backend buffer mode)
  "Export the conversation subtree at point through BACKEND into BUFFER.
Climb to the enclosing conversation headline first, so dispatcher
invocations from inside a Request/Response child cover the whole
conversation.  Enable MODE in the result when it is available, else
`text-mode'."
  (save-excursion
    (ox-ogent--goto-conversation-root)
    (org-export-to-buffer backend buffer
      nil t nil nil nil
      (lambda () (if (fboundp mode) (funcall mode) (text-mode))))))

(defun ox-ogent-export-conversation-md (&rest _)
  "Export the conversation subtree at point as Markdown, via the dispatcher.
Ignore the dispatcher's scope arguments: the export always covers
the enclosing conversation subtree."
  (interactive)
  (ox-ogent--export-conversation-to-buffer
   'ogent-md ox-ogent--export-buffer-name 'markdown-mode))

(defun ox-ogent-export-conversation-html (&rest _)
  "Export the conversation subtree at point as HTML, via the dispatcher.
Ignore the dispatcher's scope arguments: the export always covers
the enclosing conversation subtree."
  (interactive)
  (ox-ogent--export-conversation-to-buffer
   'ogent-html ox-ogent--export-buffer-name 'html-mode))

;;; HTML backend

(org-export-define-derived-backend 'ogent-html 'html
  :filters-alist '((:filter-parse-tree . ox-ogent--filter-parse-tree)))

;;; Interactive entry point

(defun ox-ogent--exchange-headline-p ()
  "Return non-nil when the Org headline at point is an exchange headline.
Exchange headlines are the \"Request: ...\" and \"Response (MODEL)\"
headlines ogent writes inside a conversation subtree."
  (let ((heading (org-get-heading t t t t)))
    (and heading
         (or (string-match-p ox-ogent--request-headline-regexp heading)
             (string-match-p ox-ogent--response-headline-regexp heading)))))

(defun ox-ogent--goto-conversation-root ()
  "Move point to the conversation root headline for the subtree at point.
Climb out of Request/Response exchange headlines so the export
covers the whole conversation no matter where inside it point sits.
Signal a `user-error' when point is not inside an Org subtree.
Return the new position of point."
  (condition-case nil
      (org-back-to-heading t)
    (error (user-error "Not inside an Org subtree")))
  (while (and (ox-ogent--exchange-headline-p)
              (org-up-heading-safe)))
  (point))

;;;###autoload
(defun ogent-export-conversation (&optional to-file)
  "Export the agent conversation subtree at point as Markdown.
Locate the enclosing conversation headline, then narrow to that
subtree and export it through the `ogent-md' backend.  Display the
result in the `ox-ogent--export-buffer-name' buffer.  With prefix
argument TO-FILE, write it instead to a file beside the Org file,
sharing its base name with a .md extension."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (save-excursion
    (ox-ogent--goto-conversation-root)
    (if to-file
        (progn
          (unless (buffer-file-name (buffer-base-buffer))
            (user-error "Buffer visits no file; export without prefix instead"))
          (let ((file (org-export-output-file-name ".md" t)))
            (org-export-to-file 'ogent-md file nil t)
            (message "Wrote %s" file)))
      (org-export-to-buffer 'ogent-md ox-ogent--export-buffer-name
        nil t nil nil nil (lambda () (text-mode))))))

(defun ox-ogent--format-char-count (n)
  "Format the character count N for the copy confirmation message.
Counts below 1000 render verbatim; larger counts render with one
decimal and a k suffix, e.g. 2100 renders as \"2.1k\"."
  (if (< n 1000)
      (number-to-string n)
    (format "%.1fk" (/ n 1000.0))))

;;;###autoload
(defun ogent-export-conversation-to-kill-ring ()
  "Export the conversation subtree at point as Markdown to the kill ring.
Locate the enclosing conversation headline exactly like
`ogent-export-conversation', export the subtree through the
`ogent-md' backend, and push the result onto the kill ring (and,
through `interprogram-cut-function', the system clipboard) for
pasting outside Emacs.  Message the size of the copied text."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((md (save-excursion
              (ox-ogent--goto-conversation-root)
              (org-export-as 'ogent-md t))))
    (kill-new md)
    (message "Copied %s chars as Markdown"
             (ox-ogent--format-char-count (length md)))))

(provide 'ox-ogent)

;;; ox-ogent.el ends here

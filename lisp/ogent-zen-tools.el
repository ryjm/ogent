;;; ogent-zen-tools.el --- Zen tool-call store and inspection buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Out-of-band tool-call recording per Zen request plus the read-only
;; tool-call inspection buffer and its major mode.

;;; Code:

(require 'ogent-zen-core)

(declare-function ogent-zen-refresh-at "ogent-zen")

;;; Tool-call store

(cl-defstruct ogent-zen-tool-record
  "A single tool call recorded out of band for a Zen request.
Stored in `ogent-zen--tool-runs' instead of an inline `:TOOL:' drawer so
the notebook buffer stays small as runs accumulate."
  name context args result status error heading time)

(defvar-local ogent-zen--tool-runs nil
  "Out-of-band tool calls for Zen requests in this buffer.
A list of (HEADING-MARKER . RECORDS); HEADING-MARKER points at a Zen
`Request:' heading and RECORDS is a list of `ogent-zen-tool-record' in
chronological order.  Buffer-local and session-scoped: closing or
reverting the buffer clears it.  Inspect entries with
`ogent-zen-show-tool-calls'; durable history lives in the proof ledger
and `ogent-debug-tool-history'.")

(defun ogent-zen--tool-record-active-p ()
  "Return non-nil when tool use should be recorded out of band here.
True in Zen buffers unless `ogent-zen-tool-calls-inline' restores legacy
inline `:TOOL:' drawers."
  (and (bound-and-true-p ogent-zen-mode)
       (not ogent-zen-tool-calls-inline)))

(defun ogent-zen--tool-name-string (name)
  "Return tool NAME as a display string."
  (cond ((stringp name) name)
        ((symbolp name) (symbol-name name))
        (t (format "%s" name))))

(defun ogent-zen--tool-error-detail (result)
  "Return a compact error snippet from tool RESULT, or nil."
  (when (stringp result)
    (ogent-zen--detail-snippet
     (if (string-match "Tool error:[ \t]*\\(.*\\)" result)
         (match-string 1 result)
       result))))

(defun ogent-zen--tool-run-entry (heading-pos &optional create)
  "Return the (MARKER . RECORDS) store entry for the request at HEADING-POS.
With CREATE, make a fresh entry when none exists.  Drops entries whose
heading marker has died."
  (setq ogent-zen--tool-runs
        (cl-remove-if-not (lambda (entry) (marker-position (car entry)))
                          ogent-zen--tool-runs))
  (or (cl-find-if (lambda (entry)
                    (= (marker-position (car entry)) heading-pos))
                  ogent-zen--tool-runs)
      (when create
        (let ((entry (cons (copy-marker heading-pos) nil)))
          (push entry ogent-zen--tool-runs)
          entry))))

(defun ogent-zen--refresh-request-safe (heading)
  "Refresh the Zen request overlay for HEADING marker, ignoring errors."
  (when (and (bound-and-true-p ogent-zen-mode)
             (markerp heading)
             (marker-position heading))
    (ignore-errors (ogent-zen-refresh-at (marker-position heading)))))

(defun ogent-zen-record-tool-call (name args result &optional status context)
  "Record a tool call under the Zen request enclosing point.
NAME is the tool name, ARGS its arguments, RESULT its output string,
STATUS a symbol (`done', `error', `running', or `pending'), and CONTEXT
a short target label.  Append a new `ogent-zen-tool-record' to the
buffer-local store and refresh the request headline.  Return the record,
or nil when point is not inside a Zen request so callers can fall back to
an inline drawer."
  (when-let ((heading (ogent-zen--transcript-request-heading)))
    (let* ((entry (ogent-zen--tool-run-entry heading t))
           (status (or status 'done))
           (record (make-ogent-zen-tool-record
                    :name (ogent-zen--tool-name-string name)
                    :context context
                    :args args
                    :result result
                    :status status
                    :error (and (eq status 'error)
                                (ogent-zen--tool-error-detail result))
                    :heading (car entry)
                    :time (current-time))))
      (setcdr entry (nconc (cdr entry) (list record)))
      (ogent-zen--refresh-request-safe (car entry))
      record)))

(defun ogent-zen-tool-record-append (record chunk)
  "Append CHUNK to streaming tool RECORD's result."
  (when (and (ogent-zen-tool-record-p record) (stringp chunk))
    (setf (ogent-zen-tool-record-result record)
          (concat (or (ogent-zen-tool-record-result record) "") chunk))))

(defun ogent-zen-tool-record-finish (record status &optional detail)
  "Finish streaming tool RECORD with STATUS and optional error DETAIL."
  (when (ogent-zen-tool-record-p record)
    (setf (ogent-zen-tool-record-status record) status)
    (when (and (eq status 'error) detail)
      (setf (ogent-zen-tool-record-error record)
            (ogent-zen--tool-error-detail (format "%s" detail))))
    (ogent-zen--refresh-request-safe (ogent-zen-tool-record-heading record))))

(defun ogent-zen--recorded-tool-infos ()
  "Return tool info plists from the store for the request at point, or nil."
  (when ogent-zen--tool-runs
    (when-let* ((heading (ogent-zen--transcript-request-heading))
                (entry (ogent-zen--tool-run-entry heading)))
      (mapcar (lambda (rec)
                (list :name (ogent-zen-tool-record-name rec)
                      :context (or (ogent-zen-tool-record-context rec) "")
                      :status (ogent-zen-tool-record-status rec)
                      :error-detail (ogent-zen-tool-record-error rec)))
              (cdr entry)))))

(defun ogent-zen--request-tool-infos (end)
  "Return plist summaries for tool use in the current request before END.
Prefer out-of-band recorded calls (`ogent-zen--tool-runs'); fall back to
inline `:TOOL:' drawers for legacy or inline-mode transcripts."
  (or (ogent-zen--recorded-tool-infos)
      (ogent-zen--drawer-tool-infos end)))

(defun ogent-zen--drawer-tool-infos (end)
  "Return plist summaries for inline `:TOOL:' drawers before END."
  (save-excursion
    (let (infos)
      (forward-line 1)
      (while (re-search-forward "^[ \t]*:TOOL:[ \t]*$" end t)
        (let ((drawer-start (line-beginning-position))
              drawer-end name context status error-detail)
          (forward-line 1)
          (when (looking-at "^[ \t]*▶[ \t]+\\([^:\n]+\\):[ \t]*\\(.*\\)$")
            (setq name (string-trim (match-string-no-properties 1)))
            (setq context (string-trim (match-string-no-properties 2)))
            (when (string-match "[ \t]+\\([○◐✓✗]\\)\\'" context)
              (setq status
                    (ogent-zen--tool-status-from-icon
                     (match-string 1 context)))
              (setq context
                    (string-trim (substring context 0 (match-beginning 1)))))
            (save-excursion
              (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
                (setq drawer-end (point))))
            (when (and drawer-end (eq status 'error))
              (save-excursion
                (goto-char drawer-start)
                (when (re-search-forward
                       "^[ \t]*Tool error:[ \t]*\\(.*\\)$" drawer-end t)
                  (setq error-detail
                        (ogent-zen--detail-snippet
                         (match-string-no-properties 1))))))
            (push (list :name name
                        :context context
                        :status (or status 'done)
                        :error-detail error-detail)
                  infos))
          (when drawer-end
            (goto-char drawer-end))))
      (nreverse infos))))

(defun ogent-zen--request-tool-grounded-p (end)
  "Return non-nil when the current request before END used or requested tools."
  (or (member (org-entry-get (point) "OGENT_TOOLS") '("t" "true" "yes"))
      (and (ogent-zen--recorded-tool-infos) t)
      (save-excursion
        (re-search-forward "^[ \t]*:TOOL:[ \t]*$" end t))))

;;; Tool-call inspection buffer

(defconst ogent-zen--tool-record-icons
  '((done . "✓") (error . "✗") (running . "◐") (pending . "○"))
  "Status glyphs for recorded tool calls in the inspection buffer.")

(defun ogent-zen--tool-record-icon (status)
  "Return a status glyph for tool STATUS."
  (or (cdr (assq status ogent-zen--tool-record-icons)) "•"))

(defun ogent-zen--src-block-body (start end marker)
  "Return the body of a `#+begin_src ... MARKER' block within START..END.
MARKER is a header token such as \":args\" or \":result\"; return nil
when the block is absent."
  (save-excursion
    (goto-char start)
    (when (re-search-forward
           (concat "^[ \t]*#\\+begin_src[ \t].*"
                   (regexp-quote marker) "\\b.*$")
           end t)
      (forward-line 1)
      (let ((body-start (point)))
        (when (re-search-forward "^[ \t]*#\\+end_src[ \t]*$" end t)
          (string-trim-right
           (buffer-substring-no-properties
            body-start (line-beginning-position))))))))

(defun ogent-zen--parse-inline-tool-drawers (start end)
  "Parse inline `:TOOL:' drawers between START and END into record plists.
Each plist holds :name, :context, :status, :args, and :result."
  (save-excursion
    (goto-char start)
    (let (records)
      (while (re-search-forward "^[ \t]*:TOOL:[ \t]*$" end t)
        (let ((drawer-start (line-beginning-position))
              drawer-end name context status)
          (forward-line 1)
          (when (looking-at "^[ \t]*▶[ \t]+\\([^:\n]+\\):[ \t]*\\(.*\\)$")
            (setq name (string-trim (match-string-no-properties 1)))
            (setq context (string-trim (match-string-no-properties 2)))
            (when (string-match "[ \t]+\\([○◐✓✗]\\)\\'" context)
              (setq status (ogent-zen--tool-status-from-icon
                            (match-string 1 context)))
              (setq context (string-trim
                             (substring context 0 (match-beginning 1))))))
          (save-excursion
            (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
              (setq drawer-end (point))))
          (when drawer-end
            (push (list :name (or name "tool")
                        :context (or context "")
                        :status (or status 'done)
                        :args (ogent-zen--src-block-body
                               drawer-start drawer-end ":args")
                        :result (ogent-zen--src-block-body
                                 drawer-start drawer-end ":result"))
                  records)
            (goto-char drawer-end))))
      (nreverse records))))

(defun ogent-zen--request-tool-call-records (heading-pos)
  "Return full tool-call record plists for the request at HEADING-POS.
Prefer the out-of-band store; fall back to inline `:TOOL:' drawers."
  (or (when-let ((entry (and ogent-zen--tool-runs
                             (ogent-zen--tool-run-entry heading-pos))))
        (mapcar (lambda (rec)
                  (list :name (ogent-zen-tool-record-name rec)
                        :context (or (ogent-zen-tool-record-context rec) "")
                        :status (ogent-zen-tool-record-status rec)
                        :args (ogent-zen-tool-record-args rec)
                        :result (ogent-zen-tool-record-result rec)))
                (cdr entry)))
      (save-excursion
        (goto-char heading-pos)
        (ogent-zen--parse-inline-tool-drawers
         heading-pos (ogent-zen--subtree-end)))))

(defun ogent-zen--subtree-tool-call-groups ()
  "Return tool-call groups for Zen requests in the subtree at point.
Each group is a plist (:title TITLE :records RECORDS) in document order;
requests without recorded tool calls are skipped."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (ogent-zen--subtree-end))
          groups)
      (save-excursion
        (while (re-search-forward "^\\*+[ \t]+Request:" end t)
          (save-excursion
            (beginning-of-line)
            (when (ogent-zen--request-heading-p)
              (let ((records (ogent-zen--request-tool-call-records (point))))
                (when records
                  (push (list :title (org-get-heading t t t t)
                              :records records)
                        groups)))))))
      (nreverse groups))))

(defun ogent-zen--insert-tool-call-record (record)
  "Insert one tool-call RECORD plist into the inspection buffer."
  (let* ((name (or (plist-get record :name) "tool"))
         (context (or (plist-get record :context) ""))
         (icon (ogent-zen--tool-record-icon (plist-get record :status)))
         (args (plist-get record :args))
         (result (plist-get record :result)))
    (insert (format "** %s%s %s\n"
                    name
                    (if (string-empty-p context) "" (concat ": " context))
                    icon))
    (insert "#+begin_src elisp :args\n"
            (cond ((null args) "nil")
                  ((stringp args) (string-trim-right args))
                  (t (string-trim-right (pp-to-string args))))
            "\n#+end_src\n")
    (insert "#+begin_src text :result\n")
    (insert (cond ((null result) "")
                  ((stringp result) result)
                  (t (pp-to-string result))))
    (unless (bolp) (insert "\n"))
    (insert "#+end_src\n")))

(defun ogent-zen--insert-tool-call-group (group)
  "Insert a request GROUP plist into the inspection buffer."
  (let ((records (plist-get group :records)))
    (insert (format "* %s  [%d %s]\n"
                    (plist-get group :title)
                    (length records)
                    (if (= (length records) 1) "tool" "tools")))
    (mapc #'ogent-zen--insert-tool-call-record records)))

(defvar ogent-zen-tool-calls-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-zen-tool-calls-mode'.")

(define-derived-mode ogent-zen-tool-calls-mode org-mode "Ogent-Tools"
  "Major mode for the Zen tool-call inspection buffer.
The buffer is read-only; tool arguments and results fold like normal Org
content with TAB."
  (setq buffer-read-only t)
  (when (fboundp 'org-content) (ignore-errors (org-content))))

(defun ogent-zen-show-tool-calls ()
  "List the tool use recorded under the Org heading at point.
Zen records tool calls out of band to keep the notebook responsive; this
opens a separate read-only buffer listing every tool call (name,
arguments, result, status) for the requests in the current subtree.
Falls back to inline `:TOOL:' drawers for legacy transcripts."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen tool inspection requires an Org buffer"))
  (unless (or (org-at-heading-p)
              (ignore-errors (org-back-to-heading t) t))
    (user-error "Point is not under an Org heading"))
  (let* ((title (or (ignore-errors (org-get-heading t t t t)) "buffer"))
         (groups (ogent-zen--subtree-tool-call-groups))
         (total (apply #'+ (mapcar (lambda (g) (length (plist-get g :records)))
                                   groups)))
         (buffer (get-buffer-create "*ogent tool calls*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Tool calls: %s\n\n" title))
        (if (zerop total)
            (insert "No tool calls recorded under this heading.\n")
          (mapc #'ogent-zen--insert-tool-call-group groups)))
      (goto-char (point-min))
      (ogent-zen-tool-calls-mode))
    (if (zerop total)
        (message "No tool calls recorded under this heading")
      (message "%d tool %s under %s"
               total (if (= total 1) "call" "calls") title))
    (display-buffer buffer)
    buffer))

(provide 'ogent-zen-tools)
;;; ogent-zen-tools.el ends here

;;; ogent-workbench.el --- Feedback anchored to editable work -*- lexical-binding: t; -*-

;;; Commentary:
;; Store review comments in Org, request one revision of the marked passages,
;; and review replacements through the existing edit proposal interface.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-id)
(require 'ogent-edit-diff)
(require 'ogent-ui)

(declare-function ogent-task-comment "ogent-task")
(declare-function ogent-workbench-comments "ogent-ui-workbench")
(declare-function evil-visual-state-p "ext:evil-states")
(declare-function evil-visual-range "ext:evil-states")

(defgroup ogent-workbench nil
  "Feedback and revisions attached to work."
  :group 'ogent)

(defcustom ogent-workbench-file
  (expand-file-name "ogent/review.org" org-directory)
  "Org file holding passage comments and protected text."
  :type 'file
  :group 'ogent-workbench)

(defvar-local ogent-workbench--records nil
  "Loaded comments for the current source buffer.")

(defvar ogent-workbench--runs (make-hash-table :test #'equal)
  "Revision requests awaiting the shared request completion hook.")

(defvar ogent-workbench--edits (make-hash-table :test #'equal)
  "Proposal IDs mapped to their originating comments.")

(defun ogent-workbench--key (buffer)
  "Return the stable source key for BUFFER."
  (or (buffer-file-name buffer) (concat "buffer:" (buffer-name buffer))))

(defun ogent-workbench--store ()
  "Return the review Org buffer, creating its directory when necessary."
  (make-directory (file-name-directory ogent-workbench-file) t)
  (let ((buffer (find-file-noselect ogent-workbench-file)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (when (= (buffer-size) 0) (insert "#+title: Work review\n\n")))
    buffer))

(defun ogent-workbench--src (text)
  "Return TEXT safely enclosed in an Org source block."
  (concat "#+begin_src text\n"
          (org-escape-code-in-string text)
          (unless (string-suffix-p "\n" text) "\n")
          "#+end_src\n"))

(defun ogent-workbench--write (record)
  "Persist RECORD as a readable Org heading."
  (with-current-buffer (ogent-workbench--store)
    (save-excursion
      (goto-char (point-min))
      (let ((found (org-find-property "OGENT_COMMENT_ID"
                                      (plist-get record :id))))
        (if found
            (progn (goto-char found)
                   (delete-region (point) (save-excursion
                                            (org-end-of-subtree t t) (point))))
          (goto-char (point-max))))
      (insert "* " (upcase (plist-get record :status)) " "
              (if (eq (plist-get record :kind) 'keep) "Keep passage" "Comment")
              "\n")
      (forward-line -1)
      (dolist (pair `(("OGENT_COMMENT_ID" . ,(plist-get record :id))
                      ("OGENT_SOURCE" . ,(plist-get record :source))
                      ("OGENT_KIND" . ,(symbol-name (plist-get record :kind)))
                      ("OGENT_STATUS" . ,(plist-get record :status))
                      ("OGENT_BEGIN" . ,(number-to-string (plist-get record :begin)))
                      ("OGENT_END" . ,(number-to-string (plist-get record :end)))
                      ("OGENT_TEXT_LENGTH" . ,(number-to-string
                                               (length (plist-get record :text))))))
        (org-entry-put (point) (car pair) (cdr pair)))
      (org-end-of-meta-data t)
      (insert (ogent-workbench--src (plist-get record :text))
              (ogent-workbench--src (plist-get record :note))
              (if (plist-get record :draft)
                  (ogent-workbench--src (plist-get record :draft)) "") "\n"))
    (save-buffer)))

(defun ogent-workbench--load ()
  "Load durable comments for the current source buffer."
  (unless ogent-workbench--records
    (let ((source (ogent-workbench--key (current-buffer))) records)
      (when (file-exists-p ogent-workbench-file)
        (with-current-buffer (ogent-workbench--store)
          (org-map-entries
           (lambda ()
             (when (equal source (org-entry-get (point) "OGENT_SOURCE"))
               (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
                      (tree (save-restriction
                              (narrow-to-region (point) end)
                              (org-element-parse-buffer)))
                      (blocks (org-element-map tree 'src-block
				(lambda (element)
				  (org-unescape-code-in-string
				   (org-element-property :value element))))))
                 (push (list :id (org-entry-get (point) "OGENT_COMMENT_ID")
                             :source source
                             :kind (intern (org-entry-get (point) "OGENT_KIND"))
                             :status (let ((status (org-entry-get (point) "OGENT_STATUS")))
                                       (if (equal status "proposed") "open" status))
                             :begin (string-to-number
                                     (org-entry-get (point) "OGENT_BEGIN"))
                             :end (string-to-number
                                   (org-entry-get (point) "OGENT_END"))
                             :text (substring (car blocks) 0
                                              (string-to-number
                                               (org-entry-get
                                                (point) "OGENT_TEXT_LENGTH")))
                             :note (string-trim-right (cadr blocks))
                             :draft (when (caddr blocks) (string-trim-right (caddr blocks))))
                       records))))
           nil 'file)))
      (setq-local ogent-workbench--records (nreverse records)))))

(defun ogent-workbench--anchor (record)
  "Return the exact source bounds of RECORD, rejecting changed text."
  (let* ((marker (plist-get record :marker))
         (beg (if (and (markerp marker) (marker-buffer marker))
                  (marker-position marker) (plist-get record :begin)))
         (text (plist-get record :text))
         (end (+ beg (length text))))
    (unless (and (<= (point-min) beg end (point-max))
                 (equal text (buffer-substring-no-properties beg end)))
      (when (string-empty-p text)
        (user-error "Insertion comment is stale; mark the insertion again"))
      (let (matches)
        (save-excursion
          (goto-char (point-min))
          (while (search-forward text nil t) (push (match-beginning 0) matches)))
        (unless (= (length matches) 1)
          (user-error "Comment %s is stale or ambiguous; mark the passage again"
                      (plist-get record :id)))
        (setq beg (car matches) end (+ beg (length text)))))
    (plist-put record :begin beg)
    (plist-put record :end end)
    (plist-put record :marker (copy-marker beg))
    (cons beg end)))

(defun ogent-workbench--decorate (record)
  "Show a local, theme-aware marker for RECORD."
  (when-let ((old (plist-get record :overlay))) (delete-overlay old))
  (when (member (plist-get record :status) '("open" "kept" "proposed"))
    (condition-case nil
        (let* ((bounds (ogent-workbench--anchor record))
               (overlay (make-overlay (car bounds) (cdr bounds))))
          (overlay-put overlay 'face 'highlight)
          (overlay-put overlay 'after-string
                       (propertize (if (eq (plist-get record :kind) 'keep)
                                       " [keep]" " [comment]")
                                   'face 'shadow))
          (overlay-put overlay 'help-echo (plist-get record :note))
          (plist-put record :overlay overlay))
      (user-error nil))))

(defun ogent-workbench--add (begin end note kind &optional insertion)
  "Attach NOTE of KIND to BEGIN through END in the current buffer.
Allow an empty target only for an edit proposal's INSERTION."
  (unless (<= (point-min) begin end (point-max))
    (user-error "Passage bounds are outside the buffer"))
  (when (and (= begin end) (not insertion)) (user-error "Select a nonempty passage"))
  (ogent-workbench--load)
  (dolist (old ogent-workbench--records)
    (when (member (plist-get old :status) '("open" "kept" "proposed"))
      (let ((bounds (ogent-workbench--anchor old)))
        (when (and (< begin (cdr bounds)) (< (car bounds) end))
          (user-error "Passage overlaps an existing comment or kept passage")))))
  (let ((record (list :id (org-id-new) :source (ogent-workbench--key (current-buffer))
                      :kind kind :status (if (eq kind 'keep) "kept" "open")
                      :begin begin :end end :marker (copy-marker begin)
                      :text (buffer-substring-no-properties begin end) :note note)))
    (ogent-workbench--write record)
    (push record ogent-workbench--records)
    (ogent-workbench--decorate record)
    (deactivate-mark)
    record))

(defun ogent-workbench--selection (begin end)
  "Return passage bounds from BEGIN and END or the active selection."
  (cond
   ((and begin end) (cons begin end))
   ((and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
    (let ((range (evil-visual-range))) (cons (car range) (cadr range))))
   ((use-region-p) (cons (region-beginning) (region-end)))
   (t (user-error "Select a passage"))))

;;;###autoload
(defun ogent-workbench-comment (&optional note begin end)
  "Attach NOTE to the selected passage between BEGIN and END.
In a delegated task patch, attach the comment to the current diff hunk."
  (interactive)
  (cond
   ((bound-and-true-p ogent-task-patch--file) (ogent-task-comment note))
   ((derived-mode-p 'ogent-edit-diff-mode)
    (let ((edit (ogent-edit-diff--current-edit))
          (comment (or note (read-string "Hunk comment: "))))
      (unless edit (user-error "Move to an edit hunk"))
      (unless (eq (ogent-edit-status edit) 'pending)
        (user-error "Comment on a pending proposal"))
      (when (string-empty-p (string-trim comment)) (user-error "Comment is empty"))
      (with-current-buffer (ogent-edit-source-buffer edit)
        (ogent-edit--re-anchor edit)
        (let* ((existing (gethash (ogent-edit-id edit) ogent-workbench--edits))
               (record (or existing
                           (ogent-workbench--add (ogent-edit-start-pos edit)
                                                 (ogent-edit-end-pos edit) comment 'comment
                                                 (string-empty-p (ogent-edit-old-text edit))))))
          (when existing
            (plist-put record :note (concat (plist-get record :note) "\nFollow-up: " comment)))
          (plist-put record :status "open")
          (plist-put record :draft (ogent-edit-new-text edit))
          (plist-put record :proposal edit)
          (ogent-workbench--write record)
          (ogent-workbench--decorate record)))))
   (t
    (let ((bounds (ogent-workbench--selection begin end))
          (comment (or note (read-string "Comment: "))))
      (when (string-empty-p (string-trim comment)) (user-error "Comment is empty"))
      (ogent-workbench--add (car bounds) (cdr bounds) comment 'comment)
      (message "ogent: comment saved; mark more passages, then revise")))))

;;;###autoload
(defun ogent-workbench-keep (&optional begin end)
  "Protect the selected passage between BEGIN and END from revision."
  (interactive)
  (let ((bounds (ogent-workbench--selection begin end)))
    (ogent-workbench--add (car bounds) (cdr bounds)
                          "Keep this passage unchanged." 'keep)))

(defun ogent-workbench--proposals (response run)
  "Validate RESPONSE against RUN and return bounded edit proposals."
  (let* ((text (string-trim response))
         (text (if (string-prefix-p "```" text)
                   (replace-regexp-in-string
                    "\\````[^\n]*\n\\|\n```\\'" "" text) text))
         (entries (json-parse-string text :object-type 'plist :array-type 'list))
         (records (plist-get run :records)) edits seen)
    (unless (= (length entries) (length records))
      (user-error "Revision must return one replacement per comment"))
    (with-current-buffer (plist-get run :buffer)
      (save-restriction
        (widen)
        (dolist (entry entries)
          (let* ((id (plist-get entry :id))
                 (record (cl-find id records :key (lambda (r) (plist-get r :id))
                                  :test #'equal))
                 (replacement (plist-get entry :text)))
            (unless (and record (stringp replacement) (not (member id seen)))
              (user-error "Revision has an unknown, repeated, or malformed comment"))
            (unless (and (equal (plist-get record :status) "open")
                         (or (not (plist-get run :snapshot))
                             (equal (cdr (assoc id (plist-get run :snapshot)))
                                    (list (plist-get record :text) (plist-get record :note)
                                          (plist-get record :draft)))))
              (user-error "Feedback changed during revision; review it and revise again"))
            (push id seen)
            (let* ((bounds (ogent-workbench--anchor record))
                   (edit (make-ogent-edit
                          :id (concat (plist-get run :id) ":" id)
                          :old-text (plist-get record :text) :new-text replacement
                          :source-buffer (current-buffer) :source-file buffer-file-name
                          :source-marker (copy-marker (car bounds))
                          :start-pos (car bounds) :end-pos (cdr bounds)
                          :status 'pending :timestamp (current-time))))
              (push edit edits))))))
    (nreverse edits)))

(defun ogent-workbench--finished (context)
  "Prepare proposals when the revision identified by CONTEXT finishes."
  (when-let* ((id (plist-get context :workbench-run))
              (run (gethash id ogent-workbench--runs))
              (request (cl-find-if
                        (lambda (r) (equal id (plist-get (ogent-ui-request-context r)
                                                         :workbench-run)))
                        ogent-ui--request-history)))
    (remhash id ogent-workbench--runs)
    (if (not (eq (ogent-ui-request-status request) 'done))
        (message "ogent: revision stopped; comments remain open")
      (condition-case err
          (let ((edits (ogent-workbench--proposals
                        (ogent-ui--response-body-text request) run)))
            (cl-mapc
             (lambda (edit record)
               (puthash (ogent-edit-id edit) record ogent-workbench--edits)
               (when-let ((old (plist-get record :proposal)))
                 (setf (ogent-edit-status old) 'superseded)
                 (remhash (ogent-edit-id old) ogent-workbench--edits)
                 (with-current-buffer (ogent-edit-source-buffer old)
                   (setq ogent-edit--pending-edits (delq old ogent-edit--pending-edits))))
               (plist-put record :proposal edit)
               (plist-put record :draft (ogent-edit-new-text edit))
               (plist-put record :status "proposed")
               (ogent-workbench--write record))
             edits (mapcar (lambda (edit)
                             (cl-find (substring (ogent-edit-id edit) (1+ (length id)))
                                      (plist-get run :records)
                                      :key (lambda (r) (plist-get r :id)) :test #'equal))
                           edits))
            (ogent-edit-diff-show edits)
            (message "ogent: %d revisions ready; accept or reject in the diff" (length edits)))
        (error (message "ogent: cannot prepare revision: %s; comments preserved"
                        (error-message-string err)))))))

(defun ogent-workbench--resolved (edit)
  "Protect an accepted EDIT or reopen its rejected comment."
  (when-let ((record (gethash (ogent-edit-id edit) ogent-workbench--edits)))
    (remhash (ogent-edit-id edit) ogent-workbench--edits)
    (with-current-buffer (ogent-edit-source-buffer edit)
      (if (memq (ogent-edit-status edit) '(accepted applied resolved))
          (progn
            (plist-put record :kind 'keep)
            (plist-put record :status "kept")
            (plist-put record :begin (ogent-edit-start-pos edit))
            (plist-put record :end (+ (ogent-edit-start-pos edit)
                                      (length (ogent-edit-new-text edit))))
            (plist-put record :text (ogent-edit-new-text edit))
            (plist-put record :marker (copy-marker (ogent-edit-start-pos edit))))
        (plist-put record :status "open"))
      (ogent-workbench--write record)
      (ogent-workbench--decorate record))))

(defun ogent-workbench--revise-buffer (instruction)
  "Request one revision for all open passage comments.
INSTRUCTION adds a shared direction for the complete revision."
  (interactive)
  (ogent-workbench--load)
  (let* ((source (current-buffer))
         (records (cl-remove-if-not
                   (lambda (r) (equal (plist-get r :status) "open"))
                   ogent-workbench--records))
         (id (org-id-new)) bounds)
    (unless records (user-error "Mark passages with comments before revising"))
    (when (cl-loop for run being the hash-values of ogent-workbench--runs
                   thereis (eq (plist-get run :buffer) source))
      (user-error "A revision is already running for this buffer"))
    (dolist (record records) (push (ogent-workbench--anchor record) bounds))
    (let* ((begin (apply #'min (mapcar #'car bounds)))
           (end (apply #'max (mapcar #'cdr bounds)))
           (prompt
            (concat "Revise the marked passages together. Preserve consistency across them.\n"
                    "Return only a JSON array with one object per comment: "
                    "{\"id\":\"comment id\",\"text\":\"complete replacement passage\"}.\n"
                    "Keep exact IDs. Change only these passages. Other text stays unchanged.\n"
                    (when instruction (concat "Shared direction: " instruction "\n"))
                    "Comments:\n"
                    (json-serialize
                     (vconcat (mapcar (lambda (r)
                                        (list :id (plist-get r :id)
                                              :text (plist-get r :text)
                                              :draft (or (plist-get r :draft) (plist-get r :text))
                                              :comment (plist-get r :note))) records))))))
      (puthash id (list :id id :buffer source :records records
			:snapshot (mapcar (lambda (r)
                                            (cons (plist-get r :id)
                                                  (list (plist-get r :text) (plist-get r :note)
							(plist-get r :draft)))) records))
               ogent-workbench--runs)
      (condition-case err
          (let ((request
                 (ogent-ui--dispatch-request
                  source begin end prompt nil nil nil nil
                  (lambda (context) (plist-put (copy-sequence context) :workbench-run id)))))
            (unless request (remhash id ogent-workbench--runs))
            request)
        (error (remhash id ogent-workbench--runs) (signal (car err) (cdr err)))))))

;;;###autoload
(defun ogent-workbench-revise (&optional instruction)
  "Revise all open comments on the current document or proposal's source.
INSTRUCTION adds a shared direction to the batch."
  (interactive)
  (if (derived-mode-p 'ogent-edit-diff-mode)
      (let ((edit (ogent-edit-diff--current-edit)))
        (unless edit (user-error "Move to an edit hunk"))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (ogent-workbench--revise-buffer instruction)))
    (ogent-workbench--revise-buffer instruction)))

(add-hook 'ogent-after-request-hook #'ogent-workbench--finished)
(add-hook 'ogent-edit-resolved-hook #'ogent-workbench--resolved)

(provide 'ogent-workbench)
;;; ogent-workbench.el ends here

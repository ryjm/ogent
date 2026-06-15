;;; ogent-completions.el --- Completion review workflow for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides an ergonomic workflow for reviewing, cycling, and accepting/rejecting
;; LLM completions. Supports fan-out scenarios where multiple models produce
;; responses, or retry scenarios with multiple attempts at the same prompt.
;;
;; Key bindings:
;;   C-c . N - Cycle to next completion
;;   C-c . P - Cycle to previous completion
;;   C-c . A - Accept current completion (delete others)
;;   C-c . X - Reject current completion (delete it, move to next)
;;
;; Completions are tracked per Question subtree using overlays for visual
;; feedback (highlighting current, dimming others).

;;; Code:

(require 'cl-lib)
(require 'org)

;; Forward declarations
(declare-function ogent-ui-request-marker "ui/ogent-ui" t t)
(declare-function ogent-zen--transcript-request-heading "ogent-zen")
(declare-function ogent-zen--current-response-heading "ogent-zen")
(declare-function ogent-zen-accept-response "ogent-zen")
(declare-function ogent-zen-mark-accepted "ogent-zen")
(defvar ogent-session-buffer-p)

;;; Customization

(defgroup ogent-completions nil
  "Completion review workflow for ogent."
  :group 'ogent)

(defcustom ogent-completions-dim-face 'shadow
  "Face used to dim non-current completions."
  :type 'face
  :group 'ogent-completions)

(defcustom ogent-completions-fold-others t
  "When non-nil, fold non-current completions when cycling."
  :type 'boolean
  :group 'ogent-completions)

;;; Completion Registry

(defvar-local ogent-completions--registry (make-hash-table :test 'equal)
  "Hash table mapping question marker to list of completion structs.")

(defvar-local ogent-completions--current-index (make-hash-table :test 'equal)
  "Hash table mapping question marker to current completion index.")

(cl-defstruct ogent-completion
  "Structure representing a single completion."
  id              ; Unique ID (based on RESPONSE-INDEX property)
  model           ; Model that produced this completion
  marker          ; Marker to the Response headline
  end-marker      ; Marker to the end of the Response subtree
  status          ; 'pending | 'current | 'accepted | 'rejected
  overlay)        ; Overlay for visual feedback

;;; Question/Response Discovery

(defun ogent-completions--in-response-p ()
  "Return non-nil if point is at or under a Response headline."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (condition-case nil
          (progn
            (org-back-to-heading t)
            (let ((heading-text (org-get-heading t t t t)))
              (and heading-text
                   (string-match-p "\\`[Rr]esponse" heading-text))))
        (error nil)))))

(defun ogent-completions--find-question-marker ()
  "Find the marker for the Question headline associated with current position.
Returns nil if not in a Question/Response context."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (condition-case nil
          (progn
            (org-back-to-heading t)
            (let ((heading-text (org-get-heading t t t t)))
              (cond
               ;; Already at Question headline
               ((and heading-text (string-match-p "\\`[Qq]uestion\\'" heading-text))
                (point-marker))
               ;; At Response headline - find sibling Question
               ((and heading-text (string-match-p "\\`[Rr]esponse" heading-text))
                ;; Go backward to find Question at same level
                (while (and (org-get-previous-sibling)
                            (not (string-match-p "\\`[Qq]uestion\\'"
                                                 (org-get-heading t t t t)))))
                (when (string-match-p "\\`[Qq]uestion\\'"
                                      (org-get-heading t t t t))
                  (point-marker)))
               (t nil))))
        (error nil)))))

(defun ogent-completions--find-responses (question-marker)
  "Find all Response headlines that are siblings of QUESTION-MARKER.
Returns a list of markers to Response headlines."
  (when (and question-marker (marker-buffer question-marker))
    (with-current-buffer (marker-buffer question-marker)
      (save-excursion
        (goto-char question-marker)
        (let ((level (org-current-level))
              (responses nil)
              (limit (save-excursion
                       (if (org-up-heading-safe)
                           (progn (org-end-of-subtree t t) (point))
                         (point-max)))))
          ;; Move past the Question headline
          (org-end-of-subtree t t)
          ;; Scan forward for Response siblings
          (while (< (point) limit)
            (when (and (org-at-heading-p)
                       (= (org-current-level) level))
              (let ((heading-text (org-get-heading t t t t)))
                (when (and heading-text
                           (string-match-p "\\`[Rr]esponse" heading-text))
                  (push (point-marker) responses))))
            (forward-line 1))
          (nreverse responses))))))

(defun ogent-completions--response-end-marker (response-marker)
  "Get a marker to the end of the Response subtree at RESPONSE-MARKER."
  (when (and response-marker (marker-buffer response-marker))
    (with-current-buffer (marker-buffer response-marker)
      (save-excursion
        (goto-char response-marker)
        (org-end-of-subtree t t)
        (copy-marker (point) t)))))

(defun ogent-completions--get-response-model (response-marker)
  "Extract model info from the Response at RESPONSE-MARKER.
Returns a string describing the model, or \"unknown\"."
  (when (and response-marker (marker-buffer response-marker))
    (with-current-buffer (marker-buffer response-marker)
      (save-excursion
        (goto-char response-marker)
        ;; Look for :model property or model info in sibling Request headline
        (let ((model (org-entry-get nil "MODEL")))
          (or model
              ;; Try to find model from the associated Request src block
              (save-excursion
                (when (org-get-previous-sibling)
                  (when (re-search-forward ":model \\([^ \n]+\\)"
                                           (save-excursion (org-end-of-subtree t) (point))
                                           t)
                    (match-string 1))))
              "unknown"))))))

(defun ogent-completions--get-response-index (response-marker)
  "Get the RESPONSE-INDEX property from the Response at RESPONSE-MARKER."
  (when (and response-marker (marker-buffer response-marker))
    (with-current-buffer (marker-buffer response-marker)
      (save-excursion
        (goto-char response-marker)
        (let ((idx (org-entry-get nil "RESPONSE-INDEX")))
          (if idx (string-to-number idx) 1))))))

;;; Registry Management

(defun ogent-completions--build-registry (question-marker)
  "Build completion registry for QUESTION-MARKER."
  (let ((responses (ogent-completions--find-responses question-marker))
        (completions nil))
    (dolist (response-marker responses)
      (push (make-ogent-completion
             :id (ogent-completions--get-response-index response-marker)
             :model (ogent-completions--get-response-model response-marker)
             :marker response-marker
             :end-marker (ogent-completions--response-end-marker response-marker)
             :status 'pending
             :overlay nil)
            completions))
    (nreverse completions)))

(defun ogent-completions--ensure-registry (question-marker)
  "Ensure completions are registered for QUESTION-MARKER.
Builds the registry if not already present or if stale."
  (let ((key (marker-position question-marker)))
    (unless (gethash key ogent-completions--registry)
      (let ((completions (ogent-completions--build-registry question-marker)))
        (puthash key completions ogent-completions--registry)
        ;; Set initial current index to 0 (first completion)
        (when completions
          (puthash key 0 ogent-completions--current-index))))
    (gethash key ogent-completions--registry)))

(defun ogent-completions--for-subtree ()
  "Get all completions for the current Question subtree.
Returns nil if not in a valid Question/Response context."
  (let ((question-marker (ogent-completions--find-question-marker)))
    (when question-marker
      (ogent-completions--ensure-registry question-marker))))

(defun ogent-completions--current ()
  "Get the currently selected completion for this subtree."
  (let* ((question-marker (ogent-completions--find-question-marker))
         (key (and question-marker (marker-position question-marker)))
         (completions (and key (gethash key ogent-completions--registry)))
         (index (and key (gethash key ogent-completions--current-index 0))))
    (when (and completions (< index (length completions)))
      (nth index completions))))

(defun ogent-completions--set-current-index (question-marker index)
  "Set the current completion INDEX for QUESTION-MARKER."
  (let ((key (marker-position question-marker)))
    (puthash key index ogent-completions--current-index)))

;;; Visual Feedback

(defun ogent-completions--make-overlay (completion)
  "Create or update overlay for COMPLETION."
  (let ((start (ogent-completion-marker completion))
        (end (ogent-completion-end-marker completion)))
    (when (and start end
               (marker-buffer start)
               (marker-buffer end)
               (eq (marker-buffer start) (marker-buffer end)))
      (with-current-buffer (marker-buffer start)
        ;; Remove existing overlay if any
        (when (ogent-completion-overlay completion)
          (delete-overlay (ogent-completion-overlay completion)))
        ;; Create new overlay
        (let ((ov (make-overlay start end)))
          (setf (ogent-completion-overlay completion) ov)
          ov)))))

(defun ogent-completions--highlight (completion)
  "Highlight COMPLETION as the current one.
Removes dimming, expands the subtree."
  (let ((ov (ogent-completions--make-overlay completion)))
    (when ov
      ;; Clear any dimming
      (overlay-put ov 'face nil)
      (overlay-put ov 'ogent-dim nil)
      ;; Expand the subtree
      (when ogent-completions-fold-others
        (save-excursion
          (goto-char (ogent-completion-marker completion))
          (org-fold-show-subtree))))))

(defun ogent-completions--dim (completion)
  "Dim COMPLETION to indicate it's not current."
  (let ((ov (ogent-completions--make-overlay completion)))
    (when ov
      (overlay-put ov 'face ogent-completions-dim-face)
      (overlay-put ov 'ogent-dim t)
      ;; Optionally fold the subtree
      (when ogent-completions-fold-others
        (save-excursion
          (goto-char (ogent-completion-marker completion))
          (org-fold-hide-subtree))))))

(defun ogent-completions--update-visual-state (completions current-index)
  "Update visual state for all COMPLETIONS, highlighting CURRENT-INDEX."
  (cl-loop for completion in completions
           for i from 0
           do (if (= i current-index)
                  (ogent-completions--highlight completion)
                (ogent-completions--dim completion))))

(defun ogent-completions--clear-overlays (completions)
  "Remove all overlays from COMPLETIONS."
  (dolist (completion completions)
    (when (ogent-completion-overlay completion)
      (delete-overlay (ogent-completion-overlay completion))
      (setf (ogent-completion-overlay completion) nil))))

;;; Cycling Commands

;;;###autoload
(defun ogent-completion-next ()
  "Cycle to the next completion for the current Question subtree."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-completion-next only works in Org buffers"))
  (let* ((question-marker (ogent-completions--find-question-marker))
         (completions (ogent-completions--for-subtree)))
    (unless question-marker
      (user-error "Not in a Question/Response context"))
    (unless completions
      (user-error "No completions found for this question"))
    (if (= (length completions) 1)
        (message "Only one completion available")
      (let* ((key (marker-position question-marker))
             (current-index (gethash key ogent-completions--current-index 0))
             (next-index (mod (1+ current-index) (length completions)))
             (next-completion (nth next-index completions)))
        ;; Update index
        (ogent-completions--set-current-index question-marker next-index)
        ;; Update visual state
        (ogent-completions--update-visual-state completions next-index)
        ;; Move point to the new current completion
        (goto-char (ogent-completion-marker next-completion))
        (message "Completion %d of %d (%s)"
                 (1+ next-index)
                 (length completions)
                 (ogent-completion-model next-completion))))))

;;;###autoload
(defun ogent-completion-prev ()
  "Cycle to the previous completion for the current Question subtree."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-completion-prev only works in Org buffers"))
  (let* ((question-marker (ogent-completions--find-question-marker))
         (completions (ogent-completions--for-subtree)))
    (unless question-marker
      (user-error "Not in a Question/Response context"))
    (unless completions
      (user-error "No completions found for this question"))
    (if (= (length completions) 1)
        (message "Only one completion available")
      (let* ((key (marker-position question-marker))
             (current-index (gethash key ogent-completions--current-index 0))
             (prev-index (mod (1- current-index) (length completions)))
             (prev-completion (nth prev-index completions)))
        ;; Update index
        (ogent-completions--set-current-index question-marker prev-index)
        ;; Update visual state
        (ogent-completions--update-visual-state completions prev-index)
        ;; Move point to the new current completion
        (goto-char (ogent-completion-marker prev-completion))
        (message "Completion %d of %d (%s)"
                 (1+ prev-index)
                 (length completions)
                 (ogent-completion-model prev-completion))))))

;;; Accept/Reject Commands

(defun ogent-completions--delete-completion (completion)
  "Delete the Response subtree for COMPLETION."
  (let ((start (ogent-completion-marker completion))
        (end (ogent-completion-end-marker completion)))
    (when (and start end
               (marker-buffer start)
               (marker-buffer end))
      (with-current-buffer (marker-buffer start)
        ;; Clear overlay first
        (when (ogent-completion-overlay completion)
          (delete-overlay (ogent-completion-overlay completion)))
        ;; Delete the subtree
        (delete-region start end)
        ;; Clean up markers
        (set-marker start nil)
        (set-marker end nil)))))

(defun ogent-completions--invalidate-registry (question-marker)
  "Invalidate the registry for QUESTION-MARKER.
Forces rebuild on next access."
  (let ((key (marker-position question-marker)))
    (remhash key ogent-completions--registry)
    (remhash key ogent-completions--current-index)))

;;;###autoload
(defun ogent-completion-accept ()
  "Accept the current completion, deleting all others.
The accepted completion remains, and all other Response siblings
for this Question are deleted."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-completion-accept only works in Org buffers"))
  (let* ((question-marker (ogent-completions--find-question-marker))
         (completions (ogent-completions--for-subtree)))
    (unless question-marker
      (user-error "Not in a Question/Response context"))
    (unless completions
      (user-error "No completions to accept"))
    (let* ((key (marker-position question-marker))
           (current-index (gethash key ogent-completions--current-index 0))
           (current-completion (nth current-index completions))
           (model (ogent-completion-model current-completion)))
      ;; Confirm if there are multiple completions
      (when (and (> (length completions) 1)
                 (not (y-or-n-p (format "Accept completion from %s and delete %d others? "
                                        model (1- (length completions))))))
        (user-error "Cancelled"))
      ;; Clear overlay on accepted completion
      (ogent-completions--highlight current-completion)
      (when (ogent-completion-overlay current-completion)
        (delete-overlay (ogent-completion-overlay current-completion))
        (setf (ogent-completion-overlay current-completion) nil))
      ;; Delete all other completions (in reverse order to preserve positions)
      (let ((to-delete (cl-remove current-completion completions)))
        (dolist (completion (reverse to-delete))
          (ogent-completions--delete-completion completion)))
      ;; Invalidate registry
      (ogent-completions--invalidate-registry question-marker)
      ;; Update status
      (setf (ogent-completion-status current-completion) 'accepted)
      (message "Accepted completion from %s" model))))

(defun ogent-completions--remove-transient-metadata (completion)
  "Remove transient metadata properties from COMPLETION.
Removes RESPONSE-INDEX and CREATED properties from the Response headline's
drawer, leaving other properties intact. If no other properties remain,
the entire PROPERTIES drawer is removed."
  (let ((marker (ogent-completion-marker completion)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (when (org-at-heading-p)
            ;; Remove transient properties
            (org-entry-delete nil "RESPONSE-INDEX")
            (org-entry-delete nil "CREATED")))))))

;;;###autoload
(defun ogent-review-accept ()
  "Accept the current review item.
In Zen transcripts, this accepts the current response or run.  In older
Question/Response completion workflows, it accepts the current completion
and removes transient metadata."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-review-accept only works in Org buffers"))
  (if (and (fboundp 'ogent-zen--transcript-request-heading)
           (ogent-zen--transcript-request-heading))
      (if (and (fboundp 'ogent-zen--current-response-heading)
               (ogent-zen--current-response-heading))
          (ogent-zen-accept-response)
        (ogent-zen-mark-accepted))
    (let* ((question-marker (ogent-completions--find-question-marker))
           (completions (ogent-completions--for-subtree)))
      (unless question-marker
        (user-error "Not in a Question/Response context"))
      (unless completions
        (user-error "No completions to accept"))
      (let* ((key (marker-position question-marker))
             (current-index (gethash key ogent-completions--current-index 0))
             (current-completion (nth current-index completions))
             (model (ogent-completion-model current-completion)))
        (when (and (> (length completions) 1)
                   (not (y-or-n-p
                         (format "Accept completion from %s and delete %d others? "
                                 model (1- (length completions))))))
          (user-error "Cancelled"))
        (ogent-completions--highlight current-completion)
        (when (ogent-completion-overlay current-completion)
          (delete-overlay (ogent-completion-overlay current-completion))
          (setf (ogent-completion-overlay current-completion) nil))
        (let ((to-delete (cl-remove current-completion completions)))
          (dolist (completion (reverse to-delete))
            (ogent-completions--delete-completion completion)))
        (ogent-completions--remove-transient-metadata current-completion)
        (ogent-completions--invalidate-registry question-marker)
        (setf (ogent-completion-status current-completion) 'accepted)
        (message "Accepted completion from %s (metadata cleaned)" model)))))

;;;###autoload
(defun ogent-completion-reject ()
  "Reject the current completion, deleting it and moving to next.
If this is the last completion, leaves point at the Question headline."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-completion-reject only works in Org buffers"))
  (let* ((question-marker (ogent-completions--find-question-marker))
         (completions (ogent-completions--for-subtree)))
    (unless question-marker
      (user-error "Not in a Question/Response context"))
    (unless completions
      (user-error "No completions to reject"))
    (let* ((key (marker-position question-marker))
           (current-index (gethash key ogent-completions--current-index 0))
           (current-completion (nth current-index completions))
           (model (ogent-completion-model current-completion)))
      ;; Confirm deletion
      (unless (y-or-n-p (format "Reject and delete completion from %s? " model))
        (user-error "Cancelled"))
      ;; Delete the current completion
      (ogent-completions--delete-completion current-completion)
      ;; Invalidate and rebuild registry
      (ogent-completions--invalidate-registry question-marker)
      (let ((new-completions (ogent-completions--for-subtree)))
        (if new-completions
            (progn
              ;; Adjust index if necessary
              (let ((new-index (min current-index (1- (length new-completions)))))
                (ogent-completions--set-current-index question-marker new-index)
                (ogent-completions--update-visual-state new-completions new-index)
                (goto-char (ogent-completion-marker (nth new-index new-completions)))
                (message "Rejected. Now showing completion %d of %d"
                         (1+ new-index) (length new-completions))))
          ;; No completions left, go to Question
          (goto-char question-marker)
          (message "All completions rejected"))))))

;;; Integration Hook

(defun ogent-completions--on-response-complete (request)
  "Hook function called when a response completes.
Invalidates the completion registry so it rebuilds on next access.
REQUEST is the `ogent-ui-request' struct."
  ;; Only process if we're in a session buffer with Question/Response structure
  (when (and (boundp 'ogent-session-buffer-p)
             ogent-session-buffer-p)
    ;; Invalidate any cached registry for the relevant Question
    ;; The next call to ogent-completions--for-subtree will rebuild it
    (let ((marker (and request
                       (fboundp 'ogent-ui-request-marker)
                       (ogent-ui-request-marker request))))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (let ((question-marker (ogent-completions--find-question-marker)))
              (when question-marker
                (ogent-completions--invalidate-registry question-marker)))))))))

;;; Setup

(defun ogent-completions-setup ()
  "Set up ogent-completions integration hooks."
  (add-hook 'ogent-after-completion-hook #'ogent-completions--on-response-complete))

;; Auto-setup when loaded
(with-eval-after-load 'ogent-core
  (ogent-completions-setup))

(provide 'ogent-completions)

;;; ogent-completions.el ends here

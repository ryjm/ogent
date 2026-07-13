;;; ogent-issues-edit-tests.el --- Tests for ogent-issues-edit -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the structured issue editor: chrome protection, field
;; collection, pill cycling, change diffing, and the diff-aware submit.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)
(require 'ogent-issues)
(require 'ogent-issues-edit)

;;; Fixtures

(defconst ogent-issues-edit-tests--issue
  '(:id "test-42" :title "Original title" :status "open" :priority 1
        :issue_type "feature" :assignee "jake" :labels ("ui" "ux")
        :description "Original description."
        :design "Original design."
        :acceptance_criteria "AC one."
        :notes "Some notes.")
  "Sample issue for editor tests.")

(defmacro ogent-issues-edit-tests--with-buffer (issue &rest body)
  "Run BODY in a fresh edit buffer for ISSUE, killing it afterwards."
  (declare (indent 1) (debug t))
  `(let ((buf (ogent-issues-edit--create-buffer (copy-sequence ,issue))))
     (unwind-protect
         (with-current-buffer buf ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq ogent-issues-edit--kill-confirmed t))
         (kill-buffer buf)))))

(defun ogent-issues-edit-tests--type (text)
  "Simulate interactively typing TEXT at point."
  (dolist (char (string-to-list text))
    (let ((last-command-event char))
      (call-interactively #'self-insert-command))))

;;; Rendering

(ert-deftest ogent-issues-edit-render-round-trips-fields ()
  "Every text field's rendered value collects back unchanged."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (should (equal (ogent-issues-edit--field-value 'title) "Original title"))
    (should (equal (ogent-issues-edit--field-value 'assignee) "jake"))
    (should (equal (ogent-issues-edit--field-value 'labels) "ui, ux"))
    (should (equal (ogent-issues-edit--field-value 'description)
                   "Original description."))
    (should (equal (ogent-issues-edit--field-value 'design) "Original design."))
    (should (equal (ogent-issues-edit--field-value 'acceptance) "AC one."))
    (should (equal (ogent-issues-edit--field-value 'notes) "Some notes."))))

(ert-deftest ogent-issues-edit-render-no-initial-changes ()
  "A freshly rendered editor reports no changes."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (should-not (ogent-issues-edit--changes))))

(ert-deftest ogent-issues-edit-render-places-point-in-title ()
  "The editor opens with point at the end of the title."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (should (= (point) (cdr (ogent-issues-edit--field-bounds 'title))))))

(ert-deftest ogent-issues-edit-chrome-rejects-insertion ()
  "Typing into chrome (labels, buffer start) signals `text-read-only'."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (point-min))
    (should-error (ogent-issues-edit-tests--type "x") :type 'text-read-only)
    ;; Inside the Description label line
    (goto-char (- (ogent-issues-edit--field-start 'description) 3))
    (should-error (ogent-issues-edit-tests--type "x") :type 'text-read-only)))

(ert-deftest ogent-issues-edit-chrome-rejects-deletion ()
  "Backspacing from a field start into chrome signals `text-read-only'."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (ogent-issues-edit--field-start 'title))
    (should-error (delete-char -1) :type 'text-read-only)))

;;; Editing & Collection

(ert-deftest ogent-issues-edit-typed-text-enters-field ()
  "Text typed at a field boundary lands inside the field, uncontaminated."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (ogent-issues-edit--field-start 'title))
    (ogent-issues-edit-tests--type "New ")
    (should (equal (ogent-issues-edit--field-value 'title)
                   "New Original title"))
    (should-not (get-text-property (ogent-issues-edit--field-start 'title)
                                   'ogent-edit-chrome))
    (let ((changes (ogent-issues-edit--changes)))
      (should (= (length changes) 1))
      (should (eq (caar changes) 'title)))))

(ert-deftest ogent-issues-edit-empty-field-is-editable ()
  "A field rendered empty still accepts typed text."
  (ogent-issues-edit-tests--with-buffer
      (plist-put (copy-sequence ogent-issues-edit-tests--issue) :notes nil)
    (should (equal (ogent-issues-edit--field-value 'notes) ""))
    (goto-char (ogent-issues-edit--field-start 'notes))
    (ogent-issues-edit-tests--type "fresh note")
    (should (equal (ogent-issues-edit--field-value 'notes) "fresh note"))))

(ert-deftest ogent-issues-edit-single-line-fields-normalize-newlines ()
  "Pasted newlines in single-line fields collapse to spaces on collect."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (ogent-issues-edit--field-start 'title))
    (insert "one\ntwo ")
    (should (equal (plist-get (ogent-issues-edit--collect) :title)
                   "one two Original title"))))

(ert-deftest ogent-issues-edit-labels-diff-to-add-remove ()
  "Label edits become :add-labels/:remove-labels update props."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (pcase-let ((`(,start . ,end) (ogent-issues-edit--field-bounds 'labels)))
      (goto-char start)
      (delete-region start end)
      (insert "ui, polish"))
    (let ((props (ogent-issues-edit--update-props
                  (ogent-issues-edit--changes))))
      (should (equal (plist-get props :add-labels) '("polish")))
      (should (equal (plist-get props :remove-labels) '("ux")))
      (should-not (plist-member props :title)))))

;;; Pills

(ert-deftest ogent-issues-edit-pill-cycle-updates-value-and-buffer ()
  "Cycling the priority pill advances the value and re-renders in place."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (car (ogent-issues-edit--pill-bounds 'priority)))
    (ogent-issues-edit-pill-next)
    (should (= (alist-get 'priority ogent-issues-edit--pills) 2))
    (pcase-let ((`(,start . ,end) (ogent-issues-edit--pill-bounds 'priority)))
      (should (string-match-p "P2" (buffer-substring-no-properties start end))))
    (let ((changes (ogent-issues-edit--changes)))
      (should (equal (assq 'priority changes) '(priority "priority" 1 2))))))

(ert-deftest ogent-issues-edit-pill-wraps-through-p4 ()
  "Priority cycling reaches P4 and wraps back to P0."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (car (ogent-issues-edit--pill-bounds 'priority)))
    (dotimes (_ 3) (ogent-issues-edit-pill-next))
    (should (= (alist-get 'priority ogent-issues-edit--pills) 4))
    (ogent-issues-edit-pill-next)
    (should (= (alist-get 'priority ogent-issues-edit--pills) 0))))

(ert-deftest ogent-issues-edit-pill-digit-sets-priority-directly ()
  "Typing a digit on the priority pill sets that priority."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (car (ogent-issues-edit--pill-bounds 'priority)))
    (let ((last-command-event ?4))
      (ogent-issues-edit-pill-digit))
    (should (= (alist-get 'priority ogent-issues-edit--pills) 4))))

(ert-deftest ogent-issues-edit-pill-keeps-fixed-width ()
  "Pill spans keep a constant character width across re-renders."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (pcase-let ((`(,start . ,end) (ogent-issues-edit--pill-bounds 'status)))
      (let ((width (- end start)))
        (goto-char start)
        (ogent-issues-edit-pill-next)     ; open -> in_progress (longer label)
        (pcase-let ((`(,start2 . ,end2)
                     (ogent-issues-edit--pill-bounds 'status)))
          (should (= (- end2 start2) width)))))))

(ert-deftest ogent-issues-edit-pill-rerender-preserves-undo ()
  "Undo of a text edit still applies after a silent pill re-render."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (goto-char (ogent-issues-edit--field-start 'description))
    (ogent-issues-edit-tests--type "Q")
    (undo-boundary)
    (goto-char (car (ogent-issues-edit--pill-bounds 'priority)))
    (ogent-issues-edit-pill-next)
    (primitive-undo 1 (if (car buffer-undo-list)
                          buffer-undo-list
                        (cdr buffer-undo-list)))
    (should (equal (ogent-issues-edit--field-value 'description)
                   "Original description."))))

(ert-deftest ogent-issues-edit-terminal-status-is-frozen ()
  "A closed issue renders its status as static text, not a pill."
  (ogent-issues-edit-tests--with-buffer
      (plist-put (copy-sequence ogent-issues-edit-tests--issue)
                 :status "closed")
    (should-not (assq 'status ogent-issues-edit--pills))
    (should-not (ogent-issues-edit--pill-bounds 'status))
    (should (string-match-p "reopen from the issue list" (buffer-string)))
    ;; And status can never appear in the diff.
    (should-not (assq 'status (ogent-issues-edit--changes)))))

;;; Navigation

(ert-deftest ogent-issues-edit-tab-reaches-pills-and-fields ()
  "TAB from the title lands on the priority pill."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (cdr (ogent-issues-edit--field-bounds 'title)))
    (ogent-issues-edit-next-field)
    (should (eq (ogent-issues-edit--pill-at-point) 'priority))))

(ert-deftest ogent-issues-edit-newline-dwim-by-field-kind ()
  "RET inserts a newline in block fields and skips ahead in line fields."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    ;; Block field: newline inserted
    (goto-char (cdr (ogent-issues-edit--field-bounds 'description)))
    (ogent-issues-edit-newline-dwim)
    (should (string-suffix-p "\n" (ogent-issues-edit--field-value 'description)))
    ;; Line field: point moves, no newline
    (goto-char (cdr (ogent-issues-edit--field-bounds 'title)))
    (ogent-issues-edit-newline-dwim)
    (should (equal (ogent-issues-edit--field-value 'title) "Original title"))
    (should-not (eq (ogent-issues-edit--field-at-point) 'title))))

;;; Revert

(ert-deftest ogent-issues-edit-revert-field-restores-original ()
  "Reverting restores the field at point to its fetched value."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (ogent-issues-edit--field-start 'title))
    (ogent-issues-edit-tests--type "junk ")
    (should (ogent-issues-edit--changes))
    (goto-char (ogent-issues-edit--field-start 'title))
    (ogent-issues-edit-revert-field)
    (should-not (ogent-issues-edit--changes))))

(ert-deftest ogent-issues-edit-revert-pill-restores-original ()
  "Reverting on a pill restores the fetched enum value."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (goto-char (car (ogent-issues-edit--pill-bounds 'type)))
    (ogent-issues-edit-pill-next)
    (should (assq 'type (ogent-issues-edit--changes)))
    (goto-char (car (ogent-issues-edit--pill-bounds 'type)))
    (ogent-issues-edit-revert-field)
    (should-not (ogent-issues-edit--changes))))

;;; Apply

(ert-deftest ogent-issues-edit-apply-sends-only-changed-fields ()
  "Applying sends one update carrying exactly the changed props."
  (let (captured-id captured-props success-cb)
    (cl-letf (((symbol-function 'ogent-issues-bd-update)
               (lambda (id callback &rest props)
                 (setq captured-id id
                       captured-props props
                       success-cb callback))))
      (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
        (goto-char (ogent-issues-edit--field-start 'title))
        (ogent-issues-edit-tests--type "New ")
        (goto-char (car (ogent-issues-edit--pill-bounds 'type)))
        (ogent-issues-edit-pill-next)   ; feature -> chore
        (ogent-issues-edit-apply)
        (should (equal captured-id "test-42"))
        (should (equal (plist-get captured-props :title) "New Original title"))
        (should (equal (plist-get captured-props :type) "chore"))
        (should (functionp (plist-get captured-props :error-callback)))
        ;; Unchanged fields never travel.
        (dolist (key '(:status :priority :assignee :description
                               :design :acceptance-criteria :notes
                               :add-labels :remove-labels))
          (should-not (plist-member captured-props key)))
        ;; Buffer intact until the update is confirmed...
        (should (buffer-live-p (current-buffer)))
        (should ogent-issues-edit--pending))
      ;; ...and killed on confirmed success.
      (funcall success-cb)
      (should-not (get-buffer "*ogent-issue-edit: test-42*")))))

(ert-deftest ogent-issues-edit-apply-failure-keeps-buffer-editable ()
  "A failed update preserves the buffer, its changes, and clears pending."
  (cl-letf (((symbol-function 'ogent-issues-bd-update)
             (lambda (_id _callback &rest props)
               (funcall (plist-get props :error-callback) "boom"))))
    (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
      (goto-char (ogent-issues-edit--field-start 'title))
      (ogent-issues-edit-tests--type "New ")
      (ogent-issues-edit-apply)
      (should (buffer-live-p (current-buffer)))
      (should-not ogent-issues-edit--pending)
      (should (equal (plist-get (ogent-issues-edit--collect) :title)
                     "New Original title")))))

(ert-deftest ogent-issues-edit-apply-without-changes-errors ()
  "Applying a pristine form is a `user-error', not a br round-trip."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (should-error (ogent-issues-edit-apply) :type 'user-error)))

(ert-deftest ogent-issues-edit-apply-rejects-empty-title ()
  "Blanking the title is rejected before anything is sent."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    (pcase-let ((`(,start . ,end) (ogent-issues-edit--field-bounds 'title)))
      (delete-region start end))
    (should-error (ogent-issues-edit-apply) :type 'user-error)))

;;; Kill Protection

(ert-deftest ogent-issues-edit-kill-guard-blocks-unsaved-changes ()
  "Killing a buffer with changes prompts; declining keeps the buffer."
  (ogent-issues-edit-tests--with-buffer ogent-issues-edit-tests--issue
    ;; Pill-only change: invisible to buffer-modified-p by design.
    (goto-char (car (ogent-issues-edit--pill-bounds 'priority)))
    (ogent-issues-edit-pill-next)
    (should-not (buffer-modified-p))
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (kill-buffer buf)
        (should (buffer-live-p buf)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (kill-buffer buf)
        (should-not (buffer-live-p buf))))))

(ert-deftest ogent-issues-edit-kill-guard-passes-clean-buffers ()
  "A pristine edit buffer dies without prompting."
  (let ((buf (ogent-issues-edit--create-buffer
              (copy-sequence ogent-issues-edit-tests--issue)))
        (prompted nil))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (setq prompted t) t)))
      (kill-buffer buf))
    (should-not prompted)
    (should-not (buffer-live-p buf))))

;;; bd Layer

(ert-deftest ogent-issues-edit-bd-update-builds-extended-flags ()
  "The extended update props map to the right br flags, in order."
  (let (captured)
    (cl-letf (((symbol-function 'ogent-issues-bd--run-async)
               (lambda (args callback &rest _)
                 (setq captured args)
                 (funcall callback "ok")))
              ((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil)))
      (ogent-issues-bd-update "id-1" #'ignore
                              :title "T"
                              :assignee ""
                              :priority 4
                              :add-labels '("a" "b")
                              :remove-labels '("c"))
      (should (equal captured
                     '("update" "id-1"
                       "--title" "T"
                       "--assignee" ""
                       "--priority" "4"
                       "--add-label" "a" "--add-label" "b"
                       "--remove-label" "c"))))))

(ert-deftest ogent-issues-edit-bd-update-skips-absent-fields ()
  "Props not supplied produce no flags (legacy call shape unchanged)."
  (let (captured)
    (cl-letf (((symbol-function 'ogent-issues-bd--run-async)
               (lambda (args callback &rest _)
                 (setq captured args)
                 (funcall callback "ok")))
              ((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil)))
      (ogent-issues-bd-update "id-2" #'ignore :status "in_progress")
      (should (equal captured '("update" "id-2" "--status" "in_progress"))))))

(provide 'ogent-issues-edit-tests)

;;; ogent-issues-edit-tests.el ends here

;;; ogent-issues-edit.el --- Structured issue editor for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; A form-style buffer for editing a beads issue in place: editable field
;; regions framed by read-only chrome, cycling "pill" controls for the
;; enum fields (priority, type, status), live change tracking in the
;; header line, and a diff-aware submit that sends only changed fields
;; through `br update'.
;;
;; Mechanics: chrome text carries `read-only' plus `ogent-edit-chrome';
;; the last chrome character before each editable region is fully
;; `rear-nonsticky' and tagged `ogent-edit-field-follows', so field
;; bounds are recovered by property scan (no marker bookkeeping) and
;; typed text can never inherit chrome properties.  Pills re-render at a
;; fixed character width inside `with-silent-modifications', which keeps
;; the user's undo history position-stable.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'ogent-ops-style)
(require 'ogent-issues-bd)

;; Core ogent-issues helpers referenced below live in the facade
;; (`ogent-issues') and the detail satellite (`ogent-issues-detail').
;; Declare them here so this file byte-compiles on its own; it avoids
;; requiring the facade to keep the load graph acyclic.
(declare-function ogent-issues-refresh "ogent-issues")
(declare-function ogent-issues--current-issue "ogent-issues")
(declare-function ogent-issues--status-label "ogent-issues")
(declare-function ogent-issues--status-face "ogent-issues")
(declare-function ogent-issues--status-icon "ogent-issues")
(declare-function ogent-issues--priority-face "ogent-issues")
(declare-function ogent-issues--type-icon "ogent-issues")
(declare-function ogent-issues--render-detail "ogent-issues-detail")
(defvar ogent-issues-use-unicode)
(defvar ogent-issues-detail--issue)

;;; Faces

(defface ogent-issues-edit-label
  '((t :inherit shadow :weight bold))
  "Face for field labels in the issue editor."
  :group 'ogent-issues-faces)

(defface ogent-issues-edit-title
  '((t :weight bold :height 1.15))
  "Face for the title field content in the issue editor."
  :group 'ogent-issues-faces)

(defface ogent-issues-edit-rule
  '((t :inherit shadow))
  "Face for horizontal rules in the issue editor."
  :group 'ogent-issues-faces)

(defface ogent-issues-edit-modified
  '((t :inherit warning :weight bold))
  "Face for the modified-field marker in the issue editor."
  :group 'ogent-issues-faces)

;;; Field Specs

(defconst ogent-issues-edit--text-fields
  '((title       :label "Title"               :source :title               :line t :block t)
    (assignee    :label "Assignee"            :source :assignee            :line t)
    (labels      :label "Labels"              :source :labels              :line t)
    (description :label "Description"         :source :description         :block t)
    (design      :label "Design"              :source :design              :block t)
    (acceptance  :label "Acceptance Criteria" :source :acceptance_criteria :block t)
    (notes       :label "Notes"               :source :notes               :block t))
  "Editable text fields: (SYMBOL :label L :source KEY [:line t] [:block t]).
:line marks single-line semantics (newlines collapse on collect);
:block renders the value on its own line below the label.")

(defconst ogent-issues-edit--pill-specs
  '((priority :label "Priority" :choices (0 1 2 3 4))
    (type     :label "Type"     :choices ("task" "bug" "feature" "chore" "epic"))
    (status   :label "Status"   :choices ("open" "in_progress" "blocked" "deferred")))
  "Cycling pill fields: (SYMBOL :label L :choices VALUES).")

(defconst ogent-issues-edit--priority-names
  '((0 . "Critical") (1 . "High") (2 . "Medium") (3 . "Low") (4 . "Backlog"))
  "Human names for priority levels, following the beads P0-P4 scale.")

(defconst ogent-issues-edit--terminal-statuses '("closed" "tombstone")
  "Statuses `br update --status' refuses; the status pill is frozen for these.")

;;; Buffer-local State

(defvar-local ogent-issues-edit--original nil
  "The issue plist as fetched when the editor was opened.")

(defvar-local ogent-issues-edit--pills nil
  "Alist of (FIELD . CURRENT-VALUE) for the pill controls.")

(defvar-local ogent-issues-edit--pending nil
  "Non-nil while a `br update' spawned from this buffer is in flight.")

(defvar-local ogent-issues-edit--kill-confirmed nil
  "Non-nil once discarding this edit buffer has been confirmed or completed.")

;;; Chrome Insertion

(defun ogent-issues-edit--chrome (text &rest extra)
  "Insert TEXT as read-only chrome with EXTRA text properties."
  (let ((start (point)))
    (insert text)
    (add-text-properties start (point)
                         (append '(read-only t ogent-edit-chrome t) extra))))

(defun ogent-issues-edit--anchor (field)
  "Mark the character before point as the editable-region anchor for FIELD.
The char becomes fully rear-nonsticky so typed text inherits none of
the chrome properties, and is tagged so field bounds can be recovered."
  (add-text-properties (1- (point)) (point)
                       (list 'rear-nonsticky t
                             'ogent-edit-field-follows field)))

;;; Field Bounds & Values

(defun ogent-issues-edit--field-start (field)
  "Return the buffer position where FIELD's editable region begins."
  (let ((pos (point-min)) hit)
    (while (and (not hit) pos)
      (if (eq (get-text-property pos 'ogent-edit-field-follows) field)
          (setq hit (1+ pos))
        (setq pos (next-single-property-change pos 'ogent-edit-field-follows))))
    hit))

(defun ogent-issues-edit--field-bounds (field)
  "Return (START . END) of FIELD's editable region, or nil."
  (when-let ((start (ogent-issues-edit--field-start field)))
    (cons start
          (if (get-text-property start 'ogent-edit-chrome)
              start                     ; empty field
            (or (next-single-property-change start 'ogent-edit-chrome)
                (point-max))))))

(defun ogent-issues-edit--field-value (field)
  "Return FIELD's current buffer text, un-normalized."
  (pcase-let ((`(,start . ,end) (ogent-issues-edit--field-bounds field)))
    (if start (buffer-substring-no-properties start end) "")))

(defun ogent-issues-edit--field-at-point ()
  "Return the symbol of the text field surrounding point."
  (let ((p (point)))
    (car (seq-find (pcase-lambda (`(,field . ,_))
                     (pcase-let ((`(,start . ,end)
                                  (ogent-issues-edit--field-bounds field)))
                       (and start (>= p start) (<= p end))))
                   ogent-issues-edit--text-fields))))

;;; Normalization

(defun ogent-issues-edit--norm-line (s)
  "Collapse whitespace in S to single spaces and trim."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or s ""))))

(defun ogent-issues-edit--norm-block (s)
  "Trim outer whitespace from S, mapping nil to the empty string."
  (string-trim (or s "")))

(defun ogent-issues-edit--parse-labels (s)
  "Parse comma-separated labels string S into a sorted list."
  (sort (seq-remove #'string-empty-p
                    (mapcar #'string-trim (split-string (or s "") ",")))
        #'string<))

;;; Pills

(defun ogent-issues-edit--pill-choices (field)
  "Return the value choices for pill FIELD."
  (plist-get (alist-get field ogent-issues-edit--pill-specs) :choices))

(defun ogent-issues-edit--pill-text (field value)
  "Return the propertized display text for pill FIELD showing VALUE."
  (let ((ogent-ops-use-unicode (bound-and-true-p ogent-issues-use-unicode)))
    (pcase field
      ('priority
       (let ((face (ogent-issues--priority-face value)))
         (concat (propertize (ogent-ops-priority-symbol value) 'face face)
                 " "
                 (propertize (format "P%d · %s" value
                                     (alist-get value ogent-issues-edit--priority-names
                                                "?"))
                             'face face))))
      ('type
       (concat (ogent-issues--type-icon value) " " value))
      ('status
       (let ((face (ogent-issues--status-face value)))
         (concat (propertize (ogent-issues--status-icon value) 'face face)
                 " "
                 (propertize (ogent-issues--status-label value) 'face face)))))))

(defun ogent-issues-edit--pill-width (field)
  "Return the fixed character width reserved for pill FIELD.
Constant width keeps undo positions stable across pill re-renders."
  (+ 2 (apply #'max
              (mapcar (lambda (choice)
                        (length (ogent-issues-edit--pill-text field choice)))
                      (ogent-issues-edit--pill-choices field)))))

(defvar ogent-issues-edit-pill-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-issues-edit-pill-next)
    (define-key map (kbd "SPC") #'ogent-issues-edit-pill-next)
    (define-key map [mouse-1] #'ogent-issues-edit-pill-next)
    (define-key map (kbd "DEL") #'ogent-issues-edit-pill-prev)
    (define-key map (kbd "=") #'ogent-issues-edit-pill-choose)
    (dotimes (i 10)
      (define-key map (number-to-string i) #'ogent-issues-edit-pill-digit))
    map)
  "Keymap active on pill controls in the issue editor.")

(defun ogent-issues-edit--insert-pill (field)
  "Insert the pill control for FIELD at point, padded to fixed width."
  (let* ((value (alist-get field ogent-issues-edit--pills))
         (modified (not (equal value (ogent-issues-edit--pill-original field))))
         (text (concat (ogent-issues-edit--pill-text field value)
                       (when modified
                         (propertize " •" 'face 'ogent-issues-edit-modified))))
         (pad (max 0 (- (ogent-issues-edit--pill-width field) (length text))))
         (start (point)))
    (insert text (make-string pad ?\s))
    (add-text-properties
     start (point)
     (list 'read-only t 'ogent-edit-chrome t
           'ogent-edit-pill field
           'keymap ogent-issues-edit-pill-map
           'mouse-face 'highlight
           'help-echo "RET/SPC: next · DEL: previous · =: choose · digits: direct"))))

(defun ogent-issues-edit--pill-bounds (field)
  "Return (START . END) of pill FIELD's rendered span."
  (when-let ((start (text-property-any (point-min) (point-max)
                                       'ogent-edit-pill field)))
    (cons start (or (next-single-property-change start 'ogent-edit-pill)
                    (point-max)))))

(defun ogent-issues-edit--pill-original (field)
  "Return the original issue value for pill FIELD."
  (pcase field
    ('priority (or (plist-get ogent-issues-edit--original :priority) 2))
    ('type (or (plist-get ogent-issues-edit--original :issue_type) "task"))
    ('status (or (plist-get ogent-issues-edit--original :status) "open"))))

(defun ogent-issues-edit--rerender-pill (field)
  "Re-render pill FIELD in place, preserving point and undo history."
  (pcase-let ((`(,start . ,end) (ogent-issues-edit--pill-bounds field)))
    (when start
      (let ((at-pill (and (>= (point) start) (< (point) end))))
        (with-silent-modifications
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (ogent-issues-edit--insert-pill field)))
        (when at-pill (goto-char start))))))

(defun ogent-issues-edit--pill-at-point ()
  "Return the pill field symbol at point, if any."
  (get-text-property (point) 'ogent-edit-pill))

(defun ogent-issues-edit--pill-set (field value)
  "Set pill FIELD to VALUE, re-render it, and echo the new state."
  (setf (alist-get field ogent-issues-edit--pills) value)
  (ogent-issues-edit--rerender-pill field)
  (force-mode-line-update))

(defun ogent-issues-edit--pill-step (n)
  "Cycle the pill at point forward N choices (backward when negative)."
  (let ((field (ogent-issues-edit--pill-at-point)))
    (unless field (user-error "No pill at point"))
    (let* ((choices (ogent-issues-edit--pill-choices field))
           (idx (or (seq-position choices
                                  (alist-get field ogent-issues-edit--pills))
                    0)))
      (ogent-issues-edit--pill-set
       field (nth (mod (+ idx n) (length choices)) choices)))))

(defun ogent-issues-edit-pill-next (&optional event)
  "Cycle the pill at point (or under a mouse EVENT) to its next value."
  (interactive (list last-input-event))
  (when (and event (mouse-event-p event))
    (mouse-set-point event))
  (ogent-issues-edit--pill-step 1))

(defun ogent-issues-edit-pill-prev ()
  "Cycle the pill at point to its previous value."
  (interactive)
  (ogent-issues-edit--pill-step -1))

(defun ogent-issues-edit-pill-digit ()
  "Set the pill at point directly from the typed digit.
On the priority pill the digit is the priority level; on other pills
it selects the Nth choice (1-based)."
  (interactive)
  (let ((field (ogent-issues-edit--pill-at-point))
        (digit (- last-command-event ?0)))
    (unless field (user-error "No pill at point"))
    (let ((choices (ogent-issues-edit--pill-choices field)))
      (cond
       ((eq field 'priority)
        (if (memq digit choices)
            (ogent-issues-edit--pill-set field digit)
          (user-error "Priority must be 0-4")))
       ((and (>= digit 1) (<= digit (length choices)))
        (ogent-issues-edit--pill-set field (nth (1- digit) choices)))
       (t (user-error "Choose 1-%d" (length choices)))))))

(defun ogent-issues-edit-pill-choose ()
  "Pick a value for the pill at point with completion."
  (interactive)
  (let ((field (ogent-issues-edit--pill-at-point)))
    (unless field (user-error "No pill at point"))
    (let* ((choices (ogent-issues-edit--pill-choices field))
           (strings (mapcar (lambda (c) (format "%s" c)) choices))
           (picked (completing-read (format "%s: " (capitalize (symbol-name field)))
                                    strings nil t))
           (value (nth (seq-position strings picked) choices)))
      (ogent-issues-edit--pill-set field value))))

;;; Rendering

(defun ogent-issues-edit--rule ()
  "Return a horizontal rule string."
  (propertize (make-string 48 (if (bound-and-true-p ogent-issues-use-unicode) ?─ ?-))
              'face 'ogent-issues-edit-rule))

(defconst ogent-issues-edit--meta-label-width 11
  "Column width of labels in the metadata block.")

(defun ogent-issues-edit--insert-text-field (field)
  "Insert label chrome and the editable region for text FIELD."
  (let* ((spec (alist-get field ogent-issues-edit--text-fields))
         (label (plist-get spec :label))
         (source (plist-get spec :source))
         (raw (plist-get ogent-issues-edit--original source))
         (value (cond ((eq field 'labels)
                       (string-join (plist-get ogent-issues-edit--original :labels) ", "))
                      ((plist-get spec :line)
                       (ogent-issues-edit--norm-line raw))
                      (t (ogent-issues-edit--norm-block raw)))))
    (if (plist-get spec :block)
        (ogent-issues-edit--chrome (concat label "\n")
                                   'face 'ogent-issues-edit-label)
      (ogent-issues-edit--chrome
       (format (format "%%-%ds" ogent-issues-edit--meta-label-width) label)
       'face 'ogent-issues-edit-label))
    (ogent-issues-edit--anchor field)
    (insert (substring-no-properties value))))

(defun ogent-issues-edit--render ()
  "Render the full edit form from `ogent-issues-edit--original'."
  (let ((inhibit-read-only t)
        (issue ogent-issues-edit--original))
    (erase-buffer)
    (remove-overlays)
    ;; Identity line + rule
    (ogent-issues-edit--chrome
     (concat (propertize (or (plist-get issue :id) "?")
                         'face 'ogent-issues-id)
             (propertize "  ·  edit" 'face 'ogent-issues-dimmed)
             "\n")
     'front-sticky '(read-only))
    (ogent-issues-edit--chrome (concat (ogent-issues-edit--rule) "\n\n"))
    ;; Title (hero)
    (ogent-issues-edit--insert-text-field 'title)
    ;; Metadata block: pills then inline fields
    (ogent-issues-edit--chrome "\n\n")
    (dolist (field '(priority type status))
      (let ((label (plist-get (alist-get field ogent-issues-edit--pill-specs)
                              :label)))
        (ogent-issues-edit--chrome
         (format (format "%%-%ds" ogent-issues-edit--meta-label-width) label)
         'face 'ogent-issues-edit-label)
        (if (assq field ogent-issues-edit--pills)
            (ogent-issues-edit--insert-pill field)
          ;; Terminal status: frozen, not editable.
          (ogent-issues-edit--chrome
           (concat (propertize (ogent-issues--status-label
                                (plist-get issue :status))
                               'face (ogent-issues--status-face
                                      (plist-get issue :status)))
                   (propertize "  (reopen from the issue list)"
                               'face 'ogent-issues-dimmed))))
        (ogent-issues-edit--chrome "\n")))
    (ogent-issues-edit--insert-text-field 'assignee)
    (ogent-issues-edit--chrome "\n")
    (ogent-issues-edit--insert-text-field 'labels)
    ;; Long-form blocks
    (dolist (field '(description design acceptance notes))
      (ogent-issues-edit--chrome "\n\n")
      (ogent-issues-edit--insert-text-field field))
    ;; Footer
    (ogent-issues-edit--chrome
     (concat "\n\n" (ogent-issues-edit--rule) "\n"
             (propertize "TAB" 'face 'ogent-issues-header-line-key)
             (propertize " fields  " 'face 'ogent-issues-dimmed)
             (propertize "RET" 'face 'ogent-issues-header-line-key)
             (propertize " cycle pills  " 'face 'ogent-issues-dimmed)
             (propertize "C-c C-c" 'face 'ogent-issues-header-line-key)
             (propertize " apply  " 'face 'ogent-issues-dimmed)
             (propertize "C-c C-k" 'face 'ogent-issues-header-line-key)
             (propertize " cancel  " 'face 'ogent-issues-dimmed)
             (propertize "C-c C-r" 'face 'ogent-issues-header-line-key)
             (propertize " revert field" 'face 'ogent-issues-dimmed)
             "\n"))
    ;; Title face via overlay so typed text stays styled.
    (pcase-let ((`(,start . ,end) (ogent-issues-edit--field-bounds 'title)))
      (let ((ov (make-overlay start end nil nil t)))
        (overlay-put ov 'face 'ogent-issues-edit-title)))))

;;; Collect & Diff

(defun ogent-issues-edit--collect ()
  "Return the current form state as a normalized plist."
  (list :title (ogent-issues-edit--norm-line
                (ogent-issues-edit--field-value 'title))
        :assignee (ogent-issues-edit--norm-line
                   (ogent-issues-edit--field-value 'assignee))
        :labels (ogent-issues-edit--parse-labels
                 (ogent-issues-edit--field-value 'labels))
        :description (ogent-issues-edit--norm-block
                      (ogent-issues-edit--field-value 'description))
        :design (ogent-issues-edit--norm-block
                 (ogent-issues-edit--field-value 'design))
        :acceptance (ogent-issues-edit--norm-block
                     (ogent-issues-edit--field-value 'acceptance))
        :notes (ogent-issues-edit--norm-block
                (ogent-issues-edit--field-value 'notes))
        :priority (alist-get 'priority ogent-issues-edit--pills)
        :type (alist-get 'type ogent-issues-edit--pills)
        :status (alist-get 'status ogent-issues-edit--pills)))

(defun ogent-issues-edit--changes ()
  "Return the list of changed fields as (FIELD LABEL ORIGINAL NEW)."
  (let* ((orig ogent-issues-edit--original)
         (cur (ogent-issues-edit--collect))
         (changes nil))
    (cl-flet ((push-if (field label old new)
                (unless (equal old new)
                  (push (list field label old new) changes))))
      (push-if 'title "title"
               (ogent-issues-edit--norm-line (plist-get orig :title))
               (plist-get cur :title))
      (dolist (pill '(priority type status))
        (when-let ((new (plist-get cur (intern (format ":%s" pill)))))
          (push-if pill (symbol-name pill)
                   (ogent-issues-edit--pill-original pill) new)))
      (push-if 'assignee "assignee"
               (ogent-issues-edit--norm-line (plist-get orig :assignee))
               (plist-get cur :assignee))
      (push-if 'labels "labels"
               (sort (copy-sequence (plist-get orig :labels)) #'string<)
               (plist-get cur :labels))
      (push-if 'description "description"
               (ogent-issues-edit--norm-block (plist-get orig :description))
               (plist-get cur :description))
      (push-if 'design "design"
               (ogent-issues-edit--norm-block (plist-get orig :design))
               (plist-get cur :design))
      (push-if 'acceptance "acceptance"
               (ogent-issues-edit--norm-block (plist-get orig :acceptance_criteria))
               (plist-get cur :acceptance))
      (push-if 'notes "notes"
               (ogent-issues-edit--norm-block (plist-get orig :notes))
               (plist-get cur :notes)))
    (nreverse changes)))

(defun ogent-issues-edit--update-props (changes)
  "Build the `ogent-issues-bd-update' props plist.
CHANGES is the change list from `ogent-issues-edit--changes'."
  (let (props)
    (pcase-dolist (`(,field ,_label ,old ,new) changes)
      (pcase field
        ('title (setq props (append props (list :title new))))
        ('priority (setq props (append props (list :priority new))))
        ('type (setq props (append props (list :type new))))
        ('status (setq props (append props (list :status new))))
        ('assignee (setq props (append props (list :assignee new))))
        ('description (setq props (append props (list :description new))))
        ('design (setq props (append props (list :design new))))
        ('acceptance (setq props (append props (list :acceptance-criteria new))))
        ('notes (setq props (append props (list :notes new))))
        ('labels
         (let ((add (seq-difference new old))
               (remove (seq-difference old new)))
           (when add (setq props (append props (list :add-labels add))))
           (when remove (setq props (append props (list :remove-labels remove))))))))
    props))

;;; Header Line

(defun ogent-issues-edit--header-line ()
  "Return the live header line for the issue editor."
  (let ((id (or (plist-get ogent-issues-edit--original :id) "?"))
        (changes (ogent-issues-edit--changes)))
    (concat
     " "
     (propertize id 'face 'ogent-issues-id)
     (propertize "  edit" 'face 'ogent-issues-dimmed)
     "  "
     (cond
      (ogent-issues-edit--pending
       (propertize "applying…" 'face 'ogent-issues-header-line-ready))
      (changes
       (concat
        (propertize "● " 'face 'ogent-issues-edit-modified)
        (propertize (mapconcat (lambda (c) (nth 1 c)) changes ", ")
                    'face 'ogent-issues-edit-modified)))
      (t (propertize "no changes" 'face 'ogent-issues-dimmed)))
     "  "
     (propertize "C-c C-c" 'face 'ogent-issues-header-line-key)
     (propertize ":apply " 'face 'ogent-issues-dimmed)
     (propertize "C-c C-k" 'face 'ogent-issues-header-line-key)
     (propertize ":cancel" 'face 'ogent-issues-dimmed))))

;;; Navigation

(defun ogent-issues-edit--nav-points ()
  "Return sorted positions of every field end and pill start."
  (sort
   (append
    (delq nil
          (mapcar (lambda (spec)
                    (cdr (ogent-issues-edit--field-bounds (car spec))))
                  ogent-issues-edit--text-fields))
    (delq nil
          (mapcar (lambda (spec)
                    (car (ogent-issues-edit--pill-bounds (car spec))))
                  ogent-issues-edit--pill-specs)))
   #'<))

(defun ogent-issues-edit-next-field ()
  "Move point to the next field or pill."
  (interactive)
  (let* ((points (ogent-issues-edit--nav-points))
         (next (or (seq-find (lambda (p) (> p (point))) points)
                   (car points))))
    (when next
      (goto-char next)
      (when-let ((pill (ogent-issues-edit--pill-at-point)))
        (message "%s: RET/SPC to cycle, = to choose" (capitalize (symbol-name pill)))))))

(defun ogent-issues-edit-prev-field ()
  "Move point to the previous field or pill."
  (interactive)
  (let* ((points (ogent-issues-edit--nav-points))
         (prev (or (seq-find (lambda (p) (< p (point))) (reverse points))
                   (car (last points)))))
    (when prev (goto-char prev))))

(defun ogent-issues-edit-newline-dwim ()
  "Insert a newline in block fields; jump to the next field elsewhere."
  (interactive)
  (let* ((field (ogent-issues-edit--field-at-point))
         (spec (alist-get field ogent-issues-edit--text-fields)))
    (if (and field (not (plist-get spec :line)))
        (newline)
      (ogent-issues-edit-next-field))))

;;; Actions

(defun ogent-issues-edit-revert-field ()
  "Restore the field or pill at point to its original value."
  (interactive)
  (if-let ((pill (ogent-issues-edit--pill-at-point)))
      (progn
        (ogent-issues-edit--pill-set pill (ogent-issues-edit--pill-original pill))
        (message "Reverted %s" pill))
    (let ((field (ogent-issues-edit--field-at-point)))
      (unless field (user-error "No field at point"))
      (pcase-let ((`(,start . ,end) (ogent-issues-edit--field-bounds field)))
        (let* ((spec (alist-get field ogent-issues-edit--text-fields))
               (raw (plist-get ogent-issues-edit--original (plist-get spec :source)))
               (value (cond ((eq field 'labels)
                             (string-join (plist-get ogent-issues-edit--original :labels)
                                          ", "))
                            ((plist-get spec :line)
                             (ogent-issues-edit--norm-line raw))
                            (t (ogent-issues-edit--norm-block raw)))))
          (goto-char start)
          (delete-region start end)
          (insert value)
          (message "Reverted %s" field))))))

(defun ogent-issues-edit--propagate (id root)
  "Refresh list buffers for ROOT and detail buffers showing ID."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (cond
       ((and (derived-mode-p 'ogent-issues-mode)
             (equal (ogent-issues-bd-project-root) root))
        (ogent-issues-refresh))
       ((and (derived-mode-p 'ogent-issues-detail-mode)
             (boundp 'ogent-issues-detail--issue)
             (equal (plist-get ogent-issues-detail--issue :id) id))
        (let ((name (buffer-name buf)))
          (ogent-issues-bd-get
           id
           (lambda (fresh)
             (when (and fresh (get-buffer name))
               (ogent-issues--render-detail fresh root name)))
           nil)))))))

(defun ogent-issues-edit-apply ()
  "Apply the changed fields with a single `br update' call.
The buffer stays intact until the update is confirmed; on failure it
remains editable with all changes preserved."
  (interactive)
  (when ogent-issues-edit--pending
    (user-error "Update already in progress"))
  (let ((changes (ogent-issues-edit--changes)))
    (unless changes
      (user-error "No changes to apply"))
    (when (string-empty-p (ogent-issues-edit--norm-line
                           (ogent-issues-edit--field-value 'title)))
      (user-error "Title cannot be empty"))
    (let* ((id (plist-get ogent-issues-edit--original :id))
           (root (ogent-issues-bd-project-root))
           (buf (current-buffer))
           (summary (mapconcat (lambda (c) (nth 1 c)) changes ", "))
           (props (ogent-issues-edit--update-props changes)))
      (setq ogent-issues-edit--pending t)
      (force-mode-line-update)
      (apply #'ogent-issues-bd-update id
             (lambda ()
               (message "ogent: %s updated — %s" id summary)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq ogent-issues-edit--kill-confirmed t))
                 (kill-buffer buf))
               (ogent-issues-edit--propagate id root))
             (append props
                     (list :error-callback
                           (lambda (err)
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (setq ogent-issues-edit--pending nil)
                                 (force-mode-line-update)))
                             (message "ogent: update failed: %s" err))))))))

(defun ogent-issues-edit-cancel ()
  "Discard the edit buffer, confirming when there is unsaved work.
The confirmation itself lives in `ogent-issues-edit--kill-query', so
every teardown path (\\[kill-buffer] included) gets the same guard."
  (interactive)
  (kill-buffer))

;;; Mode

(defvar ogent-issues-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-issues-edit-apply)
    (define-key map (kbd "C-c C-k") #'ogent-issues-edit-cancel)
    (define-key map (kbd "C-c C-r") #'ogent-issues-edit-revert-field)
    (define-key map (kbd "TAB") #'ogent-issues-edit-next-field)
    (define-key map (kbd "<backtab>") #'ogent-issues-edit-prev-field)
    (define-key map (kbd "M-n") #'ogent-issues-edit-next-field)
    (define-key map (kbd "M-p") #'ogent-issues-edit-prev-field)
    (define-key map (kbd "RET") #'ogent-issues-edit-newline-dwim)
    map)
  "Keymap for `ogent-issues-edit-mode'.")

(defun ogent-issues-edit--kill-query ()
  "Ask before killing an edit buffer that has unsaved work.
Pill edits happen inside `with-silent-modifications', so the plain
buffer-modified flag cannot be trusted here."
  (or ogent-issues-edit--kill-confirmed
      (null (ogent-issues-edit--changes))
      (yes-or-no-p (format "Discard changes to %s? "
                           (plist-get ogent-issues-edit--original :id)))))

(define-derived-mode ogent-issues-edit-mode text-mode "Issue-Edit"
  "Major mode for editing a beads issue as a structured form."
  :group 'ogent-issues
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local line-prefix "  ")
  (setq-local wrap-prefix "  ")
  (setq header-line-format '(:eval (ogent-issues-edit--header-line)))
  (add-hook 'kill-buffer-query-functions #'ogent-issues-edit--kill-query nil t)
  (ogent-ops-protect-face-properties))

;;; Entry Points

(defun ogent-issues-edit--buffer-name (id)
  "Return the edit buffer name for issue ID."
  (format "*ogent-issue-edit: %s*" id))

(defun ogent-issues-edit--create-buffer (issue &optional root)
  "Create and return an edit buffer for ISSUE plist.
ROOT is the beads project root for `default-directory'."
  (let ((buf (get-buffer-create
              (ogent-issues-edit--buffer-name (plist-get issue :id)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (ogent-issues-edit-mode)
      (when root (setq default-directory root))
      (setq ogent-issues-edit--original issue)
      (setq ogent-issues-edit--pills
            (append
             (list (cons 'priority (ogent-issues-edit--pill-original 'priority))
                   (cons 'type (ogent-issues-edit--pill-original 'type)))
             (unless (member (plist-get issue :status)
                             ogent-issues-edit--terminal-statuses)
               (list (cons 'status (ogent-issues-edit--pill-original 'status))))))
      (ogent-issues-edit--render)
      (set-buffer-modified-p nil)
      (goto-char (cdr (ogent-issues-edit--field-bounds 'title))))
    buf))

(defun ogent-issues-edit--resolve-id ()
  "Return the issue id at point in an issues or detail buffer."
  (or (and (derived-mode-p 'ogent-issues-detail-mode)
           (boundp 'ogent-issues-detail--issue)
           (plist-get ogent-issues-detail--issue :id))
      (and (fboundp 'ogent-issues--current-issue)
           (plist-get (ogent-issues--current-issue) :id))))

;;;###autoload
(defun ogent-issues-edit (&optional id)
  "Edit the issue at point (or the one with ID) in a structured form buffer.
Fetches the full issue first so long-form fields (design, acceptance
criteria, notes) are present.  If an edit buffer for the issue already
holds unsaved changes, resume it instead of clobbering them."
  (interactive)
  (require 'ogent-issues)
  (let ((id (or id (ogent-issues-edit--resolve-id))))
    (unless id
      (user-error "No issue at point"))
    ;; Resume an in-progress edit rather than discarding it.
    (let ((existing (get-buffer (ogent-issues-edit--buffer-name id))))
      (if (and existing
               (buffer-live-p existing)
               (with-current-buffer existing (ogent-issues-edit--changes)))
          (progn
            (pop-to-buffer existing '((display-buffer-same-window)))
            (message "ogent: resuming edit of %s (C-c C-k to discard)" id))
        (let ((root (ogent-issues-bd-project-root)))
          (message "ogent: fetching %s…" id)
          (ogent-issues-bd-get
           id
           (lambda (issue)
             (if (null issue)
                 (message "ogent: issue %s not found" id)
               (pop-to-buffer (ogent-issues-edit--create-buffer issue root)
                              '((display-buffer-same-window)))
               (message "ogent: editing %s" id)))
           (lambda (err)
             (message "ogent: failed to fetch %s: %s" id err))))))))

(provide 'ogent-issues-edit)

;;; ogent-issues-edit.el ends here

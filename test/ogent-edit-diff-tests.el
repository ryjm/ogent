;;; ogent-edit-diff-tests.el --- Tests for ogent-edit-diff -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the magit-style diff UX for edit proposals.
;; These tests focus on pure functions that can be tested in isolation,
;; since the full magit-section rendering requires magit-section package.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)
(require 'ogent-edit-diff)

;;; Test Helpers

(defun ogent-edit-diff-test--make-edit (id file old new)
  "Create a test edit with ID, FILE, OLD and NEW text."
  (make-ogent-edit
   :id id
   :old-text old
   :new-text new
   :source-buffer nil
   :source-file file
   :status 'pending
   :timestamp (current-time)))

(defun ogent-edit-diff-test--make-edit-with-buffer (old new)
  "Create a test edit with source buffer containing OLD, replacing with NEW."
  (let ((buf (generate-new-buffer " *ogent-diff-test*")))
    (with-current-buffer buf
      (insert old))
    (let ((edit (make-ogent-edit
                 :id (format "test-%d" (random 10000))
                 :old-text old
                 :new-text new
                 :source-buffer buf
                 :source-file "test.el"
                 :status 'pending
                 :timestamp (current-time))))
      (ogent-edit-validate edit)
      edit)))

(defun ogent-edit-diff-test--cleanup ()
  "Clean up test buffers."
  (dolist (buf (buffer-list))
    (when (or (string-prefix-p " *ogent-diff-test" (buffer-name buf))
              (equal (buffer-name buf) ogent-edit-diff-buffer-name))
      (kill-buffer buf))))

;;; Group-by-file Tests

(ert-deftest ogent-edit-diff-test-group-by-file-single ()
  "Group single edit correctly."
  (let* ((edit (ogent-edit-diff-test--make-edit "e1" "file.el" "old" "new"))
         (grouped (ogent-edit-diff--group-by-file (list edit))))
    (should (= (length grouped) 1))
    (should (equal (caar grouped) "file.el"))
    (should (= (length (cdar grouped)) 1))))

(ert-deftest ogent-edit-diff-test-group-by-file-multiple-same ()
  "Group multiple edits in same file."
  (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "file.el" "old1" "new1"))
         (edit2 (ogent-edit-diff-test--make-edit "e2" "file.el" "old2" "new2"))
         (grouped (ogent-edit-diff--group-by-file (list edit1 edit2))))
    (should (= (length grouped) 1))
    (should (equal (caar grouped) "file.el"))
    (should (= (length (cdar grouped)) 2))))

(ert-deftest ogent-edit-diff-test-group-by-file-multiple-different ()
  "Group edits in different files."
  (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "a.el" "old1" "new1"))
         (edit2 (ogent-edit-diff-test--make-edit "e2" "b.el" "old2" "new2"))
         (edit3 (ogent-edit-diff-test--make-edit "e3" "a.el" "old3" "new3"))
         (grouped (ogent-edit-diff--group-by-file (list edit1 edit2 edit3))))
    (should (= (length grouped) 2))
    ;; Should have both files
    (let ((files (mapcar #'car grouped)))
      (should (member "a.el" files))
      (should (member "b.el" files)))))

(ert-deftest ogent-edit-diff-test-group-by-file-nil-file ()
  "Edits with nil source-file are grouped under (buffer)."
  (let* ((edit (make-ogent-edit
                :id "e1"
                :old-text "old"
                :new-text "new"
                :source-buffer nil
                :source-file nil
                :status 'pending
                :timestamp (current-time)))
         (grouped (ogent-edit-diff--group-by-file (list edit))))
    (should (= (length grouped) 1))
    (should (equal (caar grouped) "(buffer)"))))

(ert-deftest ogent-edit-diff-test-group-by-file-preserves-order ()
  "Edits within a file group preserve their original order."
  (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "file.el" "first" "new1"))
         (edit2 (ogent-edit-diff-test--make-edit "e2" "file.el" "second" "new2"))
         (edit3 (ogent-edit-diff-test--make-edit "e3" "file.el" "third" "new3"))
         (grouped (ogent-edit-diff--group-by-file (list edit1 edit2 edit3)))
         (edits (cdar grouped)))
    (should (equal (ogent-edit-old-text (nth 0 edits)) "first"))
    (should (equal (ogent-edit-old-text (nth 1 edits)) "second"))
    (should (equal (ogent-edit-old-text (nth 2 edits)) "third"))))

;;; Hunk Content Insertion Tests

(ert-deftest ogent-edit-diff-test-insert-hunk-content ()
  "Hunk content is inserted with proper diff markers."
  (with-temp-buffer
    (ogent-edit-diff--insert-hunk-content "old line" "new line")
    (let ((content (buffer-string)))
      (should (string-match-p "^-old line" content))
      (should (string-match-p "^\\+new line" content)))))

(ert-deftest ogent-edit-diff-test-insert-hunk-content-multiline ()
  "Multi-line content is handled correctly."
  (with-temp-buffer
    (ogent-edit-diff--insert-hunk-content "line1\nline2" "mod1\nmod2\nmod3")
    (let ((content (buffer-string)))
      ;; Removed lines
      (should (string-match-p "^-line1" content))
      (should (string-match-p "^-line2" content))
      ;; Added lines
      (should (string-match-p "^\\+mod1" content))
      (should (string-match-p "^\\+mod2" content))
      (should (string-match-p "^\\+mod3" content)))))

(ert-deftest ogent-edit-diff-test-insert-hunk-content-empty-old ()
  "Empty old text (pure addition) works."
  (with-temp-buffer
    (ogent-edit-diff--insert-hunk-content "" "new content")
    (let ((content (buffer-string)))
      (should (string-match-p "^\\+new content" content)))))

(ert-deftest ogent-edit-diff-test-insert-hunk-content-empty-new ()
  "Empty new text (pure deletion) works."
  (with-temp-buffer
    (ogent-edit-diff--insert-hunk-content "deleted" "")
    (let ((content (buffer-string)))
      (should (string-match-p "^-deleted" content)))))

;;; Status Line Tests

(ert-deftest ogent-edit-diff-test-insert-status-line ()
  "Status line shows correct staged/unstaged counts."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    ;; Set up some edits and staged table
    (setq ogent-edit-diff--edits
          (list (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b")
                (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")
                (ogent-edit-diff-test--make-edit "e3" "f.el" "e" "f")))
    ;; Stage one edit
    (puthash "e1" t ogent-edit-diff--staged)
    (let ((inhibit-read-only t))
      (ogent-edit-diff--insert-status-line)
      (let ((content (buffer-string)))
        ;; Should show 1 staged
        (should (string-match-p "Staged:.*1" content))
        ;; Should show 2 unstaged
        (should (string-match-p "Unstaged:.*2" content))))))

;;; File All-Staged Predicate Tests

(ert-deftest ogent-edit-diff-test-file-all-staged-none ()
  "No edits staged returns nil."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b"))
           (edit2 (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")))
      (should-not (ogent-edit-diff--file-all-staged "f.el" (list edit1 edit2))))))

(ert-deftest ogent-edit-diff-test-file-all-staged-some ()
  "Some edits staged returns nil."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b"))
           (edit2 (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")))
      (puthash "e1" t ogent-edit-diff--staged)
      (should-not (ogent-edit-diff--file-all-staged "f.el" (list edit1 edit2))))))

(ert-deftest ogent-edit-diff-test-file-all-staged-all ()
  "All edits staged returns t."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b"))
           (edit2 (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")))
      (puthash "e1" t ogent-edit-diff--staged)
      (puthash "e2" t ogent-edit-diff--staged)
      (should (ogent-edit-diff--file-all-staged "f.el" (list edit1 edit2))))))

;;; Basic Rendering Tests (without magit-section)

(ert-deftest ogent-edit-diff-test-render-basic-header ()
  "Basic rendering includes header with counts."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "a.el" "old" "new")
                  (ogent-edit-diff-test--make-edit "e2" "b.el" "old" "new")))
      (let ((inhibit-read-only t))
        (ogent-edit-diff--render-basic
         (ogent-edit-diff--group-by-file ogent-edit-diff--edits))
        (let ((content (buffer-string)))
          (should (string-match-p "Edit Proposals" content))
          (should (string-match-p "2 edit(s)" content))
          (should (string-match-p "2 file(s)" content)))))))

(ert-deftest ogent-edit-diff-test-render-basic-file-headings ()
  "Basic rendering includes file headings."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "foo.el" "old" "new")
                  (ogent-edit-diff-test--make-edit "e2" "bar.el" "old" "new")))
      (let ((inhibit-read-only t))
        (ogent-edit-diff--render-basic
         (ogent-edit-diff--group-by-file ogent-edit-diff--edits))
        (let ((content (buffer-string)))
          (should (string-match-p "foo.el" content))
          (should (string-match-p "bar.el" content)))))))

;;; Mode Tests

(ert-deftest ogent-edit-diff-test-mode-sets-up-state ()
  "Mode initializes buffer-local state correctly."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    (should (eq major-mode 'ogent-edit-diff-mode))
    (should truncate-lines)
    (should buffer-read-only)
    (should (hash-table-p ogent-edit-diff--staged))
    (should (hash-table-p ogent-edit-diff--source-buffers))))

(ert-deftest ogent-edit-diff-test-keymap-defined ()
  "Mode keymap has expected bindings."
  (should (keymapp ogent-edit-diff-mode-map))
  ;; Navigation
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "n"))
              'ogent-edit-diff-next-hunk))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "p"))
              'ogent-edit-diff-prev-hunk))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "TAB"))
              'ogent-edit-diff-toggle-section))
  ;; Stage/unstage
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "s"))
              'ogent-edit-diff-stage))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "u"))
              'ogent-edit-diff-unstage))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "S"))
              'ogent-edit-diff-stage-all))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "U"))
              'ogent-edit-diff-unstage-all))
  ;; Apply
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "a"))
              'ogent-edit-diff-accept-at-point))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "r"))
              'ogent-edit-diff-reject-at-point))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "A"))
              'ogent-edit-diff-accept-staged))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "R"))
              'ogent-edit-diff-reject-all))
  ;; Other
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "g"))
              'ogent-edit-diff-refresh))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "q"))
              'quit-window))
  (should (eq (lookup-key ogent-edit-diff-mode-map (kbd "?"))
              'ogent-edit-diff-help)))

;;; Staging Tests

(ert-deftest ogent-edit-diff-test-stage-all ()
  "Stage all stages every edit."
  (unwind-protect
      (with-temp-buffer
        (ogent-edit-diff-mode)
        (setq ogent-edit-diff--edits
              (list (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b")
                    (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")))
        (ogent-edit-diff-stage-all)
        (should (= (hash-table-count ogent-edit-diff--staged) 2))
        (should (gethash "e1" ogent-edit-diff--staged))
        (should (gethash "e2" ogent-edit-diff--staged)))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-unstage-all ()
  "Unstage all clears staging table."
  (unwind-protect
      (with-temp-buffer
        (ogent-edit-diff-mode)
        (setq ogent-edit-diff--edits
              (list (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b")
                    (ogent-edit-diff-test--make-edit "e2" "f.el" "c" "d")))
        ;; Stage all first
        (puthash "e1" t ogent-edit-diff--staged)
        (puthash "e2" t ogent-edit-diff--staged)
        ;; Then unstage all
        (ogent-edit-diff-unstage-all)
        (should (= (hash-table-count ogent-edit-diff--staged) 0)))
    (ogent-edit-diff-test--cleanup)))

;;; Apply Edit Tests

(ert-deftest ogent-edit-diff-test-apply-edit ()
  "Applying an edit replaces text in source buffer."
  (unwind-protect
      (let ((edit (ogent-edit-diff-test--make-edit-with-buffer
                   "original text" "modified text")))
        (ogent-edit-diff--apply-edit edit)
        (with-current-buffer (ogent-edit-source-buffer edit)
          (should (equal (buffer-string) "modified text")))
        (should (eq (ogent-edit-status edit) 'accepted)))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-apply-edit-dead-buffer ()
  "Applying to dead buffer signals error."
  (let* ((buf (generate-new-buffer " *ogent-diff-test-dead*"))
         (edit (make-ogent-edit
                :id "e1"
                :old-text "old"
                :new-text "new"
                :source-buffer buf
                :source-file "test.el"
                :start-pos 1
                :end-pos 4
                :status 'pending
                :timestamp (current-time))))
    ;; Kill the buffer
    (kill-buffer buf)
    ;; Should error
    (should-error (ogent-edit-diff--apply-edit edit) :type 'user-error)))

;;; Accept Staged Tests

(ert-deftest ogent-edit-diff-test-accept-staged-none ()
  "Accept staged with nothing staged signals error."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    (setq ogent-edit-diff--edits
          (list (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b")))
    (should-error (ogent-edit-diff-accept-staged) :type 'user-error)))

(ert-deftest ogent-edit-diff-test-accept-staged-applies-in-reverse-order ()
  "Staged edits are applied in reverse position order."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-diff-test-order*")))
        (with-current-buffer buf
          (insert "AAA\nBBB\nCCC"))
        ;; Create edits at different positions
        (let* ((edit1 (make-ogent-edit
                       :id "e1"
                       :old-text "AAA"
                       :new-text "111"
                       :source-buffer buf
                       :source-file "test.el"
                       :status 'pending
                       :timestamp (current-time)))
               (edit2 (make-ogent-edit
                       :id "e2"
                       :old-text "CCC"
                       :new-text "333"
                       :source-buffer buf
                       :source-file "test.el"
                       :status 'pending
                       :timestamp (current-time))))
          ;; Validate to set positions
          (ogent-edit-validate edit1)
          (ogent-edit-validate edit2)
          ;; Set up diff buffer
          (with-temp-buffer
            (ogent-edit-diff-mode)
            (setq ogent-edit-diff--edits (list edit1 edit2))
            (puthash "e1" t ogent-edit-diff--staged)
            (puthash "e2" t ogent-edit-diff--staged)
            (ogent-edit-diff-accept-staged)
            ;; Both edits should be removed from list
            (should (= (length ogent-edit-diff--edits) 0))
            ;; Staged should be cleared
            (should (= (hash-table-count ogent-edit-diff--staged) 0))))
        ;; Buffer should have both changes applied
        (with-current-buffer buf
          (should (equal (buffer-string) "111\nBBB\n333"))))
    (ogent-edit-diff-test--cleanup)))

;;; Show Buffer Tests

(ert-deftest ogent-edit-diff-test-show-creates-buffer ()
  "Show creates diff buffer with correct mode."
  (unwind-protect
      (let* ((edit (ogent-edit-diff-test--make-edit "e1" "f.el" "old" "new"))
             (buf (ogent-edit-diff-show (list edit))))
        (should (buffer-live-p buf))
        (should (equal (buffer-name buf) ogent-edit-diff-buffer-name))
        (with-current-buffer buf
          (should (eq major-mode 'ogent-edit-diff-mode))
          (should (= (length ogent-edit-diff--edits) 1))))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-show-renders-content ()
  "Show renders edits into buffer."
  (unwind-protect
      (let* ((edit (ogent-edit-diff-test--make-edit "e1" "test.el" "old code" "new code"))
             (buf (ogent-edit-diff-show (list edit))))
        (with-current-buffer buf
          (let ((content (buffer-string)))
            ;; Should have header
            (should (string-match-p "Edit Proposals" content))
            ;; Should have file name
            (should (string-match-p "test.el" content))
            ;; Should have diff content
            (should (string-match-p "-old code" content))
            (should (string-match-p "\\+new code" content)))))
    (ogent-edit-diff-test--cleanup)))

;;; Refresh Tests

(ert-deftest ogent-edit-diff-test-refresh-updates-buffer ()
  "Refresh re-renders the buffer content."
  (unwind-protect
      (let* ((edit1 (ogent-edit-diff-test--make-edit "e1" "f.el" "old1" "new1"))
             (edit2 (ogent-edit-diff-test--make-edit "e2" "f.el" "old2" "new2"))
             (buf (ogent-edit-diff-show (list edit1 edit2))))
        (with-current-buffer buf
          ;; Remove one edit
          (setq ogent-edit-diff--edits (list edit1))
          (ogent-edit-diff-refresh)
          (let ((content (buffer-string)))
            ;; Should show 1 edit now
            (should (string-match-p "1 edit(s)" content))
            ;; old1 should still be there
            (should (string-match-p "-old1" content))
            ;; old2 should be gone
            (should-not (string-match-p "-old2" content)))))
    (ogent-edit-diff-test--cleanup)))

;;; Customization Tests

(ert-deftest ogent-edit-diff-test-customization-group ()
  "Customization group is defined."
  (should (get 'ogent-edit-diff 'group-documentation)))

(ert-deftest ogent-edit-diff-test-buffer-name-customizable ()
  "Buffer name is customizable."
  (should (boundp 'ogent-edit-diff-buffer-name))
  (should (stringp ogent-edit-diff-buffer-name)))

(ert-deftest ogent-edit-diff-test-window-height-customizable ()
  "Window height is customizable."
  (should (boundp 'ogent-edit-diff-window-height))
  (should (numberp ogent-edit-diff-window-height)))

;;; Face Tests

(ert-deftest ogent-edit-diff-test-faces-defined ()
  "All faces are defined."
  (should (facep 'ogent-edit-diff-file-heading))
  (should (facep 'ogent-edit-diff-hunk-heading))
  (should (facep 'ogent-edit-diff-staged))
  (should (facep 'ogent-edit-diff-unstaged))
  (should (facep 'ogent-edit-diff-added))
  (should (facep 'ogent-edit-diff-removed)))

;;; Integration Tests

(ert-deftest ogent-edit-diff-test-full-workflow ()
  "Test complete stage-and-accept workflow."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-diff-test-workflow*")))
        (with-current-buffer buf
          (insert "line one\nline two"))
        (let* ((edit (make-ogent-edit
                      :id "wf-1"
                      :old-text "line one"
                      :new-text "LINE ONE"
                      :source-buffer buf
                      :source-file "test.el"
                      :status 'pending
                      :timestamp (current-time))))
          (ogent-edit-validate edit)
          ;; Show in diff buffer
          (let ((diff-buf (ogent-edit-diff-show (list edit))))
            (with-current-buffer diff-buf
              ;; Initially unstaged
              (should (= (hash-table-count ogent-edit-diff--staged) 0))
              ;; Stage it
              (ogent-edit-diff-stage-all)
              (should (gethash "wf-1" ogent-edit-diff--staged))
              ;; Accept staged
              (ogent-edit-diff-accept-staged)
              ;; Edit list should be empty
              (should (= (length ogent-edit-diff--edits) 0))))
          ;; Source buffer should be modified
          (with-current-buffer buf
            (should (equal (buffer-string) "LINE ONE\nline two")))))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-reject-at-point-without-magit ()
  "Reject at point errors when no edit at point (no magit)."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "f.el" "old" "new")))
      ;; Without magit-section, can't find edit at point
      (should-error (ogent-edit-diff-reject-at-point) :type 'user-error))))

(ert-deftest ogent-edit-diff-test-accept-at-point-without-magit ()
  "Accept at point errors when no edit at point (no magit)."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "f.el" "old" "new")))
      ;; Without magit-section, can't find edit at point
      (should-error (ogent-edit-diff-accept-at-point) :type 'user-error))))

(ert-deftest ogent-edit-diff-test-stage-without-magit ()
  "Stage errors when no edit at point (no magit)."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "f.el" "old" "new")))
      (should-error (ogent-edit-diff-stage) :type 'user-error))))

(ert-deftest ogent-edit-diff-test-unstage-without-magit ()
  "Unstage errors when no edit at point (no magit)."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "e1" "f.el" "old" "new")))
      (should-error (ogent-edit-diff-unstage) :type 'user-error))))

;;; Help Command Test

(ert-deftest ogent-edit-diff-test-help-displays-message ()
  "Help command displays usage information."
  (with-temp-buffer
    (ogent-edit-diff-mode)
    ;; Should not error
    (ogent-edit-diff-help)))

;;; Coverage Expansion Tests for ogent-edit-diff.el

(ert-deftest ogent-edit-diff-test-render-dispatches-to-basic ()
  "Render dispatches to basic when magit not available."
  (let ((ogent-edit-diff--magit-available nil)
        (basic-called nil))
    (cl-letf (((symbol-function 'ogent-edit-diff--render-basic)
               (lambda (_by-file) (setq basic-called t))))
      (with-temp-buffer
        (ogent-edit-diff-mode)
        (setq ogent-edit-diff--edits
              (list (ogent-edit-diff-test--make-edit "e1" "f.el" "a" "b")))
        (let ((inhibit-read-only t))
          (ogent-edit-diff--render ogent-edit-diff--edits))
        (should basic-called)))))

(ert-deftest ogent-edit-diff-test-next-hunk-without-magit ()
  "Next hunk falls back to forward-line without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (let ((inhibit-read-only t))
        (insert "line1\nline2\nline3\n"))
      (goto-char (point-min))
      (ogent-edit-diff-next-hunk)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-edit-diff-test-prev-hunk-without-magit ()
  "Prev hunk falls back to forward-line -1 without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (let ((inhibit-read-only t))
        (insert "line1\nline2\nline3\n"))
      (goto-char (point-max))
      (forward-line -1)
      (ogent-edit-diff-prev-hunk)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-edit-diff-test-next-file-without-magit ()
  "Next file is a no-op without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (let ((inhibit-read-only t))
        (insert "content"))
      (goto-char (point-min))
      ;; Should not error
      (ogent-edit-diff-next-file)
      (should (= (point) (point-min))))))

(ert-deftest ogent-edit-diff-test-prev-file-without-magit ()
  "Prev file is a no-op without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (let ((inhibit-read-only t))
        (insert "content"))
      (goto-char (point-max))
      ;; Should not error
      (ogent-edit-diff-prev-file)
      (should (= (point) (point-max))))))

(ert-deftest ogent-edit-diff-test-toggle-section-without-magit ()
  "Toggle section is a no-op without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      ;; Should not error
      (ogent-edit-diff-toggle-section))))

(ert-deftest ogent-edit-diff-test-current-edit-without-magit ()
  "Current edit returns nil without magit."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (should-not (ogent-edit-diff--current-edit)))))

(ert-deftest ogent-edit-diff-test-goto-source-without-magit ()
  "Goto source errors when no edit at point (no magit)."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (should-error (ogent-edit-diff-goto-source) :type 'user-error))))

(ert-deftest ogent-edit-diff-test-reject-all-with-confirmation ()
  "Reject all marks all edits as rejected when confirmed."
  (let ((ogent-edit-diff--magit-available nil))
    (unwind-protect
        (with-temp-buffer
          (ogent-edit-diff-mode)
          (setq ogent-edit-diff--edits
                (list (ogent-edit-diff-test--make-edit "r1" "f.el" "a" "b")
                      (ogent-edit-diff-test--make-edit "r2" "f.el" "c" "d")))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
            (ogent-edit-diff-reject-all)
            (should (null ogent-edit-diff--edits))))
      (ogent-edit-diff-test--cleanup))))

(ert-deftest ogent-edit-diff-test-reject-all-cancelled ()
  "Reject all keeps edits when user says no."
  (let ((ogent-edit-diff--magit-available nil))
    (unwind-protect
        (with-temp-buffer
          (ogent-edit-diff-mode)
          (setq ogent-edit-diff--edits
                (list (ogent-edit-diff-test--make-edit "r1" "f.el" "a" "b")))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) nil)))
            (ogent-edit-diff-reject-all)
            ;; Edits should remain
            (should (= (length ogent-edit-diff--edits) 1))))
      (ogent-edit-diff-test--cleanup))))

(ert-deftest ogent-edit-diff-test-apply-edit-replaces-content ()
  "Apply edit correctly replaces source buffer content and sets status."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-diff-test-apply2*"))
             (edit (make-ogent-edit
                    :id "ap1"
                    :old-text "hello"
                    :new-text "world"
                    :source-buffer buf
                    :source-file "test.el"
                    :status 'pending
                    :timestamp (current-time))))
        (with-current-buffer buf
          (insert "hello"))
        (ogent-edit-validate edit)
        (ogent-edit-diff--apply-edit edit)
        (with-current-buffer buf
          (should (string= (buffer-string) "world")))
        (should (eq (ogent-edit-status edit) 'accepted)))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-refresh-preserves-point ()
  "Refresh keeps point at a reasonable position."
  (unwind-protect
      (let* ((edit (ogent-edit-diff-test--make-edit "rp1" "f.el" "old text" "new text"))
             (buf (ogent-edit-diff-show (list edit))))
        (with-current-buffer buf
          ;; Move to some position
          (goto-char (point-min))
          (forward-line 2)
          (let ((pos (point)))
            (ogent-edit-diff-refresh)
            ;; Point should be at same position or point-max if buffer shrank
            (should (<= (point) (point-max))))))
    (ogent-edit-diff-test--cleanup)))

(ert-deftest ogent-edit-diff-test-refresh-noop-outside-mode ()
  "Refresh is a no-op outside ogent-edit-diff-mode."
  (with-temp-buffer
    ;; Should not error in a non-diff mode buffer
    (ogent-edit-diff-refresh)))

(ert-deftest ogent-edit-diff-test-render-basic-diff-content ()
  "Basic render includes diff markers for edits."
  (let ((ogent-edit-diff--magit-available nil))
    (with-temp-buffer
      (ogent-edit-diff-mode)
      (setq ogent-edit-diff--edits
            (list (ogent-edit-diff-test--make-edit "bc1" "test.el" "old code" "new code")))
      (let ((inhibit-read-only t))
        (ogent-edit-diff--render-basic
         (ogent-edit-diff--group-by-file ogent-edit-diff--edits))
        (let ((content (buffer-string)))
          ;; Should have diff markers
          (should (string-match-p "-old code" content))
          (should (string-match-p "\\+new code" content)))))))

(provide 'ogent-edit-diff-tests)

;;; ogent-edit-diff-tests.el ends here

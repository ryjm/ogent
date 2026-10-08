;;; ogent-edit-review-tests.el --- Source-safe multi-edit review tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise recoverable rejection, staged preflight, resolution and undo.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-edit-diff)

(defun ogent-edit-review-tests--edit (buffer id old new)
  "Return a validated edit in BUFFER with ID replacing OLD by NEW."
  (let ((edit (make-ogent-edit :id id :old-text old :new-text new
                               :source-buffer buffer :status 'pending)))
    (ogent-edit-validate edit)
    edit))

(ert-deftest ogent-edit-review-stale-proposals-remain-recoverable ()
  "Reject missing, duplicate and killed source without resolving proposals."
  (dolist (changed '("missing" "old old"))
    (with-temp-buffer
      (insert "old")
      (let ((edit (ogent-edit-review-tests--edit (current-buffer) "e" "old" "new"))
            (resolutions 0)
            (ogent-edit-resolved-hook nil))
        (setq ogent-edit-resolved-hook (list (lambda (_) (cl-incf resolutions))))
        (erase-buffer) (insert changed)
        ;; Ensure a duplicate is stale even though one occurrence stays at 1.
        (setf (ogent-edit-start-pos edit) 2 (ogent-edit-end-pos edit) 5)
        (should-error (ogent-edit-diff--apply-edit edit) :type 'user-error)
        (should (equal (buffer-string) changed))
        (should (eq (ogent-edit-status edit) 'pending))
        (should (= resolutions 0)))))
  (let* ((buffer (generate-new-buffer " *review-killed*"))
         (edit (with-current-buffer buffer
                 (insert "old")
                 (ogent-edit-review-tests--edit buffer "e" "old" "new"))))
    (kill-buffer buffer)
    (should-error (ogent-edit-diff--apply-edit edit) :type 'user-error)
    (should (eq (ogent-edit-status edit) 'pending))))

(ert-deftest ogent-edit-review-staged-overlap-is-atomic ()
  "Keep proposals and staging when a staged batch contains overlapping edits."
  (with-temp-buffer
    (insert "abcdef")
    (let* ((a (ogent-edit-review-tests--edit (current-buffer) "a" "abc" "A"))
           (b (ogent-edit-review-tests--edit (current-buffer) "b" "bcd" "B"))
           (ogent-edit-diff--edits (list a b))
           (ogent-edit-diff--staged (make-hash-table :test #'equal)))
      (puthash "a" t ogent-edit-diff--staged)
      (puthash "b" t ogent-edit-diff--staged)
      (should-error (ogent-edit-diff-accept-staged) :type 'user-error)
      (should (equal (buffer-string) "abcdef"))
      (should (= (hash-table-count ogent-edit-diff--staged) 2))
      (should (eq (ogent-edit-status a) 'pending)))))

(ert-deftest ogent-edit-review-staged-narrowed-source-and-undo ()
  "Apply separated edits in a narrowed source and undo the batch together."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "left middle right")
    (let* ((a (ogent-edit-review-tests--edit (current-buffer) "a" "left" "LEFT"))
           (b (ogent-edit-review-tests--edit (current-buffer) "b" "right" "RIGHT"))
           (ogent-edit-diff--edits (list a b))
           (ogent-edit-diff--staged (make-hash-table :test #'equal))
           (resolutions nil)
           (ogent-edit-resolved-hook nil))
      (setq ogent-edit-resolved-hook (list (lambda (edit) (push (ogent-edit-id edit) resolutions))))
      (setq ogent-edit--pending-edits (list a b))
      (setq buffer-undo-list nil)
      (puthash "a" t ogent-edit-diff--staged) (puthash "b" t ogent-edit-diff--staged)
      (narrow-to-region 6 12)
      (ogent-edit-diff-accept-staged)
      (widen)
      (should (equal (buffer-string) "LEFT middle RIGHT"))
      (should-not ogent-edit--pending-edits)
      (should (= (length resolutions) 2))
      (undo-boundary)
      (undo 1)
      (should (equal (buffer-string) "left middle right")))))

(ert-deftest ogent-edit-review-reject-once ()
  "Notify rejection once and remove the proposal from source tracking."
  (with-temp-buffer
    (insert "old")
    (let* ((edit (ogent-edit-review-tests--edit (current-buffer) "e" "old" "new"))
           (ogent-edit-diff--edits (list edit))
           (ogent-edit-diff--staged (make-hash-table :test #'equal))
           (ogent-edit-resolved-hook nil) (count 0))
      (setq ogent-edit--pending-edits (list edit)
            ogent-edit-resolved-hook (list (lambda (_) (cl-incf count))))
      (cl-letf (((symbol-function 'ogent-edit-diff--current-edit) (lambda () edit)))
        (ogent-edit-diff-reject-at-point))
      (ogent-edit-diff--resolve edit 'rejected)
      (should (= count 1))
      (should-not ogent-edit--pending-edits)
      (should (equal (buffer-string) "old")))))

(provide 'ogent-edit-review-tests)
;;; ogent-edit-review-tests.el ends here

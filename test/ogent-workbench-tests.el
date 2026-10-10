;;; ogent-workbench-tests.el --- Passage feedback regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise persistent anchors, bounded revisions and acceptance without inference.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-workbench)
(require 'ogent-ui-workbench)

(defmacro ogent-workbench-tests--with-source (text &rest body)
  "Run BODY with a source containing TEXT and an isolated review store."
  (declare (indent 1) (debug t))
  `(let* ((dir (ogent-test--provision-store-directory 'workbench))
          (ogent-workbench-file (expand-file-name "review.org" dir))
          (ogent-workbench--runs (make-hash-table :test #'equal))
          (ogent-workbench--edits (make-hash-table :test #'equal))
          (source (generate-new-buffer " *workbench-source*")))
     (unwind-protect
         (with-current-buffer source
           (insert ,text)
           ,@body)
       (kill-buffer source)
       (when-let ((store (find-buffer-visiting ogent-workbench-file)))
         (kill-buffer store)))))

(ert-deftest ogent-workbench-reloads-exact-text-and-comments ()
  "Org comments preserve escaped content, whitespace and source identity."
  (ogent-workbench-tests--with-source "First\n#+end_src\nLast\n"
    (let ((record (ogent-workbench--add 1 (point-max) "Make this clearer.\nWhy?" 'comment)))
      (setq ogent-workbench--records nil)
      (ogent-workbench--load)
      (should (= 1 (length ogent-workbench--records)))
      (should (equal (plist-get record :text)
		     (plist-get (car ogent-workbench--records) :text)))
      (should (equal "Make this clearer.\nWhy?"
		     (plist-get (car ogent-workbench--records) :note))))))

(ert-deftest ogent-workbench-anchors-follow-insertions-but-reject-changes ()
  "Inserting elsewhere retains anchors; changing the target blocks revision."
  (ogent-workbench-tests--with-source "First.\nSecond.\n"
    (let ((record (ogent-workbench--add 8 15 "Improve." 'comment)))
      (goto-char 1) (insert "Intro.\n")
      (should (equal (ogent-workbench--anchor record) '(15 . 22)))
      (goto-char 15) (delete-char 1) (insert "X")
      (should-error (ogent-workbench--anchor record) :type 'user-error)
      (should (equal "open" (plist-get record :status))))))

(ert-deftest ogent-workbench-reopens-pending-feedback-after-restart ()
  "Durable feedback can be revised when its in-memory proposal is gone."
  (ogent-workbench-tests--with-source "Original."
    (let ((record (ogent-workbench--add 1 10 "Try again." 'comment)))
      (plist-put record :status "proposed")
      (plist-put record :draft "Proposed.")
      (ogent-workbench--write record)
      (setq ogent-workbench--records nil)
      (ogent-workbench--load)
      (should (equal "open" (plist-get (car ogent-workbench--records) :status)))
      (should (equal "Proposed." (plist-get (car ogent-workbench--records) :draft))))))

(ert-deftest ogent-workbench-kept-and-overlapping-passages-stay-protected ()
  "A keep marker blocks overlapping comments and invalid empty selections."
  (ogent-workbench-tests--with-source "Keep me. Change me."
    (ogent-workbench-keep 1 9)
    (should-error (ogent-workbench--add 5 14 "Change." 'comment) :type 'user-error)
    (should-error (ogent-workbench--add 10 10 "Empty." 'comment) :type 'user-error)
    (should (= 1 (length ogent-workbench--records)))))

(ert-deftest ogent-workbench-batch-review-applies-only-marked-passages ()
  "One coherent batch proposes two replacements and preserves other text."
  (ogent-workbench-tests--with-source "Old intro.\nKeep this.\nOld ending.\n"
    (let* ((first (ogent-workbench--add 1 11 "Shorten." 'comment))
	   (second (ogent-workbench--add 23 34 "Be concrete." 'comment))
	   (run (list :id "batch" :buffer source :records (list first second)))
	   (response (json-serialize
		      (vector (list :id (plist-get second :id) :text "New ending.")
			      (list :id (plist-get first :id) :text "New intro."))))
	   (edits (ogent-workbench--proposals response run)))
      (should (= 2 (length edits)))
      (should (string-match-p "Old intro" (buffer-string)))
      (dolist (edit edits)
	(puthash (ogent-edit-id edit)
		 (if (= (ogent-edit-start-pos edit) 1) first second)
		 ogent-workbench--edits))
      ;; The real proposal application invokes the actual resolution hook.
      (dolist (edit (sort edits (lambda (a b) (> (ogent-edit-start-pos a)
						 (ogent-edit-start-pos b)))))
	(ogent-edit-diff--apply-edit edit))
      (should (equal "New intro.\nKeep this.\nNew ending.\n" (buffer-string)))
      (should (equal "kept" (plist-get first :status)))
      (should (equal "kept" (plist-get second :status)))
      (should-error (ogent-workbench--add 1 5 "Change again." 'comment)
		    :type 'user-error))))

(ert-deftest ogent-workbench-malformed-batches-preserve-all-source ()
  "Unknown IDs, repeated IDs, missing entries and stale anchors mutate nothing."
  (ogent-workbench-tests--with-source "Old intro."
    (let* ((record (ogent-workbench--add 1 11 "Improve." 'comment))
	   (run (list :id "batch" :buffer source :records (list record))))
      (dolist (response (list "not JSON" "[]" "[{\"id\":\"other\",\"text\":\"x\"}]"
			      (json-serialize (vector (list :id (plist-get record :id)
							    :text 42)))))
	(should-error (ogent-workbench--proposals response run)))
      (should (equal "Old intro." (buffer-string)))
      (goto-char 1) (insert "New ")
      (delete-region 5 (point-max))
      (should-error
       (ogent-workbench--proposals
	(json-serialize (vector (list :id (plist-get record :id) :text "Replacement"))) run)))))

(ert-deftest ogent-workbench-rejecting-a-proposal-reopens-comment ()
  "Rejecting a revision leaves original text available for the next attempt."
  (ogent-workbench-tests--with-source "Original."
    (let* ((record (ogent-workbench--add 1 10 "Improve." 'comment))
	   (edit (make-ogent-edit :id "proposal" :source-buffer source
				  :start-pos 1 :end-pos 10 :old-text "Original."
				  :new-text "New." :status 'pending)))
      (plist-put record :status "proposed")
      (puthash "proposal" record ogent-workbench--edits)
      (ogent-edit-diff--resolve edit 'rejected)
      (should (equal "open" (plist-get record :status)))
      (should (equal "Original." (buffer-string))))))

(ert-deftest ogent-workbench-plain-emacs-review-needs-no-magit ()
  "Actual n/a keys select and accept proposals in the built-in diff fallback."
  (save-window-excursion
    (ogent-workbench-tests--with-source "Original."
      (let* ((ogent-edit-diff--magit-available nil)
	     (record (ogent-workbench--add 1 10 "Improve." 'comment))
	     (edit (make-ogent-edit :id "plain" :source-buffer source
				    :source-file "draft.org" :start-pos 1 :end-pos 10
				    :old-text "Original." :new-text "Improved." :status 'pending)))
	(puthash "plain" record ogent-workbench--edits)
	(pop-to-buffer (ogent-edit-diff-show (list edit)))
        (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
          (call-interactively (key-binding (kbd "n")))
          (call-interactively (key-binding (kbd "a"))))
	(should (equal "Improved." (with-current-buffer source (buffer-string))))
	(should (equal "kept" (plist-get record :status)))
	(kill-buffer (current-buffer))))))

(ert-deftest ogent-workbench-comments-on-proposals-retain-proposed-draft ()
  "Feedback on a pending hunk addresses the proposed text without applying it."
  (save-window-excursion
    (ogent-workbench-tests--with-source "Original."
      (let* ((ogent-edit-diff--magit-available nil)
             (edit (make-ogent-edit :id "draft" :source-buffer source
                                    :source-file "draft.org" :start-pos 1 :end-pos 10
                                    :old-text "Original." :new-text "Proposed." :status 'pending)))
        (pop-to-buffer (ogent-edit-diff-show (list edit)))
        (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
          (call-interactively (key-binding (kbd "n"))))
        (ogent-workbench-comment "Make the proposal clearer.")
        (with-current-buffer source
          (should (equal "Original." (buffer-string)))
          (should (equal "Proposed." (plist-get (car ogent-workbench--records) :draft))))
        (kill-buffer (current-buffer))))))

(ert-deftest ogent-workbench-refines-feedback-on-its-own-pending-proposal ()
  "A second comment refines the existing passage instead of overlapping it."
  (save-window-excursion
    (ogent-workbench-tests--with-source "Original."
      (let* ((ogent-edit-diff--magit-available nil)
             (record (ogent-workbench--add 1 10 "Improve." 'comment))
             (edit (make-ogent-edit :id "follow-up" :source-buffer source
                                    :start-pos 1 :end-pos 10 :old-text "Original."
                                    :new-text "Draft." :status 'pending)))
        (plist-put record :status "proposed")
        (puthash "follow-up" record ogent-workbench--edits)
        (pop-to-buffer (ogent-edit-diff-show (list edit)))
        (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
          (call-interactively (key-binding (kbd "n"))))
        (ogent-workbench-comment "Be more concrete.")
        (with-current-buffer source
          (should (= 1 (length ogent-workbench--records)))
          (should (equal "Original." (buffer-string)))
          (should (equal "open" (plist-get record :status)))
          (should (string-match-p "Be more concrete" (plist-get record :note)))
          (should (equal "Draft." (plist-get record :draft))))
        (kill-buffer (current-buffer))))))

(ert-deftest ogent-workbench-inflight-revision-preserves-newly-accepted-text ()
  "Late responses cannot revise feedback changed or accepted after dispatch."
  (ogent-workbench-tests--with-source "Original."
    (let* ((record (ogent-workbench--add 1 10 "Improve." 'comment))
           (id (plist-get record :id))
           (run (list :id "inflight" :buffer source :records (list record)
                      :snapshot (list (cons id (list "Original." "Improve." nil)))))
           (response (json-serialize (vector (list :id id :text "Late draft."))))
           (edit (make-ogent-edit :id "accepted" :source-buffer source
                                  :start-pos 1 :end-pos 10 :old-text "Original."
                                  :new-text "Original." :status 'accepted)))
      (plist-put record :note "A newer direction.")
      (should-error (ogent-workbench--proposals response run) :type 'user-error)
      (plist-put record :note "Improve.")
      (puthash "accepted" record ogent-workbench--edits)
      (ogent-workbench--resolved edit)
      (should-error (ogent-workbench--proposals response run) :type 'user-error)
      (should (equal "kept" (plist-get record :status)))
      (should (equal "Original." (buffer-string))))))

(ert-deftest ogent-workbench-reader-preserves-comment-and-visits-selection ()
  "Keyboard review and refresh retain the selected source passage."
  (save-window-excursion
    (ogent-workbench-tests--with-source "First. Second."
      (ogent-workbench--add 1 7 "Shorten this." 'comment)
      (ogent-workbench--add 8 15 "Explain this." 'comment)
      (switch-to-buffer source)
      (ogent-workbench-comments)
      (unwind-protect
	  (progn
            (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
              (call-interactively (key-binding (kbd "n"))))
	    (let ((selected (get-text-property (point) 'ogent-comment)))
	      (should selected)
              (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                (call-interactively (key-binding (kbd "g"))))
	      (should (eq selected (get-text-property (point) 'ogent-comment)))
              (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                (call-interactively (key-binding (kbd "RET"))))
	      (should (eq (current-buffer) source))
	      (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
			     (plist-get selected :text)))))
	(when-let ((reader (get-buffer (format "*ogent-review:%s*" (buffer-name source)))))
	  (kill-buffer reader))))))

(provide 'ogent-workbench-tests)
;;; ogent-workbench-tests.el ends here

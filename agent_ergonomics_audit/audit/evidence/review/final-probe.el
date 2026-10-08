;;; final-probe.el --- Final independent review probes -*- lexical-binding: t; -*-

(load "/work/agent_ergonomics_audit/audit/evidence/review/verification-probe.el" nil nil t)

;; The named contract preserves actual external key spellings while accepting
;; unique aliases, including a schema declaring both spellings.
(let ((single '(:name custom :args ((:name "file-path" :type string))))
      (distinct '(:name custom :args ((:name "file-path" :type string)
                                      (:name "file_path" :type string)))))
  (unless (equal '("a") (ogent-tool-contract-values single '(:file-path "a")))
    (error "Exact declared spelling failed"))
  (unless (equal '("b") (ogent-tool-contract-values single '(:file_path "b")))
    (error "Unambiguous alias failed"))
  (unless (equal '("a" "b") (ogent-tool-contract-values distinct '(:file-path "a" :file_path "b")))
    (error "Distinct exact fields collapsed"))
  (ogent-review-current-print "declared-argument-spellings" "exact, alias, distinct fields pass"))

;; Exact edit context must reject mismatched case before a file write or diff.
(let* ((file (expand-file-name "final-exact-case.txt" ogent-review-current-root))
       (case-fold-search t))
  (with-temp-file file (insert "same SAME\n"))
  (dolist (run (list (lambda () (ogent-tool--edit-file file "Same" "new"))
                    (lambda () (ogent-ui--generate-diff file nil "Same" "new"))))
    (unless (condition-case nil (progn (funcall run) nil) (user-error t))
      (error "Mismatched case reached edit or diff")))
  (with-temp-buffer
    (insert "same SAME\n")
    (unless (and (not (ogent-ui--tool-edit-occurrences (current-buffer) "Same"))
                 (= 1 (length (ogent-ui--tool-edit-occurrences (current-buffer) "same"))))
      (error "Inline occurrence case handling failed")))
  (ogent-tool--edit-file file "same" "new")
  (unless (equal "new SAME\n"
                 (with-temp-buffer (insert-file-contents file) (buffer-string)))
    (error "Exact edit altered differently cased neighbor"))
  (ogent-review-current-print "exact-edit-case" "direct, default, inline pass"))

(ogent-review-current-print "final-review-verdict" "CLEAN for covered behavior")

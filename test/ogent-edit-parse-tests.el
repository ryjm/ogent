;;; ogent-edit-parse-tests.el --- Tests for ogent-edit-parse -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)

;;; Parsing Tests

(ert-deftest ogent-edit-parse/single-block ()
  "Parse a single SEARCH/REPLACE block from response."
  (let* ((response "Here is the fix:

<<<<<<< SEARCH
(defun old-fn ()
  nil)
=======
(defun new-fn ()
  t)
>>>>>>> REPLACE

Done.")
         (source-buffer (get-buffer-create "*parse-single*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (let ((edit (car edits)))
            (should (string= (ogent-edit-old-text edit)
                             "(defun old-fn ()\n  nil)"))
            (should (string= (ogent-edit-new-text edit)
                             "(defun new-fn ()\n  t)"))
            (should (eq (ogent-edit-status edit) 'pending))
            (should (eq (ogent-edit-source-buffer edit) source-buffer))
            (should (stringp (ogent-edit-id edit)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/multiple-blocks ()
  "Parse multiple SEARCH/REPLACE blocks from response."
  (let* ((response "Multiple changes:

<<<<<<< SEARCH
(setq a 1)
=======
(setq a 10)
>>>>>>> REPLACE

And another:

<<<<<<< SEARCH
(setq b 2)
=======
(setq b 20)
>>>>>>> REPLACE

<<<<<<< SEARCH
(setq c 3)
=======
(setq c 30)
>>>>>>> REPLACE
")
         (source-buffer (get-buffer-create "*parse-multi*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 3))
          (should (string= (ogent-edit-old-text (nth 0 edits)) "(setq a 1)"))
          (should (string= (ogent-edit-new-text (nth 0 edits)) "(setq a 10)"))
          (should (string= (ogent-edit-old-text (nth 1 edits)) "(setq b 2)"))
          (should (string= (ogent-edit-new-text (nth 1 edits)) "(setq b 20)"))
          (should (string= (ogent-edit-old-text (nth 2 edits)) "(setq c 3)"))
          (should (string= (ogent-edit-new-text (nth 2 edits)) "(setq c 30)")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/no-blocks ()
  "Parse response with no edit blocks returns empty list."
  (let* ((response "I cannot make that change because the code structure doesn't allow it.")
         (source-buffer (get-buffer-create "*parse-none*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (should (= (length edits) 0))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/malformed-no-separator ()
  "Malformed block without separator is skipped."
  (let* ((response "<<<<<<< SEARCH
old code
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-malformed1*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (should (= (length edits) 0))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/malformed-no-end ()
  "Malformed block without end marker is skipped."
  (let* ((response "<<<<<<< SEARCH
old code
=======
new code")
         (source-buffer (get-buffer-create "*parse-malformed2*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (should (= (length edits) 0))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/preserves-whitespace ()
  "Parser preserves internal whitespace in code blocks."
  (let* ((response "<<<<<<< SEARCH
  indented line 1
    more indented
  back to normal
=======
  new indented 1
    new more indented
  new back
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-whitespace*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string-match-p "^  indented" (ogent-edit-old-text (car edits))))
          (should (string-match-p "^    more" (ogent-edit-old-text (car edits)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/empty-old-text ()
  "Parser handles empty old text (pure insertion scenario)."
  (let* ((response "<<<<<<< SEARCH

=======
new content
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-empty-old*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) ""))
          (should (string= (ogent-edit-new-text (car edits)) "new content")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/empty-new-text ()
  "Parser handles empty new text (pure deletion scenario)."
  (let* ((response "<<<<<<< SEARCH
old content
=======

>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-empty-new*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) "old content"))
          (should (string= (ogent-edit-new-text (car edits)) "")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/source-file-captured ()
  "Parser captures source file from source buffer."
  (with-temp-buffer
    (setq buffer-file-name "/nonexistent/ogent-parse-source.el")
    (unwind-protect
        (let* ((response "<<<<<<< SEARCH
old
=======
new
>>>>>>> REPLACE")
               (edits (ogent-edit-parse-response response (current-buffer))))
          (should (= (length edits) 1))
          (should (string= (ogent-edit-source-file (car edits))
                           "/nonexistent/ogent-parse-source.el")))
      (setq buffer-file-name nil))))

(ert-deftest ogent-edit-parse/nil-source-file-for-temp-buffer ()
  "Parser sets nil source-file for non-file buffers."
  (let* ((source-buffer (get-buffer-create "*temp-no-file*"))
         (response "<<<<<<< SEARCH
old
=======
new
>>>>>>> REPLACE")
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should-not (ogent-edit-source-file (car edits))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/id-counter-increments ()
  "Parser generates sequential IDs."
  (ogent-edit--reset-counter)
  (let* ((response "<<<<<<< SEARCH
a
=======
b
>>>>>>> REPLACE

<<<<<<< SEARCH
c
=======
d
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-ids*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (string= (ogent-edit-id (nth 0 edits)) "ogent-edit-001"))
          (should (string= (ogent-edit-id (nth 1 edits)) "ogent-edit-002")))
      (kill-buffer source-buffer))))

;;; Text Normalization Tests

(ert-deftest ogent-edit-parse/normalize-trailing-newline ()
  "Normalize removes single trailing newline."
  (should (string= (ogent-edit--normalize-text "hello\n") "hello"))
  (should (string= (ogent-edit--normalize-text "line1\nline2\n") "line1\nline2")))

(ert-deftest ogent-edit-parse/normalize-no-trailing-newline ()
  "Normalize preserves text without trailing newline."
  (should (string= (ogent-edit--normalize-text "hello") "hello"))
  (should (string= (ogent-edit--normalize-text "line1\nline2") "line1\nline2")))

(ert-deftest ogent-edit-parse/normalize-nil-text ()
  "Normalize handles nil gracefully."
  (should-not (ogent-edit--normalize-text nil)))

(ert-deftest ogent-edit-parse/normalize-empty-string ()
  "Normalize handles empty string."
  (should (string= (ogent-edit--normalize-text "") "")))

(ert-deftest ogent-edit-parse/normalize-only-newline ()
  "Normalize handles string that is only newline."
  (should (string= (ogent-edit--normalize-text "\n") "")))

;;; Validation Tests

(ert-deftest ogent-edit-parse/validate-unique-match ()
  "Validation succeeds for unique match."
  (let ((source-buffer (get-buffer-create "*validate-unique*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(defun foo () nil)\n(defun bar () t)"))
          (let ((edit (make-ogent-edit
                       :id "val-001"
                       :old-text "(defun foo () nil)"
                       :new-text "(defun foo () t)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-start-pos edit))
            (should (ogent-edit-end-pos edit))
            (should (= (ogent-edit-start-pos edit) 1))
            (should (= (ogent-edit-end-pos edit) 19))
            (should-not (ogent-edit-error-p edit))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/validate-not-found ()
  "Validation fails when text not found."
  (let ((source-buffer (get-buffer-create "*validate-not-found*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(defun bar () t)"))
          (let ((edit (make-ogent-edit
                       :id "val-002"
                       :old-text "(defun nonexistent () nil)"
                       :new-text "(defun nonexistent () t)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-error-p edit))
            (should (string-match-p "not found" (ogent-edit-error-message edit)))
            (should-not (ogent-edit-start-pos edit))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/validate-multiple-matches ()
  "Validation fails when text matches multiple times."
  (let ((source-buffer (get-buffer-create "*validate-multi*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(setq x 1)\n(setq y 2)\n(setq x 1)"))
          (let ((edit (make-ogent-edit
                       :id "val-003"
                       :old-text "(setq x 1)"
                       :new-text "(setq x 10)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-error-p edit))
            (should (string-match-p "2 locations" (ogent-edit-error-message edit)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/validate-dead-buffer ()
  "Validation handles dead source buffer gracefully."
  (let* ((source-buffer (get-buffer-create "*validate-dead*"))
         (edit (make-ogent-edit
                :id "val-004"
                :old-text "test"
                :new-text "test2"
                :source-buffer source-buffer
                :status 'pending)))
    (kill-buffer source-buffer)
    ;; Should not error
    (ogent-edit-validate edit)
    ;; No positions set when buffer is dead
    (should-not (ogent-edit-start-pos edit))))

(ert-deftest ogent-edit-parse/validate-all-batch ()
  "Validate all processes multiple edits."
  (let ((source-buffer (get-buffer-create "*validate-all*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(setq a 1)\n(setq b 2)\n(setq c 3)"))
          (let ((edits (list
                        (make-ogent-edit
                         :id "batch-001"
                         :old-text "(setq a 1)"
                         :new-text "(setq a 10)"
                         :source-buffer source-buffer
                         :status 'pending)
                        (make-ogent-edit
                         :id "batch-002"
                         :old-text "(setq b 2)"
                         :new-text "(setq b 20)"
                         :source-buffer source-buffer
                         :status 'pending)
                        (make-ogent-edit
                         :id "batch-003"
                         :old-text "(setq d 4)"  ; Does not exist
                         :new-text "(setq d 40)"
                         :source-buffer source-buffer
                         :status 'pending))))
            (setq edits (ogent-edit-validate-all edits))
            ;; First two should validate
            (should (ogent-edit-valid-p (nth 0 edits)))
            (should (ogent-edit-valid-p (nth 1 edits)))
            ;; Third should error
            (should (ogent-edit-error-p (nth 2 edits)))))
      (kill-buffer source-buffer))))

;;; Utility Function Tests

(ert-deftest ogent-edit-parse/pending-p ()
  "Pending predicate works correctly."
  (let ((pending-edit (make-ogent-edit :status 'pending))
        (applied-edit (make-ogent-edit :status 'applied))
        (error-edit (make-ogent-edit :status 'error)))
    (should (ogent-edit-pending-p pending-edit))
    (should-not (ogent-edit-pending-p applied-edit))
    (should-not (ogent-edit-pending-p error-edit))))

(ert-deftest ogent-edit-parse/error-p ()
  "Error predicate works correctly."
  (let ((error-edit (make-ogent-edit :status 'error))
        (pending-edit (make-ogent-edit :status 'pending))
        (applied-edit (make-ogent-edit :status 'applied)))
    (should (ogent-edit-error-p error-edit))
    (should-not (ogent-edit-error-p pending-edit))
    (should-not (ogent-edit-error-p applied-edit))))

(ert-deftest ogent-edit-parse/valid-p ()
  "Valid predicate requires positions and no error."
  (let ((valid-edit (make-ogent-edit
                     :status 'pending
                     :start-pos 1
                     :end-pos 10))
        (no-positions (make-ogent-edit
                       :status 'pending))
        (error-with-positions (make-ogent-edit
                               :status 'error
                               :start-pos 1
                               :end-pos 10)))
    (should (ogent-edit-valid-p valid-edit))
    (should-not (ogent-edit-valid-p no-positions))
    (should-not (ogent-edit-valid-p error-with-positions))))

(ert-deftest ogent-edit-parse/filter-valid ()
  "Filter valid returns only valid edits."
  (let ((edits (list
                (make-ogent-edit :id "v1" :status 'pending :start-pos 1 :end-pos 5)
                (make-ogent-edit :id "v2" :status 'error)
                (make-ogent-edit :id "v3" :status 'pending :start-pos 10 :end-pos 20)
                (make-ogent-edit :id "v4" :status 'pending))))
    (let ((valid (ogent-edit-filter-valid edits)))
      (should (= (length valid) 2))
      (should (string= (ogent-edit-id (nth 0 valid)) "v1"))
      (should (string= (ogent-edit-id (nth 1 valid)) "v3")))))

(ert-deftest ogent-edit-parse/filter-errors ()
  "Filter errors returns only error edits."
  (let ((edits (list
                (make-ogent-edit :id "e1" :status 'pending)
                (make-ogent-edit :id "e2" :status 'error)
                (make-ogent-edit :id "e3" :status 'applied)
                (make-ogent-edit :id "e4" :status 'error))))
    (let ((errors (ogent-edit-filter-errors edits)))
      (should (= (length errors) 2))
      (should (string= (ogent-edit-id (nth 0 errors)) "e2"))
      (should (string= (ogent-edit-id (nth 1 errors)) "e4")))))

(ert-deftest ogent-edit-parse/filter-empty-list ()
  "Filters handle empty list."
  (should (= (length (ogent-edit-filter-valid '())) 0))
  (should (= (length (ogent-edit-filter-errors '())) 0)))

;;; Edge Cases

(ert-deftest ogent-edit-parse/with-code-in-prose ()
  "Parser correctly ignores code-like patterns in prose."
  (let* ((response "You mentioned <<<<<<< but that's not a marker.
Here's the actual fix:

<<<<<<< SEARCH
(old code)
=======
(new code)
>>>>>>> REPLACE

The >>>>>>> symbol appears in docs sometimes.")
         (source-buffer (get-buffer-create "*parse-prose*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) "(old code)")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/unicode-content ()
  "Parser handles unicode content correctly."
  (let* ((response "<<<<<<< SEARCH
(message \"Hello \")
=======
(message \"Hello \")
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*parse-unicode*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string-match-p "" (ogent-edit-old-text (car edits))))
          (should (string-match-p "" (ogent-edit-new-text (car edits)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/large-block ()
  "Parser handles large code blocks."
  (let* ((large-old (mapconcat #'identity
                               (make-list 100 "(defun fn () nil)")
                               "\n"))
         (large-new (mapconcat #'identity
                               (make-list 100 "(defun fn () t)")
                               "\n"))
         (response (format "<<<<<<< SEARCH\n%s\n=======\n%s\n>>>>>>> REPLACE"
                           large-old large-new))
         (source-buffer (get-buffer-create "*parse-large*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          ;; Check roughly correct size
          (should (> (length (ogent-edit-old-text (car edits))) 1000)))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/validate-position-accuracy ()
  "Validation positions are byte-accurate."
  (let ((source-buffer (get-buffer-create "*validate-pos*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "prefix(target)suffix"))
          (let ((edit (make-ogent-edit
                       :id "pos-001"
                       :old-text "(target)"
                       :new-text "(replacement)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            ;; Positions should match exactly
            (should (= (ogent-edit-start-pos edit) 7))  ; After "prefix"
            (should (= (ogent-edit-end-pos edit) 15)))) ; After "(target)"
      (kill-buffer source-buffer))))

;;; Structured Output Tests

(ert-deftest ogent-edit-parse/structured-valid-array ()
  "Valid structured array payload produces pending edit structs."
  (let* ((response "[{\"file\": \"a.el\", \"search\": \"(defun old-fn ()\\n  nil)\", \"replace\": \"(defun new-fn ()\\n  t)\"}]")
         (source-buffer (get-buffer-create "*structured-valid*"))
         (edits (ogent-edit-parse-structured-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (let ((edit (car edits)))
            (should (string= (ogent-edit-old-text edit)
                             "(defun old-fn ()\n  nil)"))
            (should (string= (ogent-edit-new-text edit)
                             "(defun new-fn ()\n  t)"))
            (should (eq (ogent-edit-status edit) 'pending))
            (should (eq (ogent-edit-source-buffer edit) source-buffer))
            (should (stringp (ogent-edit-id edit)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-matches-text-parser ()
  "Structured payload yields structs identical to text-parser output."
  (let ((source-buffer (get-buffer-create "*structured-parity*")))
    (unwind-protect
        (let* ((text-response "<<<<<<< SEARCH
(defun foo ()
  1)
=======
(defun foo ()
  2)
>>>>>>> REPLACE

<<<<<<< SEARCH
(defvar bar nil)
=======
(defvar bar t)
>>>>>>> REPLACE")
               (text-edits (ogent-edit-parse-response text-response source-buffer))
               (json-response (concat
                               "[{\"file\": \"a.el\","
                               " \"search\": \"(defun foo ()\\n  1)\","
                               " \"replace\": \"(defun foo ()\\n  2)\"},"
                               " {\"file\": \"a.el\","
                               " \"search\": \"(defvar bar nil)\","
                               " \"replace\": \"(defvar bar t)\"}]"))
               (structured-edits
                (ogent-edit-parse-structured-response json-response source-buffer)))
          (should (= (length text-edits) 2))
          (should (= (length structured-edits) 2))
          (cl-loop for text-edit in text-edits
                   for structured-edit in structured-edits
                   do (progn
                        (should (string= (ogent-edit-id text-edit)
                                         (ogent-edit-id structured-edit)))
                        (should (string= (ogent-edit-old-text text-edit)
                                         (ogent-edit-old-text structured-edit)))
                        (should (string= (ogent-edit-new-text text-edit)
                                         (ogent-edit-new-text structured-edit)))
                        (should (eq (ogent-edit-source-buffer text-edit)
                                    (ogent-edit-source-buffer structured-edit)))
                        (should (equal (ogent-edit-source-file text-edit)
                                       (ogent-edit-source-file structured-edit)))
                        (should (eq (ogent-edit-status text-edit)
                                    (ogent-edit-status structured-edit))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-items-wrapper ()
  "Object payload with an items array unwraps like a bare array.
Some backends cannot put an array at the schema root, so gptel wraps
it in an object with an \"items\" field."
  (let* ((response "{\"items\": [{\"file\": \"a.el\", \"search\": \"old\", \"replace\": \"new\"}]}")
         (source-buffer (get-buffer-create "*structured-items*"))
         (edits (ogent-edit-parse-structured-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) "old"))
          (should (string= (ogent-edit-new-text (car edits)) "new")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-normalizes-trailing-newline ()
  "Structured fields get the same trailing-newline normalization as text blocks."
  (let* ((response "[{\"file\": \"a.el\", \"search\": \"old\\n\", \"replace\": \"new\\n\"}]")
         (source-buffer (get-buffer-create "*structured-newline*"))
         (edits (ogent-edit-parse-structured-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) "old"))
          (should (string= (ogent-edit-new-text (car edits)) "new")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-rationale-accepted ()
  "Optional rationale field is accepted and does not affect the struct."
  (let* ((response "[{\"file\": \"a.el\", \"search\": \"old\", \"replace\": \"new\", \"rationale\": \"because\"}]")
         (source-buffer (get-buffer-create "*structured-rationale*"))
         (edits (ogent-edit-parse-structured-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (should (string= (ogent-edit-old-text (car edits)) "old"))
          (should (string= (ogent-edit-new-text (car edits)) "new")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-source-file-captured ()
  "Structured parser captures source file from a file-backed buffer."
  (with-temp-buffer
    (setq buffer-file-name "/nonexistent/ogent-parse-structured.el")
    (unwind-protect
        (let* ((response
                "[{\"file\": \"a.el\", \"search\": \"old\", \"replace\": \"new\"}]")
               (edits (ogent-edit-parse-structured-response
                       response (current-buffer))))
          (should (= (length edits) 1))
          (should (string= (ogent-edit-source-file (car edits))
                           "/nonexistent/ogent-parse-structured.el")))
      (setq buffer-file-name nil))))

(ert-deftest ogent-edit-parse/structured-empty-array ()
  "Empty structured payload yields an empty edit list, not an error."
  (let ((source-buffer (get-buffer-create "*structured-empty*")))
    (unwind-protect
        (progn
          (should-not (ogent-edit-parse-structured-response "[]" source-buffer))
          (should-not (ogent-edit-parse-structured-response
                       "{\"items\": []}" source-buffer)))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-malformed-json-signals ()
  "Non-JSON response signals the structured fallback error."
  (let ((source-buffer (get-buffer-create "*structured-nonjson*")))
    (unwind-protect
        (should-error
         (ogent-edit-parse-structured-response
          "Here is the fix:\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
          source-buffer)
         :type 'ogent-edit-structured-invalid)
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-wrong-shape-signals ()
  "Valid JSON with the wrong shape signals the structured fallback error."
  (let ((source-buffer (get-buffer-create "*structured-shape*")))
    (unwind-protect
        (progn
          ;; Scalar payload.
          (should-error (ogent-edit-parse-structured-response "42" source-buffer)
                        :type 'ogent-edit-structured-invalid)
          ;; Object without an items array.
          (should-error (ogent-edit-parse-structured-response
                         "{\"foo\": 1}" source-buffer)
                        :type 'ogent-edit-structured-invalid)
          ;; Entry missing the search field.
          (should-error (ogent-edit-parse-structured-response
                         "[{\"file\": \"a.el\", \"replace\": \"new\"}]" source-buffer)
                        :type 'ogent-edit-structured-invalid)
          ;; Entry with a non-string replace field.
          (should-error (ogent-edit-parse-structured-response
                         "[{\"file\": \"a.el\", \"search\": \"old\", \"replace\": 3}]"
                         source-buffer)
                        :type 'ogent-edit-structured-invalid)
          ;; Non-string response.
          (should-error (ogent-edit-parse-structured-response nil source-buffer)
                        :type 'ogent-edit-structured-invalid))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse/structured-id-counter-resets ()
  "Structured parsing restarts the edit ID sequence per response."
  (let ((source-buffer (get-buffer-create "*structured-ids*")))
    (unwind-protect
        (let* ((response (concat
                          "[{\"file\": \"a.el\", \"search\": \"one\", \"replace\": \"1\"},"
                          " {\"file\": \"a.el\", \"search\": \"two\", \"replace\": \"2\"}]"))
               (edits (ogent-edit-parse-structured-response response source-buffer)))
          (should (equal (mapcar #'ogent-edit-id edits)
                         '("ogent-edit-001" "ogent-edit-002")))
          ;; A second parse restarts the sequence.
          (should (equal (mapcar #'ogent-edit-id
                                 (ogent-edit-parse-structured-response
                                  response source-buffer))
                         '("ogent-edit-001" "ogent-edit-002"))))
      (kill-buffer source-buffer))))

(provide 'ogent-edit-parse-tests)
;;; ogent-edit-parse-tests.el ends here

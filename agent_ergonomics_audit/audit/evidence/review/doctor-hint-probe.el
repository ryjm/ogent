;;; doctor-hint-probe.el --- Verify the doctor correction example -*- lexical-binding: t; -*-

(require 'ogent-doctor)
(let ((doc (documentation 'ogent-doctor-batch)))
  (unless (string-match "(ogent-doctor-batch nil (quote json))" doc)
    (error "Public doctor docstring lacks a valid JSON example: %S" doc))
  (let ((example (match-string 0 doc)))
    (unless (equal (read example) '(ogent-doctor-batch nil (quote json)))
      (error "Public doctor example is not a valid JSON call"))
    (princ (format "docstring-example=%S\n" example))))
(let ((called nil)
      hint code output)
  (cl-letf (((symbol-function 'ogent-doctor-run)
             (lambda (&optional opt-in)
               (unless (null opt-in) (error "Hint enabled opt-in probes"))
               (setq called t)
               '((:id fixture :label "Fixture" :category environment
                       :status ok :detail "local fixture")))))
    (setq hint (condition-case err
                   (ogent-doctor-batch t 'jsno)
                 (user-error (error-message-string err))))
    (when called (error "Invalid format ran diagnostics"))
    (unless (string-match "(ogent-doctor-batch nil 'json)" hint)
      (error "Missing valid correction expression: %S" hint))
    (setq output (with-output-to-string
                   (setq code (eval (read (match-string 0 hint))))))
    (unless (and called (zerop code)
                 (equal "1" (plist-get (json-parse-string output :object-type 'plist)
                                       :contract_version)))
      (error "Pasted correction did not produce valid doctor JSON"))
    (princ (format "hint=%S\npaste-result=%S\nexit-code=%d\nverdict=CLEAN\n"
                   hint output code))))

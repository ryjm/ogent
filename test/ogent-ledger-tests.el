;;; ogent-ledger-tests.el --- Tests for ogent ledger -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for append-only ledger recording and tool integration.

;;; Code:

(require 'ert)
(require 'ogent-ledger)
(require 'ogent-models)
(require 'ogent-ui)

(ert-deftest ogent-ledger-record/disabled ()
  "Disabled ledger records nothing."
  (let* ((dir (make-temp-file "ogent-ledger-" t))
         (file (expand-file-name "ledger.org" dir))
         (ogent-ledger-enabled nil)
         (ogent-ledger-file file))
    (unwind-protect
        (progn
          (should-not (ogent-ledger-record 'test '(:x 1)))
          (should-not (file-exists-p file)))
      (delete-directory dir t))))

(ert-deftest ogent-ledger-record/appends-org-event ()
  "Enabled ledger appends an Org event with hash metadata."
  (let* ((dir (make-temp-file "ogent-ledger-" t))
         (file (expand-file-name "ledger.org" dir))
         (ogent-ledger-enabled t)
         (ogent-ledger-file file))
    (unwind-protect
        (let ((event (ogent-ledger-record 'test-event '(:x 1))))
          (should event)
          (should (file-exists-p file))
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward "#+title: ogent ledger" nil t))
            (should (search-forward "OGENT_LEDGER_TYPE: test-event" nil t))
            (should (search-forward "OGENT_LEDGER_HASH:" nil t))
            (should (search-forward ":x 1" nil t))))
      (delete-directory dir t))))


(ert-deftest ogent-ledger-hash/string-is-stable ()
  "Hashing a string preserves the proof-ledger compatibility contract."
  (should (equal (ogent-ledger-hash "hello")
                 "5aa762ae383fbb727af3c7a36d4940a5b8c40a989452d2304fc958ff3f354e7a")))

(ert-deftest ogent-ledger-sanitize/golden-shapes ()
  "Sanitization keeps printable shapes stable for replay and audit."
  (let ((table (make-hash-table :test 'equal)))
    (puthash "k" "v" table)
    (should (equal (ogent-ledger-sanitize [a "b" 3])
                   [a "b" 3]))
    (should (equal (ogent-ledger-sanitize '(:outer (:inner "v")))
                   '(:outer (:inner "v"))))
    (should (equal (ogent-ledger-sanitize table)
                   '(("k" . "v"))))))

(ert-deftest ogent-ledger-sanitize/buffer-and-marker ()
  "Sanitization converts buffers and markers to printable data."
  (with-temp-buffer
    (insert "abc")
    (let* ((marker (copy-marker 2))
           (sanitized (ogent-ledger-sanitize
                       (list :buffer (current-buffer) :marker marker))))
      (should (equal (plist-get sanitized :buffer)
                     (list :buffer (buffer-name))))
      (should (equal (plist-get sanitized :marker)
                     (list :marker 2 :buffer (buffer-name)))))))

(ert-deftest ogent-ledger-live-executor-records-tool-events ()
  "The live tool executor writes start and finish events when enabled."
  (let* ((dir (make-temp-file "ogent-ledger-" t))
         (file (expand-file-name "ledger.org" dir))
         (ogent-ledger-enabled t)
         (ogent-ledger-file file)
         (ogent-tool-registry
          '((:name echo-tool
             :function (lambda (value) value)
             :description "Echo value"
             :args ((:name "value" :type "string"))
             :effects ((:kind read :target memory :scope process :risk low)))))
         (seen-result nil)
         (seen-error nil))
    (unwind-protect
        (progn
          (setq seen-result (ogent-ui--execute-tool 'echo-tool '(:value "ok")))
          (should (equal seen-result "ok"))
          (should-not seen-error)
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward "OGENT_LEDGER_TYPE: tool-start" nil t))
            (should (search-forward "OGENT_LEDGER_TYPE: tool-finish" nil t))
            (goto-char (point-min))
            (should (search-forward ":effects" nil t))
            (goto-char (point-min))
            (should (search-forward ":result-hash" nil t))))
      (delete-directory dir t))))

(provide 'ogent-ledger-tests)

;;; ogent-ledger-tests.el ends here

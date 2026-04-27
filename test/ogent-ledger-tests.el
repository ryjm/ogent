;;; ogent-ledger-tests.el --- Tests for ogent ledger -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for append-only ledger recording and tool integration.

;;; Code:

(require 'ert)
(require 'ogent-ledger)
(require 'ogent-models)
(require 'ogent-tool-fsm)

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

(ert-deftest ogent-ledger-tool-fsm-records-tool-events ()
  "Tool FSM writes start and finish events when ledger is enabled."
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
          (ogent-tool-fsm-execute
           '(:id "tool-1" :name echo-tool :args (:value "ok"))
           (lambda (result error-message)
             (setq seen-result result
                   seen-error error-message)))
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

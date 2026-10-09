;;; boundary.el --- Independent round 13 boundary checks -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tool-process)
(require 'ogent-tool-results)

(defun review13--json-p (data)
  "Return whether DATA can be serialized with the contract JSON sentinels."
  (condition-case nil
      (progn (json-serialize data :null-object :json-null :false-object :json-false) t)
    (error nil)))

(defun review13--call (name args format async)
  "Return NAME result from ARGS using FORMAT and optional ASYNC delivery."
  (if (not async) (ogent-agent-call name args format)
    (let ((calls 0) result process)
      (setq process (ogent-agent-call-async name args
                                          (lambda (value) (cl-incf calls) (setq result value)) format))
      (let ((deadline (+ (float-time) 10)))
        (while (and (= calls 0) (< (float-time) deadline)) (accept-process-output nil 0.01)))
      (should (= calls 1))
      (when process (should-not (process-live-p process)))
      result)))

(ert-deftest review13-empty-excluded-and-missing-raw-roots ()
  "Refuse reflected raw roots before classification in every SDK transport."
  (let* ((base (make-temp-file "review13-root-" t))
         (raw (expand-file-name (decode-coding-string (unibyte-string 254) 'utf-8-unix) base))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil))
    (unwind-protect
        (progn
          (make-directory raw)
          (dolist (state '(empty excluded missing))
            (pcase state
              ('excluded (with-temp-file (expand-file-name "excluded.txt" raw) (insert "needle\n")))
              ('missing (delete-directory raw t)))
            (dolist (name '("files" "search"))
              (let ((arguments (if (equal name "files") '(:pattern "**/*.el")
                                 '(:pattern "needle" :glob_filter "**/*.el"))))
                (dolist (explicit '(nil t))
                  (let ((ogent-tools-project-root raw))
                    (dolist (format '(plist json))
                      (dolist (async '(nil t))
                        (let* ((value (review13--call name
                                                    (if explicit (append arguments (list :path raw)) arguments)
                                                    format async))
                               (result (if (eq format 'json)
                                           (json-parse-string value :object-type 'plist
                                                              :false-object :json-false :null-object :json-null)
                                         value)))
                          (should (review13--json-p result))
                          (should (equal (plist-get result :status) "error"))
                          (should (equal (plist-get (plist-get result :error) :code) "unsupported_output")))))))))))
      (delete-directory base t))))

(ert-deftest review13-pagination-unicode-and-symlink-identity ()
  "Keep valid Unicode paths and continuation args intact through both formats."
  (let* ((base (make-temp-file "review13-page-" t))
         (root (expand-file-name "λ 😀\troot" base))
         (alias (expand-file-name "é-link" base))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil))
    (unwind-protect
        (progn
          (make-directory root)
          (dolist (name '("日本語\nfile.el" "a'colon:.el"))
            (with-temp-file (expand-file-name name root) (insert "needle λ\nneedle 😀\n")))
          (make-symbolic-link root alias)
          (dolist (entry (list (list "files" (list :pattern "**/*.el" :path alias :limit 1))
                               (list "search" (list :pattern "needle" :path alias :limit 1))
                               (list "read" (list :file_path (expand-file-name "日本語\nfile.el" alias) :limit 1))))
            (dolist (format '(plist json))
              (let* ((value (review13--call (car entry) (cadr entry) format t))
                     (result (if (eq format 'json)
                                 (json-parse-string value :object-type 'plist
                                                    :false-object :json-false :null-object :json-null) value)))
                (should (equal (plist-get result :status) "ok"))
                (should (review13--json-p result))
                (should (= (length (plist-get result :next)) 1))
                (let* ((next-value (ogent-agent-next value format))
                       (next-result (if (eq format 'json)
                                        (json-parse-string next-value :object-type 'plist) next-value)))
                  (should (equal (plist-get next-result :status) "ok"))
                  (should (string-prefix-p alias (plist-get (plist-get next-result :data) :path))))))))
      (delete-directory base t))))

(ert-deftest review13-real-gptel-error-and-unicode-wire ()
  "Use actual gptel processing and nested encoding for root errors and Unicode."
  (let* ((base (make-temp-file "review13-wire-" t))
         (raw (expand-file-name (decode-coding-string (unibyte-string 253) 'utf-8-unix) base))
         (valid (expand-file-name "λ-root" base))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-tools-result-format 'json) (ogent-ledger-enabled nil)
         (ogent--tools-registered nil) (ogent--tool-specs-registered nil)
         (ogent--tool-formats-registered nil) (gptel--known-tools nil)
         (backend (gptel-make-openai "review13-offline" :host "offline.invalid"
                                    :key "unused" :models '(local))))
    (unwind-protect
        (progn
          (make-directory raw) (make-directory valid)
          (with-temp-file (expand-file-name "😀.el" valid) (insert "λ"))
          (dolist (root (list raw valid))
            (let* ((tool (ogent-tool-get "glob"))
                   (value (funcall (gptel-tool-function tool) "*.el" root))
                   (completed (list :id "completed" :name "glob" :args (list :pattern "*.el" :path root)))
                   (pending (list :id "no-transport" :name "glob"))
                   (fsm (gptel-make-fsm :info (list :backend backend :tool-use (list completed pending)))))
              (gptel--process-tool-call fsm tool completed value)
              (should-not (plist-get pending :result))
              (let* ((messages (gptel--parse-tool-results backend (list completed)))
                     (wire (gptel--json-encode (list :messages (vconcat messages))))
                     (parsed (json-parse-string wire :object-type 'plist))
                     (content (plist-get (aref (plist-get parsed :messages) 0) :content))
                     (result (json-parse-string content :object-type 'plist)))
                (should (equal content value))
                (if (equal root raw)
                    (should (equal (plist-get (plist-get result :error) :code) "unsupported_output"))
                  (should (equal (plist-get result :status) "ok"))
                  (should (equal (plist-get (plist-get result :data) :path) valid)))))))
      (delete-directory base t))))

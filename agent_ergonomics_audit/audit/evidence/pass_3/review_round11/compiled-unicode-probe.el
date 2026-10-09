;;; compiled-unicode-probe.el --- Review compiled Unicode boundaries -*- lexical-binding: t; -*-

(require 'ogent-agent-execution-tests)
(require 'bytecomp)

(load "/work/lisp/ogent-agent.el" nil t t)
(load "/work/lisp/ogent-tool-results.el" nil t t)

(let* ((compile-root (ogent-test--provision-store-directory 'round11-bytecode))
       (byte-compile-error-on-warn t)
       (byte-compile-dest-file-function
        (lambda (file)
          (expand-file-name (concat (file-name-nondirectory file) "c") compile-root))))
  (dolist (file '("/work/lisp/ogent-agent.el" "/work/lisp/ogent-tool-results.el"))
    (unless (byte-compile-file file)
      (error "Warning-strict compilation failed: %s" file)))
  (load (expand-file-name "ogent-tool-results.elc" compile-root) nil t t))

(ert-deftest ogent-round11-compiled-valid-unicode-identity ()
  "Compiled validation returns the same supported string object."
  (should (byte-code-function-p (symbol-function 'ogent-tool-results--unicode)))
  (dolist (text '("" "ASCII" "lambda: λ" "日本語" "🦉" "é" "quote: \" slash: \\ tab: \t newline: \n"))
    (should (eq (ogent-tool-results--unicode text) text))
    (should (equal (json-parse-string (json-serialize text)) text))))

(ert-deftest ogent-round11-compiled-rejects-raw-byte-characters ()
  "Compiled validation keeps the serializer call and rejects raw bytes."
  (should (byte-code-function-p (symbol-function 'ogent-tool-results--unicode)))
  (dolist (byte '(128 192 255))
    (let ((text (concat "lambda: λ" (unibyte-string byte))))
      (should-error (ogent-tool-results--unicode text)
                    :type 'ogent-tool-results-output-error))))

(ert-deftest ogent-round11-compiled-unicode-sdk-continuation ()
  "Compiled reads retain Unicode characters across native and JSON pages."
  (let* ((root (ogent-test--provision-store-directory 'round11-unicode))
         (text "λ🦉é日本語\"\\\tend")
         (file (ogent-agent-execution-tests--file root "λ🦉.txt" text))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-tools-max-output-chars 3)
         (page (json-parse-string (ogent-agent-call "read" (list :file_path file) 'json)
                                 :object-type 'plist :null-object :json-null
                                 :false-object :json-false))
         (snapshot (plist-get (plist-get page :data) :snapshot))
         (content "")
         (pages 0))
    (while (equal (plist-get page :status) "ok")
      (cl-incf pages)
      (should (<= pages 20))
      (should (equal (plist-get (plist-get page :data) :path) file))
      (should (equal (plist-get (plist-get page :data) :snapshot) snapshot))
      (setq content (concat content (plist-get (plist-get page :data) :content))
            page (json-parse-string (ogent-agent-next page 'json)
                                    :object-type 'plist :null-object :json-null
                                    :false-object :json-false)))
    (should (equal (plist-get page :status) "done"))
    (should (> pages 1))
    (should (equal content text))))

(ert-deftest ogent-round11-compiled-raw-path-sdk-boundaries ()
  "Raw filenames keep typed sync, callback and read-only batch failures."
  (let* ((root (ogent-test--provision-store-directory 'round11-raw-path))
         (file (concat root "/" (unibyte-string 255) ".txt"))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-ledger-enabled nil)
         (callbacks 0)
         terminal)
    (with-temp-file file (insert "contents"))
    (dolist (name '("read" "files"))
      (let* ((args (if (equal name "read")
                       (list :file_path file)
                     (list :pattern "*.txt" :path root)))
             (result (json-parse-string (ogent-agent-call name args 'json)
                                        :object-type 'plist)))
        (should (equal (plist-get result :status) "error"))
        (should (equal (plist-get (plist-get result :error) :code) "unsupported_output"))))
    (should-not (ogent-agent-call-async
                 "read" (list :file_path file)
                 (lambda (result) (cl-incf callbacks) (setq terminal result)) 'json))
    (should (= callbacks 1))
    (should (equal (plist-get (plist-get (json-parse-string terminal :object-type 'plist)
                                       :error) :code) "unsupported_output"))
    (let* ((batch (json-parse-string
                  (ogent-agent-batch
                   (list (list :tool "read" :args (list :file_path file))
                         (list :tool "files" :args (list :pattern "*.txt" :path root)))
                   'json)
                  :object-type 'plist))
           (data (plist-get batch :data)))
      (should (equal (plist-get batch :status) "partial"))
      (should (= (plist-get data :completed) 2))
      (dotimes (index 2)
        (should (equal (plist-get (plist-get (aref (plist-get data :results) index) :error)
                                 :code) "unsupported_output"))))))

(ert-run-tests-batch-and-exit "^ogent-round11-")

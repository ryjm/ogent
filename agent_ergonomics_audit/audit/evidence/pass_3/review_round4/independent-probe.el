;;; independent-probe.el --- Round four independent probes -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-debug)
(require 'ogent-tool-process)
(require 'cl-lib)

(defun round4-output (label data)
  (princ (format "%s %S\n" label data)))

;; Exercise supported object arguments across the real approval boundary.
(dolist (format '(text json))
  (let* ((input (make-hash-table :test #'equal))
         (spec (list :name 'object-fixture :confirm t
                     :args '((:name "value" :type "object"))
                     :function (lambda (value) (gethash "path" value))))
         (ogent-tool-registry (list spec))
         (ogent-tool-require-approval t)
         (ogent-tool-allow-list nil) (ogent-tool--denied-tools nil)
         (wrapper (ogent-tool-execution-wrapper spec format)))
    (puthash "path" "safe" input)
    (cl-letf (((symbol-function 'ogent-tool--prompt-approval)
               (lambda (_name args)
                 (round4-output (format "OBJECT PREVIEW %s" format)
                                (gethash "path" (plist-get args :value)))
                 (puthash "path" "changed" input)
                 'approve)))
      (round4-output (format "OBJECT EXECUTION %s" format)
                     (funcall wrapper input)))))

(let* ((input (make-hash-table :test #'equal))
       (ogent-tool-require-approval nil)
       (ogent-tool-registry
        (list (list :name 'first-read :args nil
                    :effects '((:kind read :target file :scope workspace :risk low))
                    :function (lambda () (puthash "path" "changed" input) "first"))
              (list :name 'second-read :args '((:name "value" :type "object"))
                    :effects '((:kind read :target file :scope workspace :risk low))
                    :function (lambda (value) (gethash "path" value))))))
  (puthash "path" "safe" input)
  (round4-output "BATCH OBJECT EXECUTION"
                 (ogent-agent-batch (list (list :tool "first-read" :args nil)
                                         (list :tool "second-read" :args (list :value input))))))

;; Common practical filename wildcards must retain the same candidate set.
(let* ((root (ogent-test--provision-store-directory 'tools))
       (ogent-tools-project-root root)
       (finder (symbol-function 'executable-find)))
  (dolist (name '("src/a.txt" "src/deep/b.txt" "a.txt" "b.txt" "c.txt" "0.txt"
                  "!.txt" "[a].txt" "{a,b}.txt" "a\\b.txt" ".hidden.txt" "é.txt"
                  "!foo/bar.txt" "dir[x]/item.txt" "dir{a,b}/item.txt"))
    (let ((file (expand-file-name name root)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "needle\n"))))
  (dolist (filter '("*.txt" "**/*.txt" "src/*.txt" "src/**/*.txt"
                    "[a-c].txt" "[!a].txt" "[^a].txt" "[[]a].txt" "?.txt"
                    "{a,b}.txt" "a\\b.txt" "!foo/*.txt" "dir[[]x]/item.txt"
                    "dir{a,b}/*.txt" "**" "src/**" ".*.txt"))
    (let (results)
      (dolist (engine '(gnu rg))
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (name &optional remote)
                     (if (equal name "rg") (and (eq engine 'rg) "/tmp/ogent-test-rg")
                       (funcall finder name remote)))))
          (push (cons engine
                      (condition-case err
                          (mapcar (lambda (entry) (file-relative-name (plist-get entry :path) root))
                                  (append (plist-get (ogent-tool-process-grep "needle" root filter) :matches) nil))
                        (error err)))
                results)))
      (round4-output (format "GLOB PARITY %S" filter) (nreverse results)))))

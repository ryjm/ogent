;;; ogent-tool-process-tests.el --- Structured process tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise structured search and shell results against real local processes.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'ogent-test-helper)
(require 'ogent-tool-process nil t)

(defmacro ogent-tool-process-tests--with-directory (&rest body)
  "Run BODY with an isolated tool project directory."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "ogent-process-test-" t))
          (ogent-tools-project-root directory))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(defun ogent-tool-process-tests--write (directory name text)
  "Write TEXT into NAME under DIRECTORY and return the absolute filename."
  (let ((file (expand-file-name name directory)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(defun ogent-tool-process-tests--wait (predicate &optional timeout)
  "Pump events until PREDICATE succeeds within TIMEOUT, default five seconds."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defmacro ogent-tool-process-tests--with-engine (engine &rest body)
  "Run BODY using the real search executable selected by ENGINE."
  (declare (indent 1) (debug t))
  `(let* ((engine ,engine)
          (find-executable (symbol-function 'executable-find))
          (rg (or (getenv "OGENT_PROCESS_TEST_RG") (executable-find "rg"))))
     (when (eq engine 'ripgrep)
       (skip-unless (and rg (file-executable-p rg))))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (name &optional remote)
                  (if (equal name "rg")
                      (when (eq engine 'ripgrep) rg)
                    (funcall find-executable name remote)))))
       ,@body)))

(defun ogent-tool-process-tests--check-explicit-filter ()
  "Verify explicit-file filtering and regex validation against a real engine."
  (ogent-tool-process-tests--with-directory
    (let ((file (ogent-tool-process-tests--write
                 directory "data [1]!*.txt" "needle\nneedle\nneedle\n")))
      (should (= (plist-get (ogent-tool-process-grep "needle" file "*.txt")
                            :total_matches) 3))
      (should (= (plist-get (ogent-tool-process-grep "needle" file "*.el")
                            :total_matches) 0))
      (should-error (ogent-tool-process-grep "[" file "*.el")
                    :type 'ogent-tool-process-search-failed))))

(defun ogent-tool-process-tests--check-binary-scope ()
  "Verify binary exclusion for explicit files and directories."
  (ogent-tool-process-tests--with-directory
    (let ((binary (ogent-tool-process-tests--write
                   directory "binary.txt" "needle\n\0needle\nneedle\n"))
          (late-binary (ogent-tool-process-tests--write
                        directory "late.txt"
                        (concat "needle\n" (make-string 100000 ?x) "\0\n")))
          (bom-binary (let ((coding-system-for-write 'utf-16le-with-signature))
                        (ogent-tool-process-tests--write directory "bom.txt" "needle\n")))
          (text (ogent-tool-process-tests--write directory "source.txt" "needle\n")))
      (should (= (plist-get (ogent-tool-process-grep "needle" binary) :total_matches) 0))
      (should (= (plist-get (ogent-tool-process-grep "needle" late-binary) :total_matches) 0))
      (should (= (plist-get (ogent-tool-process-grep "needle" bom-binary) :total_matches) 0))
      (should-error (ogent-tool-process-grep "[" late-binary)
                    :type 'ogent-tool-process-search-failed)
      (let* ((result (ogent-tool-process-grep "needle" directory))
             (matches (plist-get result :matches)))
	(should (= (plist-get result :total_matches) 1))
	(should (equal (plist-get (aref matches 0) :path) text))))))

(defun ogent-tool-process-tests--check-component-filters ()
  "Verify shared positive wildcard semantics against a real search engine."
  (ogent-tool-process-tests--with-directory
    (dolist (name '("src/direct.txt" "src/deep/nested.txt" "top.txt"
                    "!literal.txt" "{a,b}.txt" "a.txt" "^literal.txt"))
      (ogent-tool-process-tests--write directory name "needle\n"))
    (dolist (case '(("src/*.txt" "src/direct.txt")
                    ("src/**/*.txt" "src/deep/nested.txt" "src/direct.txt")
                    ("*.txt" "!literal.txt" "^literal.txt" "a.txt" "src/deep/nested.txt"
                     "src/direct.txt" "top.txt" "{a,b}.txt")
                    ("**/*.txt" "!literal.txt" "^literal.txt" "a.txt" "src/deep/nested.txt"
                     "src/direct.txt" "top.txt" "{a,b}.txt")
                    ("!*.txt" "!literal.txt")
                    ("{a,b}.txt" "{a,b}.txt")
                    ("[^a]*.txt" "^literal.txt" "a.txt")
                    ("")))
      (let* ((result (ogent-tool-process-grep "needle" directory (car case)))
             (matches (plist-get result :matches))
             (paths (mapcar
                     (lambda (match) (file-relative-name (plist-get match :path) directory))
                     (append matches nil))))
        (should (equal paths (cdr case)))
        (should (= (plist-get result :total_matches) (length (cdr case))))))))

(defun ogent-tool-process-tests--check-unicode-filters ()
  "Verify Unicode name filtering without reading excluded oversized text files."
  (ogent-tool-process-tests--with-directory
    (dolist (name '("a.txt" "é.txt" "Ω.txt" "目录/é.txt" "目录/a.txt"
                    "odd:\né[1]?*.txt"))
      (ogent-tool-process-tests--write directory name "needle\n"))
    ;; This file shares the candidate parent but must never be searched.
    (ogent-tool-process-tests--write directory "excluded.log"
                                     (concat "needle" (make-string 1100000 ?x) "\n"))
    (dolist (case '(("?.txt" "a.txt" "é.txt" "Ω.txt" "目录/a.txt" "目录/é.txt")
                    ("[!a].txt" "é.txt" "Ω.txt" "目录/é.txt")
                    ("[éΩ].txt" "é.txt" "Ω.txt" "目录/é.txt")
                    ("目录/?.txt" "目录/a.txt" "目录/é.txt")
                    ("目录/[!a].txt" "目录/é.txt")
                    ("目录/é.txt" "目录/é.txt")
                    ("odd*?.txt" "odd:\né[1]?*.txt")))
      (let* ((result (ogent-tool-process-grep "needle" directory (car case)))
             (paths (mapcar
                     (lambda (match) (file-relative-name (plist-get match :path) directory))
                     (append (plist-get result :matches) nil))))
        (should (equal paths (cdr case)))
        (should (= (plist-get result :total_matches) (length (cdr case))))))
    (should-error (ogent-tool-process-grep "[" directory "missing?.txt")
                  :type 'ogent-tool-process-search-failed)
    (should (= (plist-get
                (ogent-tool-process-grep "needle" (expand-file-name "目录/é.txt" directory))
                :total_matches) 1))))

(defun ogent-tool-process-tests--check-symlink-scope ()
  "Verify file link inclusion without directory link traversal or binary text."
  (ogent-tool-process-tests--with-directory
    (let ((outside (make-temp-file "ogent-process-outside-" t))
          (link (expand-file-name "link.txt" directory)))
      (unwind-protect
          (progn
            (ogent-tool-process-tests--write
             directory "source.txt" "before\nneedle one\nbetween\nneedle two\nafter\n")
            (ogent-tool-process-tests--write directory "nested/inside.txt" "needle inside\n")
            (ogent-tool-process-tests--write directory "binary.txt" "needle\n\0needle\n")
            (ogent-tool-process-tests--write outside "outside.txt" "needle outside\n")
            (make-symbolic-link "source.txt" link)
            (make-symbolic-link "binary.txt" (expand-file-name "binary-link.txt" directory))
            (make-symbolic-link outside (expand-file-name "outside-directory.txt" directory))
            (make-symbolic-link directory (expand-file-name "loop-directory.txt" directory))
            (make-symbolic-link "cycle-two.txt" (expand-file-name "cycle-one.txt" directory))
            (make-symbolic-link "cycle-one.txt" (expand-file-name "cycle-two.txt" directory))
            (dolist (filter '(nil "*.txt" "link.txt" "l?nk.txt" "[ls]ink.txt"))
              (let* ((all (ogent-tool-process-grep "needle" directory filter 1))
                     (expected (if (member filter '(nil "*.txt"))
                                   '("link.txt" "link.txt" "nested/inside.txt"
                                     "source.txt" "source.txt")
                                 '("link.txt" "link.txt")))
                     (first (ogent-tool-process-grep "needle" directory filter 1 0 1))
                     (second (ogent-tool-process-grep "needle" directory filter 1 1 1)))
                (should (equal
                         (mapcar (lambda (match)
                                   (file-relative-name (plist-get match :path) directory))
                                 (append (plist-get all :matches) nil))
                         expected))
                (should (= (plist-get all :total_matches) (length expected)))
                (should (equal (plist-get first :snapshot) (plist-get all :snapshot)))
                (should (equal (plist-get second :snapshot) (plist-get all :snapshot)))
                (should (= (plist-get first :next_offset) 1))
                (should (= (plist-get (aref (plist-get first :matches) 0) :line) 2))
                (should (= (plist-get (aref (plist-get second :matches) 0) :line) 4))
                (should (equal (plist-get (aref (plist-get first :matches) 0) :context_before)
                               [(:line 1 :text "before")]))
                (should (equal (plist-get (aref (plist-get second :matches) 0) :context_after)
                               [(:line 5 :text "after")]))
                (should (equal (aref (plist-get first :matches) 0)
                               (aref (plist-get all :matches) 0)))
                (should (equal (aref (plist-get second :matches) 0)
                               (aref (plist-get all :matches) 1)))))
            (should (= (plist-get (ogent-tool-process-grep "needle" link "*.txt")
                                  :total_matches) 2))
            (should (= (plist-get (ogent-tool-process-grep "needle" link "*.el")
                                  :total_matches) 0))
            (should (= (plist-get (ogent-tool-process-grep
                                   "needle" (expand-file-name "binary-link.txt" directory))
                                  :total_matches) 0))
            (let ((target (ogent-tool-process-tests--write
                           outside "odd:\né[1]?*.txt" "needle mapped\n"))
                  (empty (ogent-tool-process-tests--write outside "empty.log" "unrelated\n")))
              (make-symbolic-link target (expand-file-name "a-outside.txt" directory))
              (make-symbolic-link empty (expand-file-name "b-empty.txt" directory))
              (make-symbolic-link target (expand-file-name "z-link.txt" directory))
              (ogent-tool-process-tests--write
               outside "excluded.txt" (concat "needle" (make-string 1100000 ?x) "\n"))
              (let* ((first (ogent-tool-process-grep "needle" directory "*.txt" 0 0 3))
                     (last (ogent-tool-process-grep "needle" directory "*.txt" 0 3 4))
                     (names (mapcar
                             (lambda (match)
                               (file-relative-name (plist-get match :path) directory))
                             (append (plist-get first :matches) (plist-get last :matches) nil))))
                (should (equal names '("a-outside.txt" "link.txt" "link.txt"
                                       "nested/inside.txt" "source.txt" "source.txt" "z-link.txt")))
                (should (= (plist-get first :total_matches) 7))
                (should (= (plist-get first :next_offset) 3))
                (should (eq (plist-get last :has_more) :json-false))
                (should (equal (plist-get first :snapshot) (plist-get last :snapshot))))))
        (delete-directory outside t)))))

(defun ogent-tool-process-tests--check-unsupported-filenames ()
  "Reject selected non-UTF-8 filenames and ignore excluded oversized files."
  (ogent-tool-process-tests--with-directory
    (let ((raw-name (concat (decode-coding-string (unibyte-string 255) 'utf-8-unix)
                            ".txt")))
      (ogent-tool-process-tests--write directory raw-name "needle\n")
      (ogent-tool-process-tests--write directory "valid.el" "needle\n")
      (dolist (filter '(nil "*.txt" "?.txt"))
        (should-error (ogent-tool-process-grep "needle" directory filter)
                      :type 'ogent-tool-process-output-error))
      (ogent-tool-process-tests--write
       directory raw-name (concat "needle" (make-string 1100000 ?x) "\n"))
      (should (= (plist-get (ogent-tool-process-grep "needle" directory "*.el")
                            :total_matches) 1)))))

(ert-deftest ogent-tool-process-bash-separates-channels-and-exit ()
  "Preserve stdout and stderr separately on a real nonzero command exit."
  (ogent-tool-process-tests--with-directory
    (let ((result (ogent-tool-process-bash
                   "printf 'out'; printf 'err' >&2; exit 42")))
      (should (equal (plist-get result :stdout) "out"))
      (should (equal (plist-get result :stderr) "err"))
      (should (= (plist-get result :exit_code) 42))
      (should (eq (plist-get result :timed_out) :json-false))
      (should (eq (plist-get result :cancelled) :json-false))
      (should (eq (plist-get result :truncated) :json-false)))))

(ert-deftest ogent-tool-process-bash-bounds-combined-channels ()
  "Bound combined retained output without adding text footers."
  (ogent-tool-process-tests--with-directory
    (let* ((ogent-tools-max-output-chars 7)
           (result (ogent-tool-process-bash
                    "printf 'abcdefghij'; printf 'klmnopqrst' >&2")))
      (should (= (+ (length (plist-get result :stdout))
                    (length (plist-get result :stderr))) 7))
      (should (eq (plist-get result :truncated) t))
      (should (= (plist-get result :exit_code) 0)))))

(ert-deftest ogent-tool-process-bash-zero-output-budget ()
  "Return a truncation flag and no text when the configured budget is zero."
  (ogent-tool-process-tests--with-directory
    (let* ((ogent-tools-max-output-chars 0)
           (result (ogent-tool-process-bash "printf x; printf y >&2")))
      (should (equal (plist-get result :stdout) ""))
      (should (equal (plist-get result :stderr) ""))
      (should (eq (plist-get result :truncated) t)))))

(ert-deftest ogent-tool-process-bash-invalid-utf8-remains-json-safe ()
  "Replace undecodable process bytes explicitly and retain a serializable result."
  (ogent-tool-process-tests--with-directory
    (let ((result (ogent-tool-process-bash "printf '\\377'")))
      (should (equal (plist-get result :stdout) "\uFFFD"))
      (should (eq (plist-get result :encoding_loss) t))
      (should (stringp (json-serialize result :false-object :json-false
                                       :null-object :json-null))))))

(ert-deftest ogent-tool-process-bash-timeout-keeps-partial-output ()
  "Preserve output already received when the command times out."
  (ogent-tool-process-tests--with-directory
    (let ((result (ogent-tool-process-bash "printf ready; sleep 4" nil 0.1)))
      (should (equal (plist-get result :stdout) "ready"))
      (should (eq (plist-get result :timed_out) t))
      (should (eq (plist-get result :cancelled) :json-false)))))

(ert-deftest ogent-tool-process-bash-signal-is-distinct-from-cancel ()
  "Preserve partial output and signal metadata without inventing user cancellation."
  (ogent-tool-process-tests--with-directory
    (let ((result (ogent-tool-process-bash "printf ready; kill -TERM $$")))
      (should (equal (plist-get result :stdout) "ready"))
      (should (= (plist-get result :signal) 15))
      (should (= (plist-get result :exit_code) 15))
      (should (eq (plist-get result :timed_out) :json-false))
      (should (eq (plist-get result :cancelled) :json-false)))))

(ert-deftest ogent-tool-process-bash-async-is-asynchronous ()
  "Return a live process before delivering exactly one terminal callback."
  (ogent-tool-process-tests--with-directory
    (let ((calls 0) result failure process)
      (unwind-protect
          (progn
            (setq process
                  (ogent-tool-process-bash-async
                   "sleep 0.1; printf async" nil 2
                   (lambda (data error-data)
                     (cl-incf calls) (setq result data failure error-data))))
            (should (processp process))
            (should (process-live-p process))
            (should (= calls 0))
            (should (ogent-tool-process-tests--wait (lambda () (= calls 1))))
            (should-not failure)
            (should (equal (plist-get result :stdout) "async"))
            (should-not (assq process ogent-tools--active-processes))
            (should-not (process-buffer process))
            (accept-process-output nil 0.05)
            (should (= calls 1)))
	(ogent-tool-process-cancel process)))))

(ert-deftest ogent-tool-process-bash-cancel-keeps-partial-output ()
  "Cancel the running command and return one partial result without leaks."
  (ogent-tool-process-tests--with-directory
    (let ((calls 0) result process)
      (unwind-protect
          (progn
            (setq process
                  (ogent-tool-process-bash-async
                   "printf ready; sleep 4" nil 5
                   (lambda (data _error-data)
                     (cl-incf calls) (setq result data))))
            (accept-process-output nil 0.05)
            (should (ogent-tool-process-cancel process))
            (should (ogent-tool-process-tests--wait (lambda () (= calls 1))))
            (should (equal (plist-get result :stdout) "ready"))
            (should (eq (plist-get result :cancelled) t))
            (should-not (assq process ogent-tools--active-processes))
            (should-not (ogent-tool-process-cancel process)))
	(ogent-tool-process-cancel process)))))

(ert-deftest ogent-tool-process-bash-cancel-kills-grandchild ()
  "Terminate shell grandchildren rather than leaving an orphan after cancel."
  (skip-unless (eq system-type 'gnu/linux))
  (ogent-tool-process-tests--with-directory
    (let ((pid-file (expand-file-name "child.pid" directory)) process result)
      (unwind-protect
          (progn
            (setq process
                  (ogent-tool-process-bash-async
                   "sleep 20 & child=$!; printf '%s' \"$child\" > child.pid; wait"
                   nil 5 (lambda (data _error-data) (setq result data))))
            (should (ogent-tool-process-tests--wait
                     (lambda () (file-exists-p pid-file))))
            (let ((child (string-to-number
                          (with-temp-buffer (insert-file-contents pid-file)
                                            (buffer-string)))))
              (ogent-tool-process-cancel process)
              (should (ogent-tool-process-tests--wait (lambda () result)))
              (should (ogent-tool-process-tests--wait
                       (lambda ()
                         (or (null (process-attributes child))
                             (equal (cdr (assq 'state (process-attributes child)))
                                    "Z")))))))
	(ogent-tool-process-cancel process)))))

(ert-deftest ogent-tool-process-bash-terminal-exit-bounds-descendant-drain ()
  "Finish promptly when an exited shell leaves a descendant flooding stderr."
  (skip-unless (eq system-type 'gnu/linux))
  (ogent-tool-process-tests--with-directory
    (let* ((start (float-time))
           (ogent-tools-max-output-chars 1000)
           ;; The independent two-second guard keeps this regression bounded
           ;; even when evaluated against the original broken implementation.
           (result (ogent-tool-process-bash
                    (concat
                     ;; Deliver stdout before the deliberately tiny shared
                     ;; budget can be consumed by the flooding stderr stream.
                     "printf parent; sleep 0.02; "
                     "(while :; do printf x >&2; done) & child=$!; "
                     "printf '%s' \"$child\" > child.pid; "
                     "(sleep 2; kill -KILL \"$child\" 2>/dev/null) & "
                     "exit 0")
                    nil 0.2))
           (child (string-to-number
                   (with-temp-buffer
                     (insert-file-contents (expand-file-name "child.pid" directory))
                     (buffer-string)))))
      (should (< (- (float-time) start) 0.75))
      (should (= (plist-get result :exit_code) 0))
      (should (equal (plist-get result :stdout) "parent"))
      (should (<= (+ (length (plist-get result :stdout))
                     (length (plist-get result :stderr))) 1000))
      (should (ogent-tool-process-tests--wait
               (lambda ()
                 (or (null (process-attributes child))
                     (equal (cdr (assq 'state (process-attributes child))) "Z")))
               0.25)))))

(ert-deftest ogent-tool-process-bash-callback-error-cleans-up ()
  "Clean up timers and registration even when a terminal callback signals."
  (ogent-tool-process-tests--with-directory
    (let ((calls 0) process)
      (setq process (ogent-tool-process-bash-async
                     "printf x" nil 1
                     (lambda (_data _error-data)
                       (cl-incf calls) (error "Callback failure"))))
      (should (ogent-tool-process-tests--wait (lambda () (= calls 1))))
      (should (process-get process 'ogent-callback-error))
      (should-not (assq process ogent-tools--active-processes))
      (should-not (process-get process 'ogent-cancel)))))

(ert-deftest ogent-tool-process-bash-validation-does-not-spawn ()
  "Deliver one actionable validation error before creating any process."
  (ogent-tool-process-tests--with-directory
    (let ((calls 0) failure)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _args) (ert-fail "Unexpected process"))))
	(should-not (ogent-tool-process-bash-async
                     "" nil 1
                     (lambda (data error-data)
                       (cl-incf calls) (should-not data) (setq failure error-data)))))
      (should (= calls 1))
      (should (eq (car failure) 'user-error)))))

(ert-deftest ogent-tool-process-bash-startup-error-is-terminal ()
  "Report a failed process launch once and leave no pipe process behind."
  (ogent-tool-process-tests--with-directory
    (let ((pipes-before (cl-remove-if-not
                         (lambda (proc)
                           (string-prefix-p "ogent-structured-stderr"
                                            (process-name proc)))
                         (process-list)))
          (calls 0) failure)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _args) (error "Launch failed"))))
	(should-not
         (ogent-tool-process-bash-async
          "printf x" nil 1
          (lambda (_data error-data)
            (cl-incf calls) (setq failure error-data)))))
      (should (= calls 1))
      (should (eq (car failure) 'ogent-tool-process-start-failed))
      (should (string-match-p "Launch failed" (error-message-string failure)))
      (should (equal pipes-before
                     (cl-remove-if-not
                      (lambda (proc)
			(and (process-live-p proc)
                             (string-prefix-p "ogent-structured-stderr"
                                              (process-name proc))))
                      (process-list)))))))

(ert-deftest ogent-tool-process-grep-pages-all-matches ()
  "Count matches beyond the legacy per-file cap and expose stable next offsets."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt"
                                     (mapconcat (lambda (_n) "needle")
						(number-sequence 1 250) "\n"))
    (let ((first (ogent-tool-process-grep "needle" nil nil 0 0 200))
          (last (ogent-tool-process-grep "needle" nil nil 0 200 200)))
      (should (= (plist-get first :total_matches) 250))
      (should (= (length (plist-get first :matches)) 200))
      (should (= (plist-get first :next_offset) 200))
      (should (eq (plist-get first :has_more) t))
      (should (= (length (plist-get last :matches)) 50))
      (should (eq (plist-get last :has_more) :json-false))
      (should (eq (plist-get last :next_offset) :json-null))
      (should (equal (plist-get first :snapshot) (plist-get last :snapshot))))))

(ert-deftest ogent-tool-process-grep-preserves-unusual-filenames ()
  "Keep colon, dash, spaces and newline filenames unambiguous in match objects."
  (ogent-tool-process-tests--with-directory
    (let* ((file (ogent-tool-process-tests--write
                  directory "a: b\n-c.txt" "before\nneedle:colon\nafter\n"))
           (result (ogent-tool-process-grep "needle" nil nil 1))
           (match (aref (plist-get result :matches) 0)))
      (should (equal (plist-get match :path) file))
      (should (= (plist-get match :line) 2))
      (should (equal (plist-get match :text) "needle:colon"))
      (should (equal (plist-get match :context_before)
                     [(:line 1 :text "before")]))
      (should (equal (plist-get match :context_after)
                     [(:line 3 :text "after")])))))

(ert-deftest ogent-tool-process-grep-deterministic-order ()
  "Sort pages by absolute path and then increasing source line."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "z.txt" "needle\n")
    (ogent-tool-process-tests--write directory "a.txt" "x\nneedle\nneedle\n")
    (let ((matches (plist-get (ogent-tool-process-grep "needle") :matches)))
      (should (= (length matches) 3))
      (should (string-suffix-p "/a.txt" (plist-get (aref matches 0) :path)))
      (should (= (plist-get (aref matches 0) :line) 2))
      (should (= (plist-get (aref matches 1) :line) 3))
      (should (string-suffix-p "/z.txt" (plist-get (aref matches 2) :path))))))

(ert-deftest ogent-tool-process-grep-directory-spans-argument-batches ()
  "Preserve the count and order when a directory needs multiple grep processes."
  (ogent-tool-process-tests--with-directory
    (dotimes (index 180)
      (ogent-tool-process-tests--write directory (format "%03d.txt" index) "needle\n"))
    (let* ((result (ogent-tool-process-grep "needle" nil nil 0 120 40))
           (matches (plist-get result :matches)))
      (should (= (plist-get result :total_matches) 180))
      (should (= (length matches) 40))
      (should (= (plist-get result :next_offset) 160))
      (should (string-suffix-p "/120.txt" (plist-get (aref matches 0) :path)))
      (should (string-suffix-p "/159.txt" (plist-get (aref matches 39) :path))))))

(ert-deftest ogent-tool-process-grep-context-includes-nearby-matches ()
  "Include neighboring matched lines once in each applicable context vector."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "one\nneedle1\nneedle2\nfour\n")
    (let* ((result (ogent-tool-process-grep "needle" nil nil 1))
           (matches (plist-get result :matches)))
      (should (= (plist-get result :total_matches) 2))
      (should (equal (plist-get (aref matches 0) :context_after)
                     [(:line 3 :text "needle2")]))
      (should (equal (plist-get (aref matches 1) :context_before)
                     [(:line 2 :text "needle1")])))))

(ert-deftest ogent-tool-process-grep-empty-is-success ()
  "Return an empty vector and zero count for a successful no-match search."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "unrelated\n")
    (let ((result (ogent-tool-process-grep "needle")))
      (should (equal (plist-get result :matches) []))
      (should (= (plist-get result :total_matches) 0))
      (should (eq (plist-get result :has_more) :json-false)))))

(ert-deftest ogent-tool-process-grep-invalid-regex-error ()
  "Signal a corrective search error instead of presenting invalid regex as empty."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (let ((failure (should-error (ogent-tool-process-grep "[") :type 'user-error)))
      (should (string-match-p "pattern syntax" (error-message-string failure))))))

(ert-deftest ogent-tool-process-grep-empty-gnu-candidates-validate-regex ()
  "Validate GNU grep regex syntax even when a directory or filter yields no files."
  (let ((find-executable (symbol-function 'executable-find)))
    (ogent-tool-process-tests--with-directory
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &optional remote)
                   (unless (equal name "rg")
                     (funcall find-executable name remote)))))
	(should-error (ogent-tool-process-grep "[")
                      :type 'ogent-tool-process-search-failed)
	(ogent-tool-process-tests--write directory "a.txt" "needle\n")
	(should-error (ogent-tool-process-grep "[" nil "*.el")
                      :type 'ogent-tool-process-search-failed)
	(should (= (plist-get (ogent-tool-process-grep "needle" nil "*.el")
                              :total_matches) 0))))))

(ert-deftest ogent-tool-process-grep-pattern-is-literal-process-argument ()
  "Keep shell metacharacters in a search pattern from executing commands."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (ogent-tool-process-grep "needle; touch injected")
    (should-not (file-exists-p (expand-file-name "injected" directory)))))

(ert-deftest ogent-tool-process-grep-glob-filter ()
  "Apply the requested file glob without leaking unrelated matches."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.el" "needle\n")
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (let ((result (ogent-tool-process-grep "needle" nil "*.el")))
      (should (= (plist-get result :total_matches) 1))
      (should (string-suffix-p ".el"
                               (plist-get (aref (plist-get result :matches) 0) :path))))))

(ert-deftest ogent-tool-process-grep-gnu-explicit-file-filter ()
  "Apply filename globs to explicit GNU grep files, retaining regex validation."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-explicit-filter)))

(ert-deftest ogent-tool-process-grep-ripgrep-explicit-file-filter ()
  "Apply filename globs and literal filename escaping to explicit ripgrep files."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-explicit-filter)))

(ert-deftest ogent-tool-process-grep-gnu-binary-scope ()
  "Skip NUL-containing binary files through the real GNU grep engine."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-binary-scope)))

(ert-deftest ogent-tool-process-grep-ripgrep-binary-scope ()
  "Skip NUL-containing binary files through the real ripgrep engine."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-binary-scope)))

(ert-deftest ogent-tool-process-grep-gnu-component-filters ()
  "Match directory components and recursive wildcards through real GNU grep."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-component-filters)))

(ert-deftest ogent-tool-process-grep-ripgrep-component-filters ()
  "Match directory components and positive literal globs through real ripgrep."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-component-filters)))

(ert-deftest ogent-tool-process-grep-gnu-unicode-filters ()
  "Use Unicode character widths and classes through the real GNU grep engine."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-unicode-filters)))

(ert-deftest ogent-tool-process-grep-ripgrep-unicode-filters ()
  "Select Unicode filenames while retaining real ripgrep JSON and regex execution."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-unicode-filters)
    (ogent-tool-process-tests--with-directory
      (ogent-tool-process-tests--write directory "é.txt" "Ωneedle\n")
      (let ((result (ogent-tool-process-grep "\\p{L}+" directory "?.txt")))
        (should (equal (plist-get result :engine) "ripgrep-json"))
        (should (= (plist-get result :total_matches) 1))))))

(ert-deftest ogent-tool-process-grep-gnu-symlink-scope ()
  "Include file links consistently while ignoring directory and cyclic links."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-symlink-scope)))

(ert-deftest ogent-tool-process-grep-ripgrep-symlink-scope ()
  "Include file links consistently while ignoring directory and cyclic links."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-symlink-scope)))

(ert-deftest ogent-tool-process-grep-gnu-unsupported-filenames ()
  "Reject selected raw-byte filenames through real GNU grep candidate selection."
  (ogent-tool-process-tests--with-engine 'gnu
    (ogent-tool-process-tests--check-unsupported-filenames)))

(ert-deftest ogent-tool-process-grep-ripgrep-unsupported-filenames ()
  "Reject selected raw-byte filenames without silently dropping real rg candidates."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--check-unsupported-filenames)))

(ert-deftest ogent-tool-process-grep-ripgrep-cancel-cleans-selected-script ()
  "Cancel a real selected-file search once and remove its private script."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--with-directory
      (ogent-tool-process-tests--write directory "source.txt" "needle\n")
      (make-symbolic-link "source.txt" (expand-file-name "link.txt" directory))
      (let ((calls 0) failure process script)
        (unwind-protect
            (progn
              (setq process
                    (ogent-tool-process-grep-async
                     "needle" directory nil 0 0 10
                     (lambda (_data error-data)
                       (cl-incf calls) (setq failure error-data))))
              (should (processp process))
              (setq script (cadr (process-command process)))
              (should (file-exists-p script))
              (should (ogent-tool-process-cancel process))
              (should (= calls 1))
              (should (eq (car failure) 'ogent-tool-process-search-cancelled))
              (should-not (file-exists-p script))
              (should-not (process-buffer process))
              (should-not (assq process ogent-tools--active-processes))
              (accept-process-output nil 0.05)
              (should (= calls 1)))
          (ogent-tool-process-cancel process))))))

(ert-deftest ogent-tool-process-grep-ripgrep-selected-groups-preserve-pages ()
  "Retain ordered pagination across multiple real ripgrep filename groups."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--with-directory
      (dotimes (index 180)
        (ogent-tool-process-tests--write directory (format "%03d.txt" index) "needle\n"))
      (let* ((result (ogent-tool-process-grep "needle" directory "[0-9]*.txt" 0 120 40))
             (matches (plist-get result :matches)))
        (should (= (plist-get result :total_matches) 180))
        (should (= (length matches) 40))
        (should (= (plist-get result :next_offset) 160))
        (should (string-suffix-p "/120.txt" (plist-get (aref matches 0) :path)))
        (should (string-suffix-p "/159.txt" (plist-get (aref matches 39) :path)))))))

(ert-deftest ogent-tool-process-grep-ripgrep-selected-parent-order ()
  "Page globally ordered results across root, nested and repeated root groups."
  (ogent-tool-process-tests--with-engine 'ripgrep
    (ogent-tool-process-tests--with-directory
      (dolist (name '("a.txt" "a/é.txt" "z.txt"))
        (ogent-tool-process-tests--write directory name "needle\n"))
      (let ((first (ogent-tool-process-grep "needle" directory "?.txt" 0 0 2))
            (last (ogent-tool-process-grep "needle" directory "?.txt" 0 2 2)))
        (should (equal
                 (mapcar (lambda (match)
                           (file-relative-name (plist-get match :path) directory))
                         (append (plist-get first :matches) nil))
                 '("a.txt" "a/é.txt")))
        (should (string-suffix-p "/z.txt"
                                 (plist-get (aref (plist-get last :matches) 0) :path)))
        (should (= (plist-get first :total_matches) 3))
        (should (= (plist-get first :next_offset) 2))
        (should (equal (plist-get first :snapshot) (plist-get last :snapshot))))
      ;; A no-match first group must not prevent matching later parents.
      (ogent-tool-process-tests--write directory "a.txt" "unrelated\n")
      (should (= (plist-get (ogent-tool-process-grep "needle" directory "?.txt")
                            :total_matches) 2)))))

(ert-deftest ogent-tool-process-grep-finds-hidden-and-ignored-files ()
  "Search hidden and ignored source files consistently while excluding Git storage."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory ".hidden" "needle\n")
    (ogent-tool-process-tests--write directory ".gitignore" "ignored.txt\n")
    (ogent-tool-process-tests--write directory "ignored.txt" "needle\n")
    (ogent-tool-process-tests--write directory ".git/objects/blob" "needle\n")
    (should (= (plist-get (ogent-tool-process-grep "needle") :total_matches) 2))))

(ert-deftest ogent-tool-process-grep-truncation-keeps-count-and-page ()
  "Bound match and context text while retaining accurate pagination and counts."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "before\nneedle\nafter\nneedle\n")
    (let* ((ogent-tools-max-output-chars 5)
           (result (ogent-tool-process-grep "needle" nil nil 1 0 1))
           (match (aref (plist-get result :matches) 0)))
      (should (eq (plist-get result :truncated) t))
      (should (= (plist-get result :total_matches) 2))
      (should (= (plist-get result :next_offset) 1))
      (should (eq (plist-get match :truncated) t))
      (should (<= (+ (length (plist-get match :text))
                     (cl-loop for entry across (plist-get match :context_before)
                              sum (length (plist-get entry :text)))
                     (cl-loop for entry across (plist-get match :context_after)
                              sum (length (plist-get entry :text)))) 5)))))

(ert-deftest ogent-tool-process-grep-zero-budget-does-not-skip-matches ()
  "Return every requested match identity with explicit truncation at zero budget."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle1\nneedle2\nneedle3\n")
    (let* ((ogent-tools-max-output-chars 0)
           (result (ogent-tool-process-grep "needle" nil nil 0 0 2))
           (matches (plist-get result :matches)))
      (should (equal (plist-get result :path)
                     (file-name-as-directory directory)))
      (should (= (length matches) 2))
      (should (= (plist-get result :next_offset) 2))
      (should (= (plist-get (aref matches 0) :line) 1))
      (should (= (plist-get (aref matches 1) :line) 2))
      (dotimes (index 2)
	(should (equal (plist-get (aref matches index) :text) ""))
	(should (eq (plist-get (aref matches index) :truncated) t))))))

(ert-deftest ogent-tool-process-grep-snapshot-changes-with-source ()
  "Change the snapshot when searched match text changes."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle1\n")
    (let ((before (plist-get (ogent-tool-process-grep "needle") :snapshot)))
      (ogent-tool-process-tests--write directory "a.txt" "needle2\n")
      (should-not (equal before
                         (plist-get (ogent-tool-process-grep "needle") :snapshot))))))

(ert-deftest ogent-tool-process-grep-validates-page-and-context ()
  "Reject ambiguous page values and unbounded context before launching."
  (ogent-tool-process-tests--with-directory
    (dolist (args '((0 -1 10) (0 0 0) (0 0 201) (21 0 10) (-1 0 10)))
      (should-error (apply #'ogent-tool-process-grep "needle" nil nil args)
                    :type 'user-error))))

(ert-deftest ogent-tool-process-grep-oversized-wire-line-is-explicit ()
  "Fail explicitly on a huge source line instead of silently losing match counts."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt"
                                     (concat "needle" (make-string 1100000 ?x) "\n"))
    (let ((failure (should-error (ogent-tool-process-grep "needle")
                                 :type 'ogent-tool-process-output-error)))
      (should (string-match-p "read the file directly" (error-message-string failure))))))

(ert-deftest ogent-tool-process-grep-async-once ()
  "Deliver one asynchronous match page and remove the active process entry."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (let ((calls 0) result failure process)
      (unwind-protect
          (progn
            (setq process
                  (ogent-tool-process-grep-async
                   "needle" nil nil 0 0 200
                   (lambda (data error-data)
                     (cl-incf calls) (setq result data failure error-data))))
            (should (processp process))
            (should (= calls 0))
            (should (ogent-tool-process-tests--wait (lambda () (= calls 1))))
            (should-not failure)
            (should (= (plist-get result :total_matches) 1))
            (should-not (assq process ogent-tools--active-processes))
            (accept-process-output nil 0.05)
            (should (= calls 1)))
	(ogent-tool-process-cancel process)))))

(ert-deftest ogent-tool-process-grep-timeout-has-typed-error ()
  "Reject an incomplete timed-out search with a stable condition and recovery hint."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt"
                                     (apply #'concat (make-list 20000 "needle\n")))
    (let ((ogent-tools-grep-timeout 0.001))
      (let ((failure (should-error (ogent-tool-process-grep "needle")
                                   :type 'ogent-tool-process-search-timeout)))
	(should (string-match-p "narrow path" (error-message-string failure)))))))

(ert-deftest ogent-tool-process-grep-cancel-has-typed-error ()
  "Deliver a typed cancellation once and immediately clean the search registration."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (let ((calls 0) failure process)
      (setq process
            (ogent-tool-process-grep-async
             "needle" nil nil 0 0 10
             (lambda (data error-data)
               (cl-incf calls) (should-not data) (setq failure error-data))))
      (should (ogent-tool-process-cancel process))
      (should (= calls 1))
      (should (eq (car failure) 'ogent-tool-process-search-cancelled))
      (should-not (assq process ogent-tools--active-processes))
      (accept-process-output nil 0.05)
      (should (= calls 1)))))

(ert-deftest ogent-tool-process-results-serialize-as-json ()
  "Serialize shell and search collections with explicit booleans and nulls."
  (ogent-tool-process-tests--with-directory
    (ogent-tool-process-tests--write directory "a.txt" "needle\n")
    (dolist (result (list (ogent-tool-process-bash "printf x")
                          (ogent-tool-process-grep "needle")))
      (let ((json (json-serialize result :null-object :json-null
                                  :false-object :json-false)))
	(should (stringp json))
	(should-not (string-match-p ":json-" json))))))

(ert-deftest ogent-tool-process-ripgrep-base64-text ()
  "Decode ripgrep base64 fields including filename punctuation without guessing."
  (should (equal (ogent-tool-process--json-text
                  (list :bytes (base64-encode-string "a:\nb" t)))
                 "a:\nb")))

(ert-deftest ogent-tool-process-ripgrep-real-json-protocol ()
  "Decode actual ripgrep JSON with ordered pages and unusual filename context."
  (let ((rg (or (getenv "OGENT_PROCESS_TEST_RG") (executable-find "rg")))
        (find-executable (symbol-function 'executable-find)))
    (skip-unless (and rg (file-executable-p rg)))
    (ogent-tool-process-tests--with-directory
      (let ((file (ogent-tool-process-tests--write
                   directory "a:\nb.txt" "before\nneedle1\nneedle2\nafter\n")))
	(cl-letf (((symbol-function 'executable-find)
                   (lambda (name &optional remote)
                     (if (equal name "rg") rg
                       (funcall find-executable name remote)))))
          (let* ((result (ogent-tool-process-grep "needle" nil nil 1 0 1))
                 (match (aref (plist-get result :matches) 0))
                 (last (ogent-tool-process-grep "needle" nil nil 1 1 1)))
            (should (equal (plist-get result :engine) "ripgrep-json"))
            (should (= (plist-get result :total_matches) 2))
            (should (equal (plist-get match :path) file))
            (should (equal (plist-get match :context_after)
                           [(:line 3 :text "needle2")]))
            (should (equal (plist-get result :snapshot)
                           (plist-get last :snapshot)))))))))

(ert-deftest ogent-tool-process-ripgrep-searches-hidden-files ()
  "Keep hidden and ignored file behavior identical in the real ripgrep engine."
  (let ((rg (or (getenv "OGENT_PROCESS_TEST_RG") (executable-find "rg")))
        (find-executable (symbol-function 'executable-find)))
    (skip-unless (and rg (file-executable-p rg)))
    (ogent-tool-process-tests--with-directory
      (ogent-tool-process-tests--write directory ".hidden" "needle\n")
      (ogent-tool-process-tests--write directory ".gitignore" "ignored.txt\n")
      (ogent-tool-process-tests--write directory "ignored.txt" "needle\n")
      (ogent-tool-process-tests--write directory ".git/objects/blob" "needle\n")
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &optional remote)
                   (if (equal name "rg") rg
                     (funcall find-executable name remote)))))
	(should (= (plist-get (ogent-tool-process-grep "needle") :total_matches) 2))))))

(provide 'ogent-tool-process-tests)
;;; ogent-tool-process-tests.el ends here

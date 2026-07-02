;;; ogent-test-helper.el --- Test bootstrap for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides helper utilities to load project code and execute ert suites.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'org)

;; Batch test runs must never block on Org's interactive prompt
;;   "Non-existent agenda file ... [R]emove from list or [A]bort?"
;; Suites create and tear down temporary Org trees, so a stale entry can
;; outlive its file; Emacs 29's bundled Org raises that prompt (Emacs 30
;; does not), which hangs `emacs --batch' forever on `read-char'.  Skip
;; unreadable agenda files, and make `org-check-agenda-file' non-interactive
;; so the prompt can never fire regardless of the calling path.
(require 'org-agenda nil t)
(setq org-agenda-skip-unavailable-files t)

(defun ogent-test--silence-agenda-check (orig file)
  "Batch-safe `org-check-agenda-file': never prompt for a missing FILE.
Validate an existing FILE through ORIG; for a missing FILE, drop it from
`org-agenda-files' (Org's non-destructive [R]emove choice) and return nil
instead of reading a keystroke."
  (if (file-exists-p file)
      (funcall orig file)
    (when (boundp 'org-agenda-files)
      (setq org-agenda-files (delete file org-agenda-files)))
    nil))

(advice-add 'org-check-agenda-file :around #'ogent-test--silence-agenda-check)

;; Preload jka-compr while .elc is still in `load-suffixes'.  Without
;; this, the exclusion below leaves only compressed built-in sources
;; (e.g. face-remap.el.gz on Nix Emacs) loadable via jka-compr, whose
;; own source is also compressed - requiring it then recurses fatally
;; ("Recursive load ... jka-compr.el.gz").
(require 'jka-compr)

;; Exclude .elc from load-suffixes so stale bytecode (which may embed
;; outdated macro expansions, e.g. magit-insert-section) is never loaded.
;; load-prefer-newer alone is insufficient: it still picks a newer .elc
;; over .el, but the .elc may contain stale inlined forms.
(setq load-suffixes (remove ".elc" load-suffixes))

(defconst ogent-test-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Absolute path to the ogent/test directory.")

(defconst ogent-project-root
  (expand-file-name ".." ogent-test-root)
  "Absolute path to the ogent project root from tests.")

(add-to-list 'load-path (expand-file-name "lisp" ogent-project-root))
(add-to-list 'load-path (expand-file-name "lisp/ui" ogent-project-root))
(add-to-list 'load-path ogent-test-root)
(add-to-list 'load-path (expand-file-name "ui" ogent-test-root))

(defvar transient-history-file)
(defvar transient-save-history)

(defconst ogent-test-transient-history-file
  (make-temp-file "ogent-transient-history")
  "Scratch Transient history file used by batch tests.")

(with-temp-file ogent-test-transient-history-file
  (insert "nil\n"))

(setq transient-history-file ogent-test-transient-history-file)
(setq transient-save-history nil)

;; Auto-detect magit-section from Doom Emacs straight builds.
;; Prefer the sandbox/local Compat package when it already provides compat-31.
;; Pick the highest-versioned build dir available (exact version may not match).
(unless (featurep 'magit-section)
  (let* ((straight-dir (expand-file-name
                        ".local/share/doom/straight/"
                        (getenv "HOME")))
         (build-dir
          (when (file-directory-p straight-dir)
            (car (last (sort
                        (seq-filter
                         (lambda (d)
                           (and (string-match-p "^build-[0-9]" d)
                                (not (string-match-p "\\.el$" d))
                                (file-directory-p
                                 (expand-file-name d straight-dir))))
                         (directory-files straight-dir))
                        #'string<)))))
         (doom-build (when build-dir
                       (expand-file-name build-dir straight-dir)))
         (deps (append (unless (locate-library "compat-31")
                         '("compat"))
                       '("dash" "seq" "magit-section"))))
    (when doom-build
      (let ((repos-dir (expand-file-name "repos" straight-dir)))
        (dolist (dep deps)
          (let ((dep-dir (expand-file-name dep doom-build)))
            (when (file-directory-p dep-dir)
              (add-to-list 'load-path dep-dir)))
          ;; Prefer repo source over stale bytecode for magit-section.
          ;; The build dir .elc may be compiled from an older source,
          ;; and load-prefer-newer cannot distinguish when timestamps match.
          (when (equal dep "magit-section")
            (let ((src-dir (expand-file-name "magit/lisp" repos-dir)))
              (when (file-directory-p src-dir)
                (add-to-list 'load-path src-dir)))))))))

(unless (featurep 'gptel)
  (provide 'gptel))

(dolist (feature '(gptel-openai gptel-anthropic))
  (unless (featurep feature)
    (provide feature)))

(unless (fboundp 'gptel-with-preset)
  (defmacro gptel-with-preset (_preset &rest body)
    "Fallback macro for tests when gptel isn't installed."
    `(progn ,@body)))

(unless (fboundp 'gptel-request)
  (defun gptel-request (_prompt &rest _args)
    (error "gptel-request stub not overridden in tests")))

;; Define gptel variables that ogent-ui references
(defvar gptel-tools nil
  "Test stub for gptel-tools.")
(defvar gptel-use-tools nil
  "Test stub for gptel-use-tools.")

;;; Mocking utilities
;;
;; These macros/functions make it easy to mock gptel and other external
;; dependencies using cl-letf. See elisp-handbook.org for best practices.

(defvar ogent-test--captured-requests nil
  "Captures requests made during tests.")

(defmacro ogent-test-with-mock-gptel (&rest body)
  "Execute BODY with gptel-request mocked to capture and simulate responses.
Access captured data via `ogent-test--captured-requests'.
Automatically calls the callback with success if provided."
  (declare (indent 0) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (funcall callback "Mock response" nil)
                    (funcall callback nil '(:done t)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-streaming-mock (chunks &rest body)
  "Execute BODY with gptel-request mocked to stream CHUNKS.
CHUNKS is a list of strings to send via the callback."
  (declare (indent 1) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (dolist (chunk ,chunks)
                      (funcall callback chunk nil))
                    (funcall callback nil '(:done t)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-error-mock (error-message &rest body)
  "Execute BODY with gptel-request mocked to simulate an error.
ERROR-MESSAGE is the error string returned via callback."
  (declare (indent 1) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (funcall callback nil (list :error ,error-message)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-timeout-mock (&rest body)
  "Execute BODY with gptel-request mocked to simulate a timeout (no callback)."
  (declare (indent 0) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  ;; Don't call callback - simulates hung request
                  'mock-request)))
       ,@body)))

(defun ogent-test-last-request ()
  "Return the most recent captured request, or nil."
  (car ogent-test--captured-requests))

(defun ogent-test-request-count ()
  "Return the number of captured requests."
  (length ogent-test--captured-requests))

;;; Simulated input for interactive function testing
;;
;; Uses `with-simulated-input` package when available.
;; See: https://github.com/DarwinAwardWinner/with-simulated-input

(defvar ogent-test--simulated-input-available nil
  "Non-nil when `with-simulated-input' is available.")

(condition-case nil
    (progn
      (require 'with-simulated-input)
      (setq ogent-test--simulated-input-available t))
  (error nil))

(defmacro ogent-test-with-input (keys &rest body)
  "Execute BODY with simulated keyboard input KEYS.
If `with-simulated-input' is not available, skip the test.
KEYS is a string like \"hello RET\" or a list of inputs."
  (declare (indent 1) (debug t))
  (if ogent-test--simulated-input-available
      `(with-simulated-input ,keys ,@body)
    `(ert-skip "with-simulated-input package not available")))

(defun ogent-test-with-org-file (file fn)
  "Open FILE contents in a temporary Org buffer and run FN."
  (let ((buffer (generate-new-buffer " *ogent-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert-file-contents file)
          (org-mode)
          (funcall fn))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-test-with-fixture (relative-path fn)
  "Execute FN inside the Org fixture at RELATIVE-PATH."
  (ogent-test-with-org-file
   (expand-file-name relative-path ogent-test-root)
   fn))

(defun ogent-test--files ()
  "Return every ert test file under `test/'."
  (directory-files-recursively ogent-test-root "-tests\\.el$"))

(defun ogent-test-load (file)
  "Load FILE relative to the project root."
  (load file nil 'nomessage))

;;;###autoload
(defun ogent-run-tests ()
  "Load every ogent test file then run ert suites."
  (interactive)
  (mapc #'ogent-test-load (ogent-test--files))
  (ert-run-tests-batch-and-exit t))

(provide 'ogent-test-helper)

;;; ogent-test-helper.el ends here

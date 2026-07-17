;;; ogent-ui-armory-tests.el --- Tests for richer Armory UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Armory agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-status)
(require 'ogent-ui-armory)
(require 'ogent-armory-schedule)
(require 'ogent-armory-ql)

(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function magit-current-section "ext:magit-section" t t)
(declare-function magit-section-hidden-body "ext:magit-section")

(defmacro ogent-ui-armory-test-with-temp-dir (var &rest body)
  "Bind VAR to a provisioned Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename (directory-file-name
                               (ogent-test--provision-store-directory
                                'ui-armory)))))
     ,@body))

(defun ogent-ui-armory-test--write-session
    (root agent-slug name status exit-status &optional job-id finished trace)
  "Write a Armory session fixture for AGENT-SLUG under ROOT."
  (let* ((session-dir (expand-file-name
                       "sessions"
                       (ogent-armory-agent-directory root agent-slug)))
         (file (expand-file-name (concat name ".org") session-dir)))
    (make-directory session-dir t)
    (ogent-armory--write-file
     file
     (concat
      (format "#+title: %s\n\n" name)
      (format "* %s %s\n" status name)
      (ogent-armory--format-properties
       `(("OGENT_SESSION" . t)
         ("OGENT_AGENT" . ,agent-slug)
         ("OGENT_PROVIDER" . "codex")
         ("OGENT_MODEL" . "gpt-5.4")
         ("OGENT_JOB_ID" . ,(or job-id ""))
         ("OGENT_EXIT_STATUS" . ,exit-status)
         ("OGENT_DURATION" . "1.4s")
         ("OGENT_WORKSPACE" . ,root)
         ("OGENT_FINISHED" . ,(or finished "2026-05-04T09:00:00-0700"))))
      "\n** Prompt\n#+begin_src text\nReview the project.\n#+end_src\n"
      "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"
      (when trace
        (concat "\n** Runtime Trace\n#+begin_src text\n"
                trace
                "#+end_src\n"))))
    file))

(defun ogent-ui-armory-test--seed (root)
  "Create a Armory fixture in ROOT."
  (ogent-armory-scaffold root "Zorp" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
   root
   '(:slug "cto"
           :name "CTO"
           :role "Architecture"
           :provider "codex"
           :model "gpt-5.4"
           :active t
           :workspace "engineering"
           :tags ("strategy" "architecture"))
   "Keep the technical plan clear.")
  (ogent-armory-write-job
   root "cto"
   '(:id "weekly-review"
         :name "Weekly Review"
         :cron "0 9 * * 1"
         :enabled t)
   "Review architecture notes.")
  (ogent-armory-write-job
   root "cto"
   '(:id "old-report"
         :name "Old Report"
         :cron ""
         :enabled nil)
   "Archived job.")
  (ogent-ui-armory-test--write-session
   root "cto" "weekly-review-run" "DONE" 0 "weekly-review")
  (ogent-ui-armory-test--write-session
   root "cto" "failed-run" "FAILED" 1 "weekly-review"))

(defun ogent-ui-armory-test--assert-bindings (map bindings)
  "Assert MAP binds every (KEY . COMMAND) in BINDINGS."
  (dolist (pair bindings)
    (should (eq (lookup-key map (kbd (car pair)))
                (cdr pair)))))

(defun ogent-ui-armory-test--lookup-direct (map key)
  "Return MAP's direct binding for KEY, ignoring inherited parent maps."
  (let ((parent (keymap-parent map)))
    (unwind-protect
        (progn
          (set-keymap-parent map nil)
          (lookup-key map (kbd key)))
      (set-keymap-parent map parent))))

(defun ogent-ui-armory-test--assert-unbound (map keys)
  "Assert MAP has no direct command binding for any key in KEYS."
  (dolist (key keys)
    (let ((binding (ogent-ui-armory-test--lookup-direct map key)))
      (should (or (null binding) (numberp binding))))))

(defun ogent-ui-armory-test--rendered-header-line ()
  "Return the current buffer's header line as plain text."
  (substring-no-properties
   (cond
    ((and (consp header-line-format)
          (eq (car header-line-format) :eval))
     (eval (cadr header-line-format) t))
    ((stringp header-line-format)
     header-line-format)
    (t
     (format "%s" header-line-format)))))

(ert-deftest ogent-ui-armory-agents-mode-keybindings ()
  "Agent list mode exposes the bare-key Armory navigation contract."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-agents-mode-map
   `(("RET" . ,#'ogent-armory-agents-open-agent)
     ("v" . ,#'ogent-armory-agents-visit)
     ("R" . ,#'ogent-armory-agents-run)
     ("g" . ,#'ogent-armory-agents-refresh)
     ("?" . ,#'ogent-armory-agents-dispatch)
     ("n" . ,#'ogent-armory-ui-next-item)
     ("p" . ,#'ogent-armory-ui-previous-item)
     ("j" . ,ogent-armory-jump-map)
     ("," . ,#'ogent-armory-settings)
     ("/" . ,#'ogent-armory-command-palette)
     ("q" . ,#'quit-window)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-agents-mode-map
   '("C-c v" "C-c r")))

(ert-deftest ogent-ui-armory-home-renders-operational-overview ()
  "Armory Home is the single operational entry point for daily work."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html>")
      (setq buffer (ogent-armory-home root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-home-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Armory Home" "Health" "Navigate" "Recent Activity"
                               "Active Jobs" "Needs Attention" "Agents" "Jobs"
                               "Tasks" "Conversations"
                               "Data" "Search" "Apps" "Git" "Palette"
                               "Settings" "Help" "Graph" "Armory metadata"
                               "Source Org"))
                (should (string-match-p label text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "\\[R run\\]" text))
              (should (string-match-p "\\[E prompt\\]" text))
              (should (string-match-p "\\[J jobs\\]" text))
              (should (string-match-p "\\[j a\\] Agents" text))
              (should (string-match-p "\\[j t\\] Tasks" text))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "app artifacts: 1" text))
              (should-not (string-match-p "\\[C-c r run\\]" text)))
            (let ((header (ogent-ui-armory-test--rendered-header-line)))
              (dolist (key '("?:menu" "j:jump" "g:refresh"))
                (should (string-match-p (regexp-quote key) header)))
              (should-not (string-match-p "C-c" header))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-home-daily-work-keybindings ()
  "Armory Home exposes daily-work actions and shared jumps without C-c clones."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-home-mode-map
   `(("?" . ,#'ogent-armory-home-dispatch)
     ("j" . ,ogent-armory-jump-map)
     ("/" . ,#'ogent-armory-command-palette)
     ("," . ,#'ogent-armory-settings)
     ("g" . ,#'ogent-armory-home-refresh)
     ("q" . ,#'quit-window)
     ("R" . ,#'ogent-armory-home-run)
     ("E" . ,#'ogent-armory-home-edit-item)
     ("e" . ,#'ogent-armory-home-edit-metadata)
     ("J" . ,#'ogent-armory-home-open-jobs)
     ("n" . ,#'ogent-armory-home-next-item)
     ("p" . ,#'ogent-armory-home-previous-item)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-home-mode-map
   '("C-c m" "C-c ?" "C-c j" "C-c D" "C-c h" "C-c /" "C-c ,"
     "C-c ." "C-c r" "C-c E" "C-c J" "a" "t" "c" "s" "A" "D" "u" "h" "G")))

(ert-deftest ogent-ui-armory-section-keybindings-are-consistent ()
  "Armory section buffers expose shared section and jump/navigation keys."
  (dolist (map (list ogent-armory-home-mode-map
                     ogent-armory-org-chart-mode-map
                     ogent-armory-agent-mode-map
                     ogent-armory-conversation-mode-map))
    (ogent-ui-armory-test--assert-bindings
     map
     `(("TAB" . ,#'ogent-section-toggle)
       ("<tab>" . ,#'ogent-section-toggle)
       ("<backtab>" . ,#'ogent-section-cycle)
       ("M-n" . ,#'ogent-section-next)
       ("M-p" . ,#'ogent-section-prev)
       ("^" . ,#'ogent-section-up)
       ("j" . ,ogent-armory-jump-map)
       ("q" . ,#'quit-window))))
  (dolist (map (list ogent-armory-home-mode-map
                     ogent-armory-org-chart-mode-map
                     ogent-armory-agent-mode-map
                     ogent-armory-conversation-mode-map))
    (ogent-ui-armory-test--assert-unbound
     map
     '("C-c u" "C-c U"))))

(ert-deftest ogent-ui-armory-conversation-keybindings-cover-detail-actions ()
  "Conversation detail exposes its action surface on bare local keys."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-conversation-mode-map
   `(("RET" . ,#'ogent-armory-conversation-visit-source)
     ("v" . ,#'ogent-armory-conversation-visit-source)
     ("c" . ,#'ogent-armory-conversation-continue)
     ("k" . ,#'ogent-armory-conversation-stop)
     ("R" . ,#'ogent-armory-conversation-retry)
     ("d" . ,#'ogent-armory-conversation-mark-done)
     ("a" . ,#'ogent-armory-conversation-toggle-archive)
     ("m" . ,#'ogent-armory-conversation-mute)
     ("M" . ,#'ogent-armory-conversation-unmute)
     ("C" . ,#'ogent-armory-conversation-compact)
     ("D" . ,#'ogent-armory-conversation-delete)
     ("y" . ,#'ogent-armory-conversation-copy-link)
     ("o" . ,#'ogent-armory-conversation-open-artifacts)
     ("l" . ,#'ogent-armory-conversation-open-logs)
     ("?" . ,#'ogent-armory-conversation-dispatch)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-conversation-mode-map
   '("C-c c" "C-c k" "C-c r" "C-c d" "C-c a" "C-c u" "C-c U"
     "C-c m" "C-c M" "C-c C" "C-c D" "C-c y" "C-c o" "C-c l")))

(ert-deftest ogent-ui-armory-conversation-reader-prioritizes-output ()
  "Conversation detail opens as a reader with output before metadata."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let* ((path (expand-file-name ".agents/cto/sessions/weekly-review-run.org"
                                   root))
           (buffer (ogent-armory-conversation root path)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-conversation-mode))
            (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                   (output (string-match-p "Output" text))
                   (details (string-match-p "Details" text))
                   (prompt (string-match-p "Prompt" text)))
              (should output)
              (should details)
              (should prompt)
              (should (string-match-p "Done." text))
              (should (string-match-p "Source Org" text))
              (should (< output details))
              (should (< details prompt))
              (should-not (string-match-p "^Actions$" text)))
            (let ((header (ogent-ui-armory-test--rendered-header-line)))
              (dolist (key '("?:menu" "j:jump" "g:refresh"))
                (should (string-match-p (regexp-quote key) header)))
              (should-not (string-match-p "D delete" header))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-conversation-runtime-trace-is-previewed ()
  "Conversation detail summarizes long runtime traces."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Zorp" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Keep the technical plan clear.")
    (let* ((trace "line 1\nline 2\nline 3\nline 4\nline 5\n")
           (path (ogent-ui-armory-test--write-session
                  root "cto" "long-run" "DONE" 0 nil nil trace))
           (ogent-armory-conversation-runtime-trace-preview-lines 3)
           (buffer (ogent-armory-conversation root path)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Runtime Trace" text))
              (should (string-match-p "line 1" text))
              (should (string-match-p "line 3" text))
              (should-not (string-match-p "line 4" text))
              (should (string-match-p "2 more lines" text))
              (should (string-match-p "Press l for logs" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-section-modes-derive-from-magit-section ()
  "Armory section buffers inherit Magit section behavior when available."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (dolist (mode '(ogent-armory-home-mode
                  ogent-armory-org-chart-mode
                  ogent-armory-agent-mode
                  ogent-armory-conversation-mode))
    (with-temp-buffer
      (funcall mode)
      (should (derived-mode-p 'magit-section-mode)))))

(ert-deftest ogent-ui-armory-evil-installs-all-ui-keymaps ()
  "Armory UI maps install local Evil-safe dispatch keys."
  (let ((ogent-armory-home-mode-hook nil)
        (ogent-armory-agents-mode-hook nil)
        (ogent-armory-org-chart-mode-hook nil)
        (ogent-armory-agent-mode-hook nil)
        (ogent-armory-jobs-mode-hook nil)
        (ogent-armory-tasks-mode-hook nil)
        (ogent-armory-conversations-mode-hook nil)
        (ogent-armory-conversation-mode-hook nil)
        (ogent-armory-search-mode-hook nil)
        (ogent-armory-apps-mode-hook nil)
        states
        maps)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state)
                 (push (cons mode state) states)))
              ((symbol-function 'evil-make-overriding-map)
               (lambda (map state)
                 (push (cons map state) maps)))
              ((symbol-function 'evil-normalize-keymaps)
               (lambda (&rest _) nil)))
      (ogent-armory-ui--setup-evil))
    (dolist (mode '(ogent-armory-home-mode
                    ogent-armory-agents-mode
                    ogent-armory-org-chart-mode
                    ogent-armory-agent-mode
                    ogent-armory-jobs-mode
                    ogent-armory-tasks-mode
                    ogent-armory-conversations-mode
                    ogent-armory-conversation-mode
                    ogent-armory-search-mode
                    ogent-armory-apps-mode))
      (should (member (cons mode 'normal) states)))
    (dolist (map (list ogent-armory-home-mode-map
                       ogent-armory-agents-mode-map
                       ogent-armory-org-chart-mode-map
                       ogent-armory-agent-mode-map
                       ogent-armory-jobs-mode-map
                       ogent-armory-tasks-mode-map
                       ogent-armory-conversations-mode-map
                       ogent-armory-conversation-mode-map
                       ogent-armory-search-mode-map
                       ogent-armory-apps-mode-map))
      (should (member (cons map 'normal) maps))
      (should (member (cons map 'motion) maps)))
    (dolist (hook (list ogent-armory-home-mode-hook
                        ogent-armory-agents-mode-hook
                        ogent-armory-org-chart-mode-hook
                        ogent-armory-agent-mode-hook
                        ogent-armory-jobs-mode-hook
                        ogent-armory-tasks-mode-hook
                        ogent-armory-conversations-mode-hook
                        ogent-armory-conversation-mode-hook
                        ogent-armory-search-mode-hook
                        ogent-armory-apps-mode-hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(ert-deftest ogent-ui-armory-evil-local-keys-mirror-safe-home-keys ()
  "Legacy Evil local mirroring keeps only non-reserved Home bindings."
  (let (keys)
    (with-temp-buffer
      (ogent-armory-home-mode)
      (cl-letf (((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) keys))))
        (ogent-armory-ui--evil-local-keys)))
    (dolist (binding '(("RET" ogent-armory-home-visit)
                       ("<return>" ogent-armory-home-visit)
                       ("<kp-enter>" ogent-armory-home-visit)
                       ("TAB" ogent-section-toggle)
                       ("<tab>" ogent-section-toggle)
                       ("<backtab>" ogent-section-cycle)
                       ("M-n" ogent-section-next)
                       ("M-p" ogent-section-prev)
                       ("q" quit-window)
                       ("ZZ" quit-window)
                       ("ZQ" quit-window)))
      (dolist (state '(normal motion))
        (should (member (list state (kbd (car binding)) (cadr binding))
                        keys))))
    (dolist (binding '(("J" ogent-armory-home-open-jobs)
                       ("R" ogent-armory-home-run)
                       ("E" ogent-armory-home-edit-item)
                       ("?" ogent-armory-home-dispatch)
                       ("j" ogent-armory-jump-map)
                       ("g" ogent-armory-home-refresh)
                       ("," ogent-armory-settings)
                       ("/" ogent-armory-command-palette)))
      (dolist (state '(normal motion))
        (should-not (member (list state (kbd (car binding)) (cadr binding))
                            keys))))))

(ert-deftest ogent-ui-armory-home-magit-sections-collapse ()
  "Armory Home headings are real collapsible sections when Magit is present."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (let ((section (magit-current-section)))
              (should section)
              (should-not (magit-section-hidden-body section))
              (ogent-armory-ui-toggle-section)
              (should (magit-section-hidden-body section))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-home-navigation-skips-collapsed-sections ()
  "Armory Home item navigation ignores hidden section bodies."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (ogent-armory-ui-toggle-section)
            (goto-char (point-min))
            (search-forward "Source Org")
            (beginning-of-line)
            (ogent-armory-home-next-item)
            (should-not (invisible-p (point)))
            (should (eq (plist-get (ogent-armory-ui--item-at-point) :type)
                        'session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-and-conversation-sections-collapse ()
  "Agent and conversation detail buffers expose collapsible sections."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((agent-buffer (ogent-armory-agent root "cto"))
          (conversation-buffer
           (ogent-armory-conversation
            root
            (expand-file-name ".agents/cto/sessions/weekly-review-run.org"
                              root))))
      (unwind-protect
          (progn
            (with-current-buffer agent-buffer
              (goto-char (point-min))
              (search-forward "Inbox")
              (beginning-of-line)
              (let ((section (magit-current-section)))
                (should section)
                (ogent-armory-ui-toggle-section)
                (should (magit-section-hidden-body section))))
            (with-current-buffer conversation-buffer
              (goto-char (point-min))
              (search-forward "Prompt")
              (beginning-of-line)
              (let ((section (magit-current-section)))
                (should section)
                (ogent-armory-ui-toggle-section)
                (should (magit-section-hidden-body section)))))
        (dolist (buffer (list agent-buffer conversation-buffer))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-home-runs-and-edits-active-job ()
  "Armory Home can run a job and jump straight to its prompt."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root))
          called
          body-file)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-armory-run-job)
                       (lambda (run-root agent job-id)
                         (setq called (list run-root agent job-id)))))
              (ogent-armory-home-run))
            (should (equal called (list (file-truename root)
                                        "cto"
                                        "weekly-review")))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (ogent-armory-home-edit-item)
            (setq body-file buffer-file-name)
            (should (looking-at-p "Review architecture notes"))
            (should (equal (file-truename body-file)
                           (file-truename
                            (ogent-armory-job-file root "cto" "weekly-review")))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer (ogent-armory-job-file root "cto" "weekly-review"))
          (kill-buffer (get-file-buffer
                        (ogent-armory-job-file root "cto" "weekly-review"))))))))

(ert-deftest ogent-ui-armory-home-opens-jobs-focused ()
  "Armory Home opens the jobs surface from the selected job."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root))
          jobs-buffer)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (setq jobs-buffer (ogent-armory-home-open-jobs)))
            (with-current-buffer jobs-buffer
              (should (eq major-mode 'ogent-armory-jobs-mode))
              (should (equal (plist-get (tabulated-list-get-id) :job-id)
                             "weekly-review"))))
        (dolist (buf (list buffer jobs-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest ogent-ui-armory-home-help-and-transient-render ()
  "Armory Home help and transient menu render the bare-key contract."
  (save-window-excursion
    (ogent-armory-home-help)
    (with-current-buffer "*ogent-armory-home-help*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Armory Home" text))
        (should (string-match-p "R runs or retries" text))
        (should (string-match-p "J opens jobs related" text))
        (should (string-match-p "j h Home, j g Graph" text))
        (should (string-match-p ", opens Settings" text))
        (should (string-match-p "TAB toggles" text))
        (should (string-match-p "? opens the Transient menu" text))
        (should-not (string-match-p "C-c m opens" text)))))
  (unwind-protect
      (progn
        (transient-setup 'ogent-armory-home-dispatch)
        (should (get 'ogent-armory-home-dispatch 'transient--prefix)))
    (when transient-current-prefix
      (transient-quit-one))))

(ert-deftest ogent-ui-armory-agents-lists-personas ()
  "The Armory agents buffer lists personas with job and session counts."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agents root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agents-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Architecture" text))
              (should (string-match-p "codex" text))
              (should (string-match-p "gpt-5.4" text))
              (should (string-match-p "strategy" text))
              (should (string-match-p "2" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-profile-renders-sections ()
  "The single-agent profile includes the richer Armory sections."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agent-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Composer" "Inbox" "Conversations" "Recent Work"
                               "Schedule" "Memory" "Tools/Permissions" "Details"
                               "Persona Instructions"))
                (should (string-match-p label text)))
              (should (string-match-p "memory/context.org" text))
              (should (string-match-p "inbox.org" text))
              (should (string-match-p "schedule.org" text))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Keep the technical plan clear" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-profile-keybindings-are-discoverable ()
  "The single-agent profile advertises and binds its main actions."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-agent-mode-map
   `(("RET" . ,#'ogent-armory-agent-visit)
     ("c" . ,#'ogent-armory-agent-compose)
     ("e" . ,#'ogent-armory-agent-edit-property)
     ("R" . ,#'ogent-armory-agent-run-at-point)
     ("v" . ,#'ogent-armory-agent-visit)
     ("g" . ,#'ogent-armory-agent-refresh)
     ("?" . ,#'ogent-armory-agent-dispatch)
     ("n" . ,#'ogent-armory-ui-next-item)
     ("p" . ,#'ogent-armory-ui-previous-item)
     ("j" . ,ogent-armory-jump-map)
     ("q" . ,#'quit-window)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-agent-mode-map
   '("C-c c" "C-c e" "C-c r" "C-c v")))

(ert-deftest ogent-ui-armory-create-clone-and-archive-agent ()
  "Agent management commands create, clone, and deactivate Org personas."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional _initial _history default)
                 (cond
                  ((string-match-p "Name" prompt) "Researcher")
                  ((string-match-p "Slug" prompt) "researcher")
                  ((string-match-p "Role" prompt) "Research")
                  ((string-match-p "Provider" prompt) "codex")
                  ((string-match-p "Model" prompt) "gpt-5.4")
                  ((string-match-p "Workspace" prompt) "/")
                  ((string-match-p "Tags" prompt) "research, strategy")
                  ((string-match-p "Persona" prompt) "Read deeply.")
                  (t (or default "")))))
              ((symbol-function 'completing-read)
               (lambda (prompt collection &rest _)
                 (cond
                  ((string-match-p "Provider" prompt)
                   (should (member "codex-cli" collection))
                   "codex")
                  ((string-match-p "Model" prompt)
                   (should (member "gpt-5.4" collection))
                   "gpt-5.4")
                  (t (ert-fail (format "Unexpected completion: %s"
                                       prompt)))))))
      (ogent-armory-create-agent root))
    (should (file-exists-p (ogent-armory-agent-file root "researcher")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "cto-copy")))
      (ogent-armory-clone-agent root "cto"))
    (should (file-exists-p (ogent-armory-agent-file root "cto-copy")))
    (ogent-armory-archive-agent root "cto-copy")
    (let ((agent (ogent-armory-read-agent root "cto-copy")))
      (should-not (plist-get agent :active))
      (should (plist-get agent :archived)))))

(ert-deftest ogent-ui-armory-create-agent-prompts-use-default-values ()
  "Agent creation defaults do not become editable initial input."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let (calls completion-calls)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &optional initial history default inherit)
                   (push (list prompt initial history default inherit) calls)
                   (cond
                    ((string-match-p "Name" prompt) "Architecture Steward")
                    ((string-match-p "Slug" prompt) "architecture-steward")
                    ((string-match-p "Role" prompt) "Architecture")
                    ((string-match-p "Provider" prompt) "codex")
                    ((string-match-p "Model" prompt) "gpt-5.4")
                    ((string-match-p "Workspace" prompt) "/")
                    ((string-match-p "Tags" prompt) "architecture")
                    ((string-match-p "Persona" prompt) "Keep the project clear.")
                    (t ""))))
                ((symbol-function 'completing-read)
                 (lambda (prompt collection &optional _predicate _require-match
                                 _initial _history default _inherit)
                   (push (list prompt collection default) completion-calls)
                   (cond
                    ((string-match-p "Provider" prompt) "codex")
                    ((string-match-p "Model" prompt) "gpt-5.4")
                    (t (ert-fail (format "Unexpected completion: %s"
                                         prompt)))))))
        (ogent-armory-create-agent root))
      (dolist (label '("Slug" "Role" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (let ((provider-call (seq-find (lambda (entry)
                                       (string-match-p "Provider" (car entry)))
                                     completion-calls))
            (model-call (seq-find (lambda (entry)
                                    (string-match-p "Model" (car entry)))
                                  completion-calls)))
        (should provider-call)
        (should (member "codex-cli" (cadr provider-call)))
        (should model-call)
        (should (member "gpt-5.4" (cadr model-call))))
      (should (equal (plist-get (ogent-armory-read-agent root "architecture-steward")
                                :role)
                     "Architecture")))))

(ert-deftest ogent-ui-armory-create-agent-refreshes-open-home ()
  "Creating an agent refreshes an already-open Armory Home buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should (string-match-p "agents: 0"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max)))))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (prompt &optional _initial _history default)
                         (cond
                          ((string-match-p "Name" prompt) "Architecture Steward")
                          ((string-match-p "Slug" prompt) "architecture-steward")
                          ((string-match-p "Role" prompt) "Architecture")
                          ((string-match-p "Provider" prompt) "codex")
                          ((string-match-p "Model" prompt) "gpt-5.4")
                          ((string-match-p "Workspace" prompt) "/")
                          ((string-match-p "Tags" prompt) "architecture")
                          ((string-match-p "Persona" prompt) "Keep it clear.")
                          (t (or default "")))))
                      ((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Provider" prompt)
                           (should (member "codex-cli" collection))
                           "codex")
                          ((string-match-p "Model" prompt)
                           (should (member "gpt-5.4" collection))
                           "gpt-5.4")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-armory-create-agent root))
            (with-current-buffer buffer
              (should (string-match-p "agents: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-jobs-renders-and-edits-job-records ()
  "The jobs surface lists, toggles, and archives Org-backed jobs."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-jobs-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "old-report" text)))
            (should (eq (lookup-key ogent-armory-jobs-mode-map (kbd "P"))
                        #'ogent-armory-jobs-edit-prompt))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (let ((source (ogent-armory-job-file root "cto" "weekly-review")))
              (ogent-armory-jobs-edit-prompt)
              (should (equal (file-truename (buffer-file-name))
                             (file-truename source)))
              (should (looking-at-p "Review")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (ogent-armory-jobs-toggle-enabled)
              (should-not (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                     :enabled))
              (ogent-armory-jobs-archive)
              (should (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                 :archived))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-create-job-prompts-use-default-values ()
  "Job creation defaults do not become editable initial input."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let (calls)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &optional initial history default inherit)
                   (push (list prompt initial history default inherit) calls)
                   (cond
                    ((string-match-p "Job name" prompt) "Architecture Scan")
                    ((string-match-p "Job id" prompt) "architecture-scan")
                    ((string-match-p "Cron" prompt) "0 8 * * 1")
                    ((string-match-p "Heartbeat" prompt) "")
                    ((string-match-p "Provider" prompt) "")
                    ((string-match-p "Model" prompt) "")
                    ((string-match-p "Workspace" prompt) "/")
                    ((string-match-p "Tags" prompt) "architecture")
                    ((string-match-p "Prompt" prompt) "Review architecture docs.")
                    (t ""))))
                ((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (cond
                    ((string-match-p "Provider" prompt)
                     (should (member "codex-cli" collection))
                     "")
                    ((string-match-p "Model" prompt)
                     (should (member "gpt-5.4" collection))
                     "")
                    (t (ert-fail (format "Unexpected completion: %s"
                                         prompt)))))))
        (ogent-armory-create-job root "cto"))
      (dolist (label '("Job id" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (should (file-exists-p
               (ogent-armory-job-file root "cto" "architecture-scan"))))))

(ert-deftest ogent-ui-armory-create-job-refreshes-open-home ()
  "Creating a job refreshes an already-open Armory Home buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "architect"
             :name "Architect"
             :role "Architecture"
             :provider "codex"
             :model "gpt-5.4"
             :active t)
     "Keep the project structure legible.")
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 0"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max)))))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (prompt &optional _initial _history default)
                         (cond
                          ((string-match-p "Job name" prompt) "Daily Scan")
                          ((string-match-p "Job id" prompt) "daily-scan")
                          ((string-match-p "Cron" prompt) "0 8 * * *")
                          ((string-match-p "Heartbeat" prompt) "")
                          ((string-match-p "Provider" prompt) "")
                          ((string-match-p "Model" prompt) "")
                          ((string-match-p "Workspace" prompt) "/")
                          ((string-match-p "Tags" prompt) "architecture")
                          ((string-match-p "Prompt" prompt) "Review the Armory.")
                          (t (or default "")))))
                      ((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Provider" prompt)
                           (should (member "codex-cli" collection))
                           "")
                          ((string-match-p "Model" prompt)
                           (should (member "gpt-5.4" collection))
                           "")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-armory-create-job root "architect"))
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-new-scheduled-job-stays-inbox ()
  "A new scheduled job remains Inbox work until it has run and aged out."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "architect"
             :name "Architect"
             :role "Architecture"
             :provider "codex"
             :model "gpt-5.4"
             :active t)
     "Keep the project structure legible.")
    (ogent-armory-write-job
     root
     "architect"
     '(:id "fresh-scan"
           :name "Fresh Scan"
           :cron "0 8 * * 1"
           :enabled t)
     "Review the Armory.")
    (let ((job (ogent-armory-read-job root "architect" "fresh-scan")))
      (should-not (ogent-armory-ui--stale-job-p root job))
      (let ((item (ogent-armory-tasks--job-item root job)))
        (should (equal (plist-get item :lane) "Inbox"))
        (should (equal (plist-get item :state) "scheduled"))
        (should (equal (plist-get item :scheduled) "0 8 * * 1"))))
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (should-not
             (string-match-p "stale job Fresh Scan"
                             (buffer-substring-no-properties
                              (point-min)
                              (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-stale-scheduled-job-needs-reply ()
  "An overdue scheduled job appears as attention work."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "architect"
             :name "Architect"
             :role "Architecture"
             :provider "codex"
             :model "gpt-5.4"
             :active t)
     "Keep the project structure legible.")
    (ogent-armory-write-job
     root
     "architect"
     '(:id "fresh-scan"
           :name "Fresh Scan"
           :cron "0 8 * * 1"
           :enabled t)
     "Review the Armory.")
    (ogent-ui-armory-test--write-session
     root "architect" "fresh-scan-run" "DONE" 0 "fresh-scan"
     "2000-01-01T00:00:00-0000")
    (let* ((job (ogent-armory-read-job root "architect" "fresh-scan"))
           (item (ogent-armory-tasks--job-item root job)))
      (should (ogent-armory-ui--stale-job-p root job))
      (should (equal (plist-get item :lane) "Needs Reply"))
      (should (equal (plist-get item :state) "stale"))
      (should (plist-get item :stale)))))

(ert-deftest ogent-ui-armory-jobs-edit-validates-metadata-before-write ()
  "Interactive job metadata edits reject malformed values before touching Org."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_CRON"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "bad cron")))
              (let* ((error (should-error (ogent-armory-jobs-edit)
                                          :type 'user-error))
                     (message (cadr error)))
                (should (string-match-p "Malformed Armory job metadata" message))))
            (should (equal (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                      :cron)
                           "0 9 * * 1")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-conversations-list-and-detail ()
  "Conversation browser opens detail buffers with transcript metadata."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-conversations root))
          detail)
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-conversations-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "FAILED" text)))
            (goto-char (point-min))
            (search-forward "failed-run")
            (setq detail (ogent-armory-conversations-open))
            (with-current-buffer detail
              (should (eq major-mode 'ogent-armory-conversation-mode))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (dolist (label '("Details" "Prompt" "Output" "Source Org"
                                 "Exit status" "Duration" "Agent" "Job"))
                  (should (string-match-p label text))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-armory-canonical-conversation-list-and-detail ()
  "Conversation browser reads canonical Org conversation records."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (ogent-armory-conversation-create
     root
     '(:id "conv-ui"
           :agent "cto"
           :title "Canonical Review"
           :status "done"
           :provider "codex"
           :model "gpt-5.4"
           :started "2026-05-06T10:00:00Z"
           :completed "2026-05-06T10:01:00Z"
           :duration "1s"
           :artifact-paths ("apps/report")))
    (ogent-armory-conversation-append-turn
     root "conv-ui" "user" "Review this."
     :ts "2026-05-06T10:00:00Z")
    (ogent-armory-conversation-append-turn
     root "conv-ui" "agent" "Looks solid."
     :ts "2026-05-06T10:01:00Z")
    (ogent-armory-conversation-append-event
     root "conv-ui" "task.updated"
     :ts "2026-05-06T10:01:00Z"
     :payload "status=done")
    (let ((buffer (ogent-armory-conversations root))
          detail)
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties
                         (point-min)
                         (point-max))))
              (should (string-match-p "Canonical Review" text))
              (should (string-match-p "DONE" text)))
            (goto-char (point-min))
            (search-forward "Canonical Review")
            (setq detail (ogent-armory-conversations-open))
            (with-current-buffer detail
              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (dolist (label '("Turns" "Artifacts" "Events" "Details"))
                  (should (string-match-p label text)))
                (should-not (string-match-p "^Actions$" text))
                (should (string-match-p "Review this" text))
                (should (string-match-p "Looks solid" text))
                (should (string-match-p "apps/report" text))
                (should (string-match-p "task.updated" text))
                (should (string-match-p "gpt-5.4" text)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-armory-conversation-actions-update-canonical-org ()
  "Conversation detail actions mutate canonical Org metadata and events."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-armory-conversation-create
                 root
                 '(:id "conv-actions"
                       :agent "cto"
                       :title "Action Review"
                       :status "awaiting-input"
                       :awaiting-input t
                       :provider "codex"))))
      (ogent-armory-conversation-append-turn
       root "conv-actions" "user" "Review this."
       :ts "2026-05-06T10:00:00Z")
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (ogent-armory-conversation-mute)
              (should (plist-get (ogent-armory-conversation-read
                                  root "conv-actions")
                                 :muted))
              (ogent-armory-conversation-mark-done)
              (let ((record (ogent-armory-conversation-read
                             root "conv-actions")))
                (should (equal (plist-get record :status) "done"))
                (should-not (plist-get record :awaiting-input)))
              (ogent-armory-conversation-compact "Short digest")
              (should (equal (plist-get (ogent-armory-conversation-read
                                         root "conv-actions")
                                        :context-summary)
                             "Short digest"))
              (ogent-armory-conversation-archive)
              (should (plist-get (ogent-armory-conversation-read
                                  root "conv-actions")
                                 :archived))
              (ogent-armory-conversation-unarchive)
              (should-not (plist-get (ogent-armory-conversation-read
                                      root "conv-actions")
                                     :archived))
              (let ((events (mapcar
                             (lambda (event)
                               (plist-get event :type))
                             (ogent-armory-conversation-read-events
                              root "conv-actions"))))
                (dolist (event '("conversation.muted"
                                 "conversation.marked_done"
                                 "conversation.compacted"
                                 "conversation.archived"
                                 "conversation.unarchived"))
                  (should (member event events)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversation-continue-replays-canonical-turns ()
  "Continuation builds a replay prompt and keeps the canonical id."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-armory-conversation-create
                 root
                 '(:id "conv-continue"
                       :agent "cto"
                       :title "Continue Review"
                       :status "done"
                       :provider "codex")))
          captured)
      (ogent-armory-conversation-append-turn
       root "conv-continue" "user" "Initial ask."
       :ts "2026-05-06T10:00:00Z")
      (ogent-armory-conversation-append-turn
       root "conv-continue" "agent" "Initial answer."
       :ts "2026-05-06T10:01:00Z")
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'ogent-armory-runner--confirm)
                         (lambda (_plan) t))
                        ((symbol-function 'ogent-armory-runner-start)
                         (lambda (plan)
                           (setq captured plan)
                           :started)))
                (ogent-armory-conversation-continue "Follow up."))
              (should (equal (plist-get captured :conversation-id)
                             "conv-continue"))
              (should (equal (plist-get captured :turn-content)
                             "Follow up."))
              (should (equal (plist-get captured :last-resume-result)
                             "replay"))
              (should (string-match-p "Prior turns"
                                      (plist-get captured :prompt)))
              (should (string-match-p "Initial answer"
                                      (plist-get captured :prompt))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversation-delete-removes-record ()
  "Conversation delete removes the canonical record directory."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let* ((file (ogent-armory-conversation-create
                  root
                  '(:id "conv-delete"
                        :agent "cto"
                        :title "Delete Review"
                        :status "done")))
           (directory (file-name-directory file))
           (buffer (ogent-armory-conversation root file)))
      (with-current-buffer buffer
        (ogent-armory-conversation-delete t))
      (should-not (file-exists-p directory))
      (should-not (buffer-live-p buffer)))))

(ert-deftest ogent-ui-armory-conversation-renders-success-trace ()
  "Successful conversation traces do not render as errors."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-ui-armory-test--write-session
                 root "cto" "successful-run" "DONE" 0)))
      (ogent-armory--write-file
       file
       (concat
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string))
        "\n** Runtime Trace\n#+begin_src text\nTool trace.\n#+end_src\n"))
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (should (string-match-p "Runtime Trace" text))
                (should-not (string-match-p "\nError\n" text))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversations-empty-state ()
  "A new Armory conversation browser shows a usable empty state."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-armory-conversations root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-conversations-mode))
            (should (string-match-p "No conversations yet"
                                    (buffer-substring-no-properties
                                     (point-min)
                                     (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-conversations-filter-completes-known-values ()
  "Conversation filters complete agents, statuses, and tags."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-conversations root)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Agent filter" prompt)
                           (should (member "cto" collection))
                           "cto")
                          ((string-match-p "Status filter" prompt)
                           (should (member "FAILED" collection))
                           "FAILED")
                          ((string-match-p "Tag filter" prompt)
                           (should (listp collection))
                           "")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-armory-conversations-filter))
            (should (equal (plist-get ogent-armory-conversations--filters
                                      :agent)
                           "cto"))
            (should (equal (plist-get ogent-armory-conversations--filters
                                      :status)
                           "FAILED")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-edit-property-updates-persona ()
  "Editing an agent identity property updates the Org persona drawer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_ROLE"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "Systems Architecture")))
              (ogent-armory-agent-edit-property))
            (should (equal (plist-get (ogent-armory-read-agent root "cto") :role)
                           "Systems Architecture")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-renders-attention-lanes ()
  "The Armory tasks buffer groups jobs and sessions into attention lanes."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-tasks-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (lane '("Inbox" "Needs Reply" "Running"
                              "Just Finished" "Archive"))
                (should (string-match-p lane text)))
              (let ((case-fold-search nil))
                (should-not (string-match-p "Scheduled" text))
                (should-not (string-match-p "Stale" text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-keybindings-cover-daily-actions ()
  "Task board bindings include run, archive, view cycle, edit, and filters."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-tasks-mode-map
   `(("RET" . ,#'ogent-armory-tasks-visit)
     ("c" . ,#'ogent-armory-create-task)
     ("R" . ,#'ogent-armory-tasks-run)
     ("A" . ,#'ogent-armory-tasks-archive)
     ("U" . ,#'ogent-armory-tasks-unarchive)
     ("v" . ,#'ogent-armory-tasks-cycle-view)
     ("e" . ,#'ogent-armory-tasks-edit)
     ("f" . ,#'ogent-armory-tasks-filter)
     ("g" . ,#'ogent-armory-tasks-refresh)
     ("?" . ,#'ogent-armory-tasks-dispatch)
     ("n" . ,#'ogent-armory-ui-next-item)
     ("p" . ,#'ogent-armory-ui-previous-item)
     ("j" . ,ogent-armory-jump-map)
     ("," . ,#'ogent-armory-settings)
     ("/" . ,#'ogent-armory-command-palette)
     ("q" . ,#'quit-window)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-tasks-mode-map
   '("C-c c" "C-c r" "C-c a" "C-c u" "C-c b" "C-c l" "C-c S"
     "C-c e" "C-c f" "C-c g")))

(ert-deftest ogent-ui-armory-tasks-run-displays-started-process ()
  "Running a task from the task board makes the spawned process visible."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root))
          called
          displayed)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-armory-run-job)
                       (lambda (run-root agent job-id)
                         (setq called (list run-root agent job-id))
                         'started-process))
                      ((symbol-function 'ogent-armory-runner-display-process)
                       (lambda (process)
                         (setq displayed process)
                         process)))
              (ogent-armory-tasks-run))
            (should (equal called (list (file-truename root)
                                        "cto"
                                        "weekly-review")))
            (should (eq displayed 'started-process)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-filter-completes-known-values ()
  "Task filters complete agents and observed task states."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Agent filter" prompt)
                           (should (member "cto" collection))
                           "cto")
                          ((string-match-p "Status filter" prompt)
                           (should (member "FAILED" collection))
                           "FAILED")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-armory-tasks-filter))
            (should (equal (plist-get ogent-armory-tasks--filters :agent)
                           "cto"))
            (should (equal (plist-get ogent-armory-tasks--filters :status)
                           "FAILED")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-buffer-advertises-capture ()
  "The task board makes task creation discoverable through its local menu."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq (lookup-key ogent-armory-tasks-mode-map (kbd "c"))
                        #'ogent-armory-create-task))
            (should (eq (lookup-key ogent-armory-tasks-mode-map (kbd "?"))
                        #'ogent-armory-tasks-dispatch))
            (should (get 'ogent-armory-tasks-dispatch 'transient--prefix))
            (let ((header (ogent-ui-armory-test--rendered-header-line)))
              (dolist (key '("?:menu" "j:jump" "g:refresh"))
                (should (string-match-p (regexp-quote key) header)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-create-task-captures-manual-inbox-task ()
  "Task capture creates a manual Org TODO job and refreshes the board."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "ops"
             :name "Ops"
             :role "Operations"
             :provider "codex"
             :active t)
     "Keep daily operations moving.")
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (ogent-armory-create-task
             root
             nil
             "Triage support inbox"
             "Review unresolved support threads.")
            (let* ((job (ogent-armory-read-job root "ops" "triage-support-inbox"))
                   (text (buffer-substring-no-properties (point-min) (point-max))))
              (should (equal (plist-get job :name) "Triage support inbox"))
              (should (plist-get job :enabled))
              (should-not (ogent-armory--blank-to-nil (plist-get job :cron)))
              (should (equal (plist-get job :body)
                             "Review unresolved support threads."))
              (should (string-match-p "Inbox" text))
              (should (string-match-p "Triage support inbox" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-create-task-uses-unique-job-ids ()
  "Task capture handles repeated task titles without user-visible slug prompts."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "ops"
             :name "Ops"
             :role "Operations"
             :provider "codex"
             :active t)
     "Keep daily operations moving.")
    (ogent-armory-create-task root "ops" "Review pull requests" "")
    (ogent-armory-create-task root "ops" "Review pull requests" "")
    (should (file-exists-p
             (ogent-armory-job-file root "ops" "review-pull-requests")))
    (should (file-exists-p
             (ogent-armory-job-file root "ops" "review-pull-requests-2")))))

(ert-deftest ogent-ui-armory-tasks-switches-list-and-schedule-views ()
  "Task board can switch between board, list, and schedule views."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq ogent-armory-tasks--view 'board))
            (ogent-armory-tasks-list-view)
            (should (eq ogent-armory-tasks--view 'list))
            (let ((list-text (buffer-substring-no-properties
                              (point-min)
                              (point-max))))
              (should (string-match-p "Weekly Review" list-text))
              (should-not (string-match-p "(empty)" list-text)))
            (ogent-armory-tasks-schedule-view)
            (should (eq ogent-armory-tasks--view 'schedule))
            (let ((schedule-text (buffer-substring-no-properties
                                  (point-min)
                                  (point-max))))
              (should (string-match-p "Weekly Review" schedule-text))
              (should-not (string-match-p "Old Report" schedule-text)))
            (ogent-armory-tasks-board-view)
            (should (eq ogent-armory-tasks--view 'board)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-sort-by-board-order-and-muted-state ()
  "Canonical task items honor board order and muted completed state."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (ogent-armory-conversation-create
     root
     '(:id "late"
           :agent "cto"
           :title "Late Card"
           :status "done"
           :completed "2026-05-06T11:00:00Z"
           :last-activity "2026-05-06T11:00:00Z"
           :board-order 20))
    (ogent-armory-conversation-create
     root
     '(:id "early"
           :agent "cto"
           :title "Early Card"
           :status "done"
           :completed "2026-05-06T10:00:00Z"
           :last-activity "2026-05-06T10:00:00Z"
           :board-order 1))
    (ogent-armory-conversation-create
     root
     '(:id "muted"
           :agent "cto"
           :title "Muted Card"
           :status "done"
           :completed "2026-05-06T09:00:00Z"
           :last-activity "2026-05-06T09:00:00Z"
           :muted t))
    (let ((sessions (ogent-armory-conversation-list-sessions root)))
      (should (equal (plist-get
                      (ogent-armory-tasks--session-item
                       (seq-find (lambda (session)
                                   (equal (plist-get session :id) "muted"))
                                 sessions))
                      :lane)
                     "Archive")))
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (let* ((text (buffer-substring-no-properties
                          (point-min)
                          (point-max)))
                   (early (string-match-p "Early Card" text))
                   (late (string-match-p "Late Card" text)))
              (should early)
              (should late)
              (should (< early late))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-search-finds-org-records ()
  "Armory search finds matching Org records and opens a result buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-search root "architecture")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-search-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "architecture" (downcase text)))
              (should (string-match-p "persona.org" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-search-empty-query-shows-empty-state ()
  "Empty Armory search queries produce a helpful empty state."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-search root "")))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Enter a search query" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-apps-list-opens-artifacts ()
  "The apps surface lists index.html artifacts with ownership hints."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html>")
      (setq buffer (ogent-armory-apps root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-apps-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "apps/dashboard" text))
              (should (string-match-p "index.html" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-open-app-browses-index-html ()
  "Opening a Armory app browses an index.html artifact."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          opened)
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html><title>Zorp</title>")
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (file &rest _)
                   (setq opened file))))
        (ogent-armory-open-app root)
        (should (equal opened (file-truename app-file)))))))

(ert-deftest ogent-ui-armory-status-links-richer-commands ()
  "Armory status exposes graph actions locally and richer views via jumps."
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-status-mode-map
   `(("j" . ,ogent-armory-jump-map)
     ("?" . ,#'ogent-armory-status-dispatch)
     ("R" . ,#'ogent-armory-status-run)
     ("e" . ,#'ogent-armory-status-edit)
     ("E" . ,#'ogent-armory-status-edit-body)
     ("P" . ,#'ogent-armory-status-open-agent-profile)
     ("J" . ,#'ogent-armory-status-open-agent-jobs)
     ("C" . ,#'ogent-armory-status-create-job)
     ("i" . ,#'ogent-armory-status-open-issues)))
  (ogent-ui-armory-test--assert-bindings
   ogent-armory-jump-map
   `(("a" . ,#'ogent-armory-agents)
     ("t" . ,#'ogent-armory-tasks)
     ("s" . ,#'ogent-armory-search)
     ("c" . ,#'ogent-armory-conversations)
     ("A" . ,#'ogent-armory-apps)
     ("g" . ,#'ogent-armory-status)))
  (ogent-ui-armory-test--assert-unbound
   ogent-armory-status-mode-map
   '("C-c a" "C-c t" "C-c s" "C-c c" "C-c A")))

(ert-deftest ogent-ui-armory-evil-installs-dispatch-keymaps ()
  "Armory UI dispatch keys remain active in Evil states."
  (let ((ogent-armory-home-mode-hook nil)
        (ogent-armory-agents-mode-hook nil)
        (ogent-armory-org-chart-mode-hook nil)
        (ogent-armory-agent-mode-hook nil)
        (ogent-armory-jobs-mode-hook nil)
        (ogent-armory-tasks-mode-hook nil)
        (ogent-armory-conversations-mode-hook nil)
        (ogent-armory-conversation-mode-hook nil)
        (ogent-armory-search-mode-hook nil)
        (ogent-armory-apps-mode-hook nil)
        states
        maps)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state)
                 (push (cons mode state) states)))
              ((symbol-function 'evil-make-overriding-map)
               (lambda (map state)
                 (push (cons map state) maps)))
              ((symbol-function 'evil-normalize-keymaps)
               (lambda (&rest _) nil)))
      (ogent-armory-ui--setup-evil))
    (dolist (mode '(ogent-armory-home-mode
                    ogent-armory-agents-mode
                    ogent-armory-org-chart-mode
                    ogent-armory-agent-mode
                    ogent-armory-jobs-mode
                    ogent-armory-tasks-mode
                    ogent-armory-conversations-mode
                    ogent-armory-conversation-mode
                    ogent-armory-search-mode
                    ogent-armory-apps-mode))
      (should (member (cons mode 'normal) states)))
    (dolist (map (list ogent-armory-home-mode-map
                       ogent-armory-agents-mode-map
                       ogent-armory-org-chart-mode-map
                       ogent-armory-agent-mode-map
                       ogent-armory-jobs-mode-map
                       ogent-armory-tasks-mode-map
                       ogent-armory-conversations-mode-map
                       ogent-armory-conversation-mode-map
                       ogent-armory-search-mode-map
                       ogent-armory-apps-mode-map))
      (should (member (cons map 'normal) maps))
      (should (member (cons map 'motion) maps)))
    (dolist (hook (list ogent-armory-home-mode-hook
                        ogent-armory-agents-mode-hook
                        ogent-armory-org-chart-mode-hook
                        ogent-armory-agent-mode-hook
                        ogent-armory-jobs-mode-hook
                        ogent-armory-tasks-mode-hook
                        ogent-armory-conversations-mode-hook
                        ogent-armory-conversation-mode-hook
                        ogent-armory-search-mode-hook
                        ogent-armory-apps-mode-hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(defun ogent-ui-armory-test--transient-suffixes (prefix)
  "Return the plists of all suffixes in PREFIX's transient layout."
  (let (suffixes)
    (cl-labels ((walk (node)
                  (cond
                   ((vectorp node)
                    (mapc #'walk (append node nil)))
                   ((and (consp node)
                         (symbolp (car node))
                         (plist-member (cdr node) :command))
                    (push (cdr node) suffixes))
                   ((listp node)
                    (mapc #'walk node)))))
      (walk (get prefix 'transient--layout)))
    (nreverse suffixes)))

(ert-deftest ogent-ui-armory-home-dispatch-includes-agenda-cockpit-rows ()
  "The Home dispatch wires the control-plane and saved QL view commands."
  (let ((commands (mapcar (lambda (suffix) (plist-get suffix :command))
                          (ogent-ui-armory-test--transient-suffixes
                           'ogent-armory-home-dispatch))))
    (should (memq 'ogent-armory-agenda-control-plane commands))
    (should (memq 'ogent-armory-ql-view commands))
    (should (memq 'ogent-armory-agenda commands))))

(ert-deftest ogent-ui-armory-home-dispatch-ql-row-visible-without-org-ql ()
  "The saved-views row stays visible with an install hint sans org-ql."
  (let ((suffix (cl-find 'ogent-armory-ql-view
                         (ogent-ui-armory-test--transient-suffixes
                          'ogent-armory-home-dispatch)
                         :key (lambda (plist) (plist-get plist :command)))))
    (should suffix)
    ;; The row must never be hidden behind :if; discoverability relies on
    ;; the description function dimming it instead.
    (should-not (plist-get suffix :if))
    (should (eq (plist-get suffix :description)
                'ogent-armory-home--ql-view-description))
    (cl-letf (((symbol-function 'ogent-armory-home--ql-view-available-p)
               (lambda () nil)))
      (let ((label (ogent-armory-home--ql-view-description)))
        (should (string-match-p "Saved views" label))
        (should (string-match-p "install org-ql" label))))
    (cl-letf (((symbol-function 'ogent-armory-home--ql-view-available-p)
               (lambda () t)))
      (should (equal (ogent-armory-home--ql-view-description)
                     "Saved views")))))

(provide 'ogent-ui-armory-tests)

;;; ogent-ui-armory-tests.el ends here

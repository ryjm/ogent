;;; ogent-armory-evil-tests.el --- Armory Evil keymap tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the canonical Evil display-buffer integration.
;;
;; Armory (and every other ogent display buffer) advertises single-key
;; affordances in its header line.  The correct Evil integration is the
;; magit/dired pattern: the mode keymap is marked as an Evil *overriding*
;; map so those keys fire under Evil, while keys the mode does not bind
;; keep their Evil motion meaning.  The historical behaviour -- stripping
;; every alphabetic/digit key out of Evil -- made the on-screen hints
;; lie to Evil users and is the bug these tests now guard against.

;;; Code:

(require 'cl-lib)
(require 'ogent-keys)
(require 'ogent-armory-evil)
(require 'ogent-armory-actions)
(require 'ogent-armory-adapter)
(require 'ogent-armory-compose)
(require 'ogent-armory-data)
(require 'ogent-armory-git)
(require 'ogent-armory-schedule)
(require 'ogent-armory-settings)
(require 'ogent-armory-skills)
(require 'ogent-ui-armory)

(declare-function evil-normalize-keymaps "ext:evil-core")

(defconst ogent-armory-evil-test--display-maps
  '(ogent-armory-actions-mode-map
    ogent-armory-apps-mode-map
    ogent-armory-agents-mode-map
    ogent-armory-agent-mode-map
    ogent-armory-conversation-mode-map
    ogent-armory-conversations-mode-map
    ogent-armory-data-mode-map
    ogent-armory-git-mode-map
    ogent-armory-help-mode-map
    ogent-armory-home-mode-map
    ogent-armory-jobs-mode-map
    ogent-armory-org-chart-mode-map
    ogent-armory-providers-mode-map
    ogent-armory-schedule-mode-map
    ogent-armory-search-mode-map
    ogent-armory-settings-mode-map
    ogent-armory-skills-mode-map
    ogent-armory-tasks-mode-map)
  "Armory display keymaps that must work in Evil states.")

(defconst ogent-armory-evil-test--setup-specs
  '((ogent-armory-actions--setup-evil
     ogent-armory-actions-mode ogent-armory-actions-mode-map
     ogent-armory-actions-mode-hook)
    (ogent-armory-data--setup-evil
     ogent-armory-data-mode ogent-armory-data-mode-map
     ogent-armory-data-mode-hook)
    (ogent-armory-git--setup-evil
     ogent-armory-git-mode ogent-armory-git-mode-map
     ogent-armory-git-mode-hook)
    (ogent-armory-help--setup-evil
     ogent-armory-help-mode ogent-armory-help-mode-map
     ogent-armory-help-mode-hook)
    (ogent-armory-providers--setup-evil
     ogent-armory-providers-mode ogent-armory-providers-mode-map
     ogent-armory-providers-mode-hook)
    (ogent-armory-schedule--setup-evil
     ogent-armory-schedule-mode ogent-armory-schedule-mode-map
     ogent-armory-schedule-mode-hook)
    (ogent-armory-settings--setup-evil
     ogent-armory-settings-mode ogent-armory-settings-mode-map
     ogent-armory-settings-mode-hook)
    (ogent-armory-skills--setup-evil
     ogent-armory-skills-mode ogent-armory-skills-mode-map
     ogent-armory-skills-mode-hook))
  "Armory modules that own display-mode Evil setup.")

(defmacro ogent-armory-evil-test--with-evil-spies (states overrides &rest body)
  "Run BODY with Evil setup functions stubbed.
STATES collects (MODE . STATE) from `evil-set-initial-state'.
OVERRIDES collects (KEYMAP . STATE) from `evil-make-overriding-map'."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'evil-set-initial-state)
              (lambda (mode state) (push (cons mode state) ,states)))
             ((symbol-function 'evil-make-overriding-map)
              (lambda (keymap &optional state _copy)
                (push (cons keymap state) ,overrides)))
             ((symbol-function 'evil-normalize-keymaps)
              (lambda (&rest _) nil))
             ((symbol-function 'evil-local-set-key)
              (lambda (&rest _) nil)))
     ,@body))

(ert-deftest ogent-armory-evil-keymap-bindings-ignore-parent-maps ()
  "Command collection uses direct Armory bindings only."
  (let ((parent (let ((map (make-sparse-keymap)))
                  (define-key map (kbd "p") #'ignore)
                  map))
        (child (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "c") #'ignore)
                 (define-key map (kbd "M-n") #'ignore)
                 map)))
    (set-keymap-parent child parent)
    (let ((bindings (ogent-armory-evil-keymap-command-bindings child)))
      (should (member (list (kbd "c") #'ignore) bindings))
      (should (member (list (kbd "M-n") #'ignore) bindings))
      (should-not (member (list (kbd "p") #'ignore) bindings)))))

(ert-deftest ogent-evil-display-mode-setup-marks-overriding-map ()
  "The canonical helper makes the mode map override Evil normal & motion.
This is what makes the buffer's single-key affordances actually fire
under Evil, instead of being shadowed by Evil motions."
  (let ((map (let ((m (make-sparse-keymap)))
               (define-key m "g" #'ignore)
               m))
        (hook (make-symbol "ogent-test-mode-hook"))
        states overrides)
    (cl-progv (list hook) (list nil)
      (ogent-armory-evil-test--with-evil-spies states overrides
        (ogent-evil-display-mode-setup 'ogent-test-mode map hook #'ignore))
      (should (equal (cdr (assq 'ogent-test-mode states)) 'normal))
      (should (member (cons map 'normal) overrides))
      (should (member (cons map 'motion) overrides))
      (should (memq #'evil-normalize-keymaps (symbol-value hook))))))

(ert-deftest ogent-evil-display-mode-setup-no-op-without-evil ()
  "Helper is a safe no-op when Evil is unavailable."
  (let ((map (make-sparse-keymap))
        (hook (make-symbol "ogent-test-mode-hook")))
    (cl-progv (list hook) (list nil)
      (cl-letf (((symbol-function 'evil-make-overriding-map) nil)
                ((symbol-function 'evil-set-initial-state) nil))
        ;; fboundp guards mean this must not error.
        (should-not (ogent-evil-display-mode-setup
                     'ogent-test-mode map hook))
        (should (null (symbol-value hook)))))))

(ert-deftest ogent-armory-evil-setup-mode-uses-canonical-override ()
  "`ogent-armory-evil-setup-mode' delegates to the overriding-map path.
The legacy LOCAL-KEYS mirroring function must NOT be added to the
hook -- single keys now work via the overriding map, not by stripping."
  (let ((map (let ((m (make-sparse-keymap)))
               (define-key m "g" #'ignore)
               (define-key m "n" #'ignore)
               m))
        (hook (make-symbol "ogent-armory-test-mode-hook"))
        (local-keys (lambda () (error "legacy mirror must not run")))
        states overrides)
    (cl-progv (list hook) (list nil)
      (ogent-armory-evil-test--with-evil-spies states overrides
        (ogent-armory-evil-setup-mode
         'ogent-armory-test-mode map hook local-keys))
      (should (equal (cdr (assq 'ogent-armory-test-mode states)) 'normal))
      (should (member (cons map 'normal) overrides))
      (should (member (cons map 'motion) overrides))
      (should-not (memq local-keys (symbol-value hook)))
      (should (memq #'evil-normalize-keymaps (symbol-value hook))))))

(ert-deftest ogent-armory-evil-setup-functions-wire-display-modes ()
  "Every Armory display module wires the canonical Evil integration:
initial state normal, mode map overriding normal AND motion, and
`evil-normalize-keymaps' on the mode hook."
  (dolist (spec ogent-armory-evil-test--setup-specs)
    (pcase-let ((`(,setup ,mode ,map-symbol ,hook) spec))
      (let (states overrides)
        (cl-progv (list hook) (list nil)
          (ogent-armory-evil-test--with-evil-spies states overrides
            (funcall setup))
          (should (equal (cdr (assq mode states)) 'normal))
          (should (member (cons (symbol-value map-symbol) 'normal)
                          overrides))
          (should (member (cons (symbol-value map-symbol) 'motion)
                          overrides))
          (should (memq #'evil-normalize-keymaps
                        (symbol-value hook))))))))

(ert-deftest ogent-armory-evil-display-maps-bind-quit ()
  "Sanity: every Armory display map still binds q to quit so the
advertised `q' affordance resolves once the map overrides Evil."
  (dolist (map-symbol ogent-armory-evil-test--display-maps)
    (let ((cmd (lookup-key (symbol-value map-symbol) "q")))
      (should (commandp cmd)))))

(provide 'ogent-armory-evil-tests)

;;; ogent-armory-evil-tests.el ends here

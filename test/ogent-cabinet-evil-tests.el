;;; ogent-cabinet-evil-tests.el --- Cabinet Evil keymap tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the shared Cabinet Evil integration helpers.

;;; Code:

(require 'cl-lib)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-actions)
(require 'ogent-cabinet-adapter)
(require 'ogent-cabinet-compose)
(require 'ogent-cabinet-data)
(require 'ogent-cabinet-git)
(require 'ogent-cabinet-schedule)
(require 'ogent-cabinet-settings)
(require 'ogent-cabinet-skills)
(require 'ogent-ui-cabinet)

(declare-function evil-normalize-keymaps "ext:evil-core")

(defconst ogent-cabinet-evil-test--display-maps
  '(ogent-cabinet-actions-mode-map
    ogent-cabinet-apps-mode-map
    ogent-cabinet-agents-mode-map
    ogent-cabinet-agent-mode-map
    ogent-cabinet-compose-mode-map
    ogent-cabinet-conversation-mode-map
    ogent-cabinet-conversations-mode-map
    ogent-cabinet-data-mode-map
    ogent-cabinet-git-mode-map
    ogent-cabinet-help-mode-map
    ogent-cabinet-home-mode-map
    ogent-cabinet-jobs-mode-map
    ogent-cabinet-org-chart-mode-map
    ogent-cabinet-providers-mode-map
    ogent-cabinet-schedule-mode-map
    ogent-cabinet-search-mode-map
    ogent-cabinet-settings-mode-map
    ogent-cabinet-skills-mode-map
    ogent-cabinet-tasks-mode-map)
  "Cabinet display keymaps that should work in Evil states.")

(defconst ogent-cabinet-evil-test--setup-specs
  '((ogent-cabinet-actions--setup-evil
     ogent-cabinet-actions-mode
     ogent-cabinet-actions-mode-map
     ogent-cabinet-actions-mode-hook
     ogent-cabinet-actions--evil-local-keys)
    (ogent-cabinet-compose--setup-evil
     ogent-cabinet-compose-mode
     ogent-cabinet-compose-mode-map
     ogent-cabinet-compose-mode-hook
     ogent-cabinet-compose--evil-local-keys)
    (ogent-cabinet-data--setup-evil
     ogent-cabinet-data-mode
     ogent-cabinet-data-mode-map
     ogent-cabinet-data-mode-hook
     ogent-cabinet-data--evil-local-keys)
    (ogent-cabinet-git--setup-evil
     ogent-cabinet-git-mode
     ogent-cabinet-git-mode-map
     ogent-cabinet-git-mode-hook
     ogent-cabinet-git--evil-local-keys)
    (ogent-cabinet-help--setup-evil
     ogent-cabinet-help-mode
     ogent-cabinet-help-mode-map
     ogent-cabinet-help-mode-hook
     ogent-cabinet-help--evil-local-keys)
    (ogent-cabinet-providers--setup-evil
     ogent-cabinet-providers-mode
     ogent-cabinet-providers-mode-map
     ogent-cabinet-providers-mode-hook
     ogent-cabinet-providers--evil-local-keys)
    (ogent-cabinet-schedule--setup-evil
     ogent-cabinet-schedule-mode
     ogent-cabinet-schedule-mode-map
     ogent-cabinet-schedule-mode-hook
     ogent-cabinet-schedule--evil-local-keys)
    (ogent-cabinet-settings--setup-evil
     ogent-cabinet-settings-mode
     ogent-cabinet-settings-mode-map
     ogent-cabinet-settings-mode-hook
     ogent-cabinet-settings--evil-local-keys)
    (ogent-cabinet-skills--setup-evil
     ogent-cabinet-skills-mode
     ogent-cabinet-skills-mode-map
     ogent-cabinet-skills-mode-hook
     ogent-cabinet-skills--evil-local-keys))
  "Cabinet modules that own display-mode Evil setup.")

(defun ogent-cabinet-evil-test--capture-bindings (map)
  "Return `evil-local-set-key' calls made while installing MAP."
  (let (calls)
    (cl-letf (((symbol-function 'evil-local-set-key)
               (lambda (state key command)
                 (push (list state key command) calls))))
      (ogent-cabinet-evil-install-local-bindings map))
    calls))

(ert-deftest ogent-cabinet-evil-keymap-bindings-ignore-parent-maps ()
  "Command collection uses direct Cabinet bindings only."
  (let ((parent (let ((map (make-sparse-keymap)))
                  (define-key map (kbd "p") #'ignore)
                  map))
        (child (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "c") #'ignore)
                 (define-key map (kbd "M-n") #'ignore)
                 map)))
    (set-keymap-parent child parent)
    (let ((bindings (ogent-cabinet-evil-keymap-command-bindings child)))
      (should (member (list (kbd "c") #'ignore) bindings))
      (should (member (list (kbd "M-n") #'ignore) bindings))
      (should-not (member (list (kbd "p") #'ignore) bindings)))))

(ert-deftest ogent-cabinet-evil-local-bindings-cover-cabinet-keymaps ()
  "Every Evil-safe Cabinet key is mirrored into Evil states."
  (dolist (map-symbol ogent-cabinet-evil-test--display-maps)
    (let* ((map (symbol-value map-symbol))
           (expected (ogent-cabinet-evil-state-command-bindings map))
           (calls (ogent-cabinet-evil-test--capture-bindings map)))
      (dolist (binding expected)
        (dolist (state '(normal motion))
          (should (member (list state (car binding) (cadr binding))
                          calls)))))))

(ert-deftest ogent-cabinet-evil-local-bindings-preserve-vim-normal-keys ()
  "Bare Vim normal-state keys are not mirrored into Evil states."
  (let ((home-calls
         (ogent-cabinet-evil-test--capture-bindings ogent-cabinet-home-mode-map))
        (conversation-calls
         (ogent-cabinet-evil-test--capture-bindings
          ogent-cabinet-conversation-mode-map)))
    (dolist (state '(normal motion))
      (should-not (member (list state (kbd "j") #'ogent-cabinet-jobs)
                          home-calls))
      (should (member (list state (kbd "C-c j") #'ogent-cabinet-jobs)
                      home-calls))
      (should-not (member (list state (kbd "k")
                            #'ogent-cabinet-conversation-stop)
                          conversation-calls))
      (should (member (list state (kbd "C-c k")
                            #'ogent-cabinet-conversation-stop)
                      conversation-calls)))))

(ert-deftest ogent-cabinet-evil-local-bindings-never-mirror-reserved-keys ()
  "Cabinet Evil setup leaves bare normal-state keys available to Evil."
  (dolist (map-symbol ogent-cabinet-evil-test--display-maps)
    (let ((calls (ogent-cabinet-evil-test--capture-bindings
                  (symbol-value map-symbol))))
      (dolist (call calls)
        (pcase-let ((`(,_state ,key ,_command) call))
          (should-not (ogent-cabinet-evil-reserved-key-p key)))))))

(ert-deftest ogent-cabinet-evil-local-bindings-use-captured-map-shape ()
  "Local bindings use the captured command shape after setup."
  (let ((map (let ((keymap (make-sparse-keymap)))
               (define-key keymap (kbd "m") #'ignore)
               (define-key keymap (kbd "g") #'ignore)
               (define-key keymap (kbd "C-c m") #'ignore)
               keymap))
        (hook (make-symbol "ogent-cabinet-test-mode-hook"))
        calls)
    (cl-progv (list hook) (list nil)
      (cl-letf (((symbol-function 'evil-set-initial-state)
                 (lambda (&rest _) nil))
                ((symbol-function 'evil-normalize-keymaps)
                 (lambda (&rest _) nil))
                ((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) calls))))
        (ogent-cabinet-evil-setup-mode
         'ogent-cabinet-test-mode
         map
         hook
         #'ignore)
        (setcdr map (list (cons ?g #'ignore)))
        (ogent-cabinet-evil-install-local-bindings map)))
    (dolist (state '(normal motion))
      (should (member (list state (kbd "C-c m") #'ignore) calls))
      (should-not (member (list state (kbd "m") #'ignore) calls))
      (should-not (member (list state (kbd "g") #'ignore) calls)))))

(ert-deftest ogent-cabinet-evil-setup-functions-wire-display-modes ()
  "Cabinet display modules install Evil initial states and hooks."
  (dolist (spec ogent-cabinet-evil-test--setup-specs)
    (pcase-let ((`(,setup ,mode ,map-symbol ,hook ,local-keys) spec)
                (states nil)
                (maps nil))
      (cl-progv (list hook) (list nil)
        (cl-letf (((symbol-function 'evil-set-initial-state)
                   (lambda (mode-symbol state)
                     (push (cons mode-symbol state) states)))
                  ((symbol-function 'evil-make-overriding-map)
                   (lambda (map state)
                     (push (cons map state) maps)))
                  ((symbol-function 'evil-normalize-keymaps)
                   (lambda (&rest _) nil)))
          (funcall setup))
        (should (member (cons mode 'normal) states))
        (should-not (member (cons (symbol-value map-symbol) 'all) maps))
        (should (memq local-keys (symbol-value hook)))
        (should (memq #'evil-normalize-keymaps (symbol-value hook)))))))

(provide 'ogent-cabinet-evil-tests)

;;; ogent-cabinet-evil-tests.el ends here

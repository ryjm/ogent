;;; ogent-armory-evil-tests.el --- Armory Evil keymap tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the shared Armory Evil integration helpers.

;;; Code:

(require 'cl-lib)
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
    ogent-armory-compose-mode-map
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
  "Armory display keymaps that should work in Evil states.")

(defconst ogent-armory-evil-test--setup-specs
  '((ogent-armory-actions--setup-evil
     ogent-armory-actions-mode
     ogent-armory-actions-mode-map
     ogent-armory-actions-mode-hook
     ogent-armory-actions--evil-local-keys)
    (ogent-armory-compose--setup-evil
     ogent-armory-compose-mode
     ogent-armory-compose-mode-map
     ogent-armory-compose-mode-hook
     ogent-armory-compose--evil-local-keys)
    (ogent-armory-data--setup-evil
     ogent-armory-data-mode
     ogent-armory-data-mode-map
     ogent-armory-data-mode-hook
     ogent-armory-data--evil-local-keys)
    (ogent-armory-git--setup-evil
     ogent-armory-git-mode
     ogent-armory-git-mode-map
     ogent-armory-git-mode-hook
     ogent-armory-git--evil-local-keys)
    (ogent-armory-help--setup-evil
     ogent-armory-help-mode
     ogent-armory-help-mode-map
     ogent-armory-help-mode-hook
     ogent-armory-help--evil-local-keys)
    (ogent-armory-providers--setup-evil
     ogent-armory-providers-mode
     ogent-armory-providers-mode-map
     ogent-armory-providers-mode-hook
     ogent-armory-providers--evil-local-keys)
    (ogent-armory-schedule--setup-evil
     ogent-armory-schedule-mode
     ogent-armory-schedule-mode-map
     ogent-armory-schedule-mode-hook
     ogent-armory-schedule--evil-local-keys)
    (ogent-armory-settings--setup-evil
     ogent-armory-settings-mode
     ogent-armory-settings-mode-map
     ogent-armory-settings-mode-hook
     ogent-armory-settings--evil-local-keys)
    (ogent-armory-skills--setup-evil
     ogent-armory-skills-mode
     ogent-armory-skills-mode-map
     ogent-armory-skills-mode-hook
     ogent-armory-skills--evil-local-keys))
  "Armory modules that own display-mode Evil setup.")

(defun ogent-armory-evil-test--capture-bindings (map)
  "Return `evil-local-set-key' calls made while installing MAP."
  (let (calls)
    (cl-letf (((symbol-function 'evil-local-set-key)
               (lambda (state key command)
                 (push (list state key command) calls))))
      (ogent-armory-evil-install-local-bindings map))
    calls))

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

(ert-deftest ogent-armory-evil-local-bindings-cover-armory-keymaps ()
  "Every Evil-safe Armory key is mirrored into Evil states."
  (dolist (map-symbol ogent-armory-evil-test--display-maps)
    (let* ((map (symbol-value map-symbol))
           (expected (ogent-armory-evil-state-command-bindings map))
           (calls (ogent-armory-evil-test--capture-bindings map)))
      (dolist (binding expected)
        (dolist (state '(normal motion))
          (should (member (list state (car binding) (cadr binding))
                          calls)))))))

(ert-deftest ogent-armory-evil-local-bindings-preserve-vim-normal-keys ()
  "Bare Vim normal-state keys are not mirrored into Evil states."
  (let ((home-calls
         (ogent-armory-evil-test--capture-bindings ogent-armory-home-mode-map))
        (conversation-calls
         (ogent-armory-evil-test--capture-bindings
          ogent-armory-conversation-mode-map)))
    (dolist (state '(normal motion))
      (should-not (member (list state (kbd "j") #'ogent-armory-jobs)
                          home-calls))
      (should (member (list state (kbd "C-c j") #'ogent-armory-jobs)
                      home-calls))
      (should-not (member (list state (kbd "k")
                            #'ogent-armory-conversation-stop)
                          conversation-calls))
      (should (member (list state (kbd "C-c k")
                            #'ogent-armory-conversation-stop)
                      conversation-calls)))))

(ert-deftest ogent-armory-evil-local-bindings-never-mirror-reserved-keys ()
  "Armory Evil setup leaves bare normal-state keys available to Evil."
  (dolist (map-symbol ogent-armory-evil-test--display-maps)
    (let ((calls (ogent-armory-evil-test--capture-bindings
                  (symbol-value map-symbol))))
      (dolist (call calls)
        (pcase-let ((`(,_state ,key ,_command) call))
          (should-not (ogent-armory-evil-reserved-key-p key)))))))

(ert-deftest ogent-armory-evil-local-bindings-use-captured-map-shape ()
  "Local bindings use the captured command shape after setup."
  (let ((map (let ((keymap (make-sparse-keymap)))
               (define-key keymap (kbd "m") #'ignore)
               (define-key keymap (kbd "g") #'ignore)
               (define-key keymap (kbd "C-c m") #'ignore)
               keymap))
        (hook (make-symbol "ogent-armory-test-mode-hook"))
        calls)
    (cl-progv (list hook) (list nil)
      (cl-letf (((symbol-function 'evil-set-initial-state)
                 (lambda (&rest _) nil))
                ((symbol-function 'evil-normalize-keymaps)
                 (lambda (&rest _) nil))
                ((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) calls))))
        (ogent-armory-evil-setup-mode
         'ogent-armory-test-mode
         map
         hook
         #'ignore)
        (setcdr map (list (cons ?g #'ignore)))
        (ogent-armory-evil-install-local-bindings map)))
    (dolist (state '(normal motion))
      (should (member (list state (kbd "C-c m") #'ignore) calls))
      (should-not (member (list state (kbd "m") #'ignore) calls))
      (should-not (member (list state (kbd "g") #'ignore) calls)))))

(ert-deftest ogent-armory-evil-setup-functions-wire-display-modes ()
  "Armory display modules install Evil initial states and hooks."
  (dolist (spec ogent-armory-evil-test--setup-specs)
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

(provide 'ogent-armory-evil-tests)

;;; ogent-armory-evil-tests.el ends here

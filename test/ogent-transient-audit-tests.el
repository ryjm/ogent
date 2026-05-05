;;; ogent-transient-audit-tests.el --- Command surface audits -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression coverage for Transient menus that form ogent's interactive
;; harness. These tests catch duplicate visible keys, missing suffix commands,
;; and setup-time formatter errors.

;;; Code:

(require 'ogent-test-helper)
(require 'transient)
(require 'ogent)
(require 'ogent-armory-status)
(require 'ogent-gastown-status)
(require 'ogent-gastown-status-transient)
(require 'ogent-gastown-tmux)
(require 'ogent-issues)
(require 'ogent-issues-transient)
(require 'ogent-tool-approval)

(defconst ogent-transient-audit-prefixes
  '(ogent-debug-tools-menu
    ogent-edit-menu
    ogent-armory-home-dispatch
    ogent-armory-status-dispatch
    ogent-gastown-dispatch
    ogent-gastown-status-dispatch
    ogent-gastown-tmux-dispatch
    ogent-issues-create-dispatch
    ogent-issues-dispatch
    ogent-issues-filter-dispatch
    ogent-prompt-dispatch
    ogent-tool-approval-menu)
  "Transient prefixes that make up ogent's command harness.")

(defun ogent-transient-audit--with-stable-environment (fn)
  "Call FN with external command lookups stubbed for deterministic audits."
  (cl-letf (((symbol-function 'ogent-gastown--in-town-p)
             (lambda (&rest _) nil))
            ((symbol-function 'ogent-gastown--workspace-root-display)
             (lambda (&rest _) nil))
            ((symbol-function 'ogent-gastown-tmux--get-sessions)
             (lambda (&rest _) nil))
            ((symbol-function 'ogent-gastown-integration-active-p)
             (lambda (&rest _) nil)))
    (funcall fn)))

(defun ogent-transient-audit--visible-suffix-p (suffix)
  "Return non-nil when SUFFIX belongs to an ogent-visible command key."
  (let ((command (oref suffix command))
        (key (oref suffix key)))
    (not (or (and (symbolp command)
                  (string-prefix-p "transient-" (symbol-name command)))
             (string-prefix-p "C-" key)))))

(defun ogent-transient-audit--action-suffix-p (suffix)
  "Return non-nil when SUFFIX should resolve to an interactive command."
  (not (object-of-class-p suffix 'transient-infix)))

(ert-deftest ogent-transient-audit-prefixes-setup ()
  "Every Transient prefix should render without setup-time errors."
  (ogent-transient-audit--with-stable-environment
   (lambda ()
     (dolist (prefix ogent-transient-audit-prefixes)
       (unwind-protect
           (progn
             (transient-setup prefix)
             (should (get prefix 'transient--prefix)))
         (when transient-current-prefix
           (transient-quit-one)))))))

(ert-deftest ogent-transient-audit-visible-keys-are-unique ()
  "Every visible Transient key should map to a single command per prefix."
  (ogent-transient-audit--with-stable-environment
   (lambda ()
     (dolist (prefix ogent-transient-audit-prefixes)
       (let ((seen (make-hash-table :test #'equal))
             duplicates)
         (dolist (suffix (transient-suffixes prefix))
           (when (ogent-transient-audit--visible-suffix-p suffix)
             (let* ((key (oref suffix key))
                    (command (oref suffix command))
                    (existing (gethash key seen)))
               (if existing
                   (push (list key existing command) duplicates)
                 (puthash key command seen)))))
         (should-not duplicates))))))

(ert-deftest ogent-transient-audit-suffix-commands-are-commands ()
  "Every visible Transient suffix should resolve to an interactive command."
  (ogent-transient-audit--with-stable-environment
   (lambda ()
     (dolist (prefix ogent-transient-audit-prefixes)
       (dolist (suffix (transient-suffixes prefix))
         (when (and (ogent-transient-audit--visible-suffix-p suffix)
                    (ogent-transient-audit--action-suffix-p suffix))
           (should (commandp (oref suffix command)))))))))

(provide 'ogent-transient-audit-tests)

;;; ogent-transient-audit-tests.el ends here

;;; ogent-ui-models-tests.el --- Tests for the model picker UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for ogent-ui-models covering:
;; - Provider display names and role back-references
;; - Annotated, grouped designator completion
;; - Session and buffer-local model switching
;; - Org subtree and file-level model pinning
;; - Role assignment commands
;; - The Org-table registry browser

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-ui-models)
(require 'ogent-presets)
(require 'cl-lib)
(require 'org)

;; gptel session state let-bound around the switch commands; gptel
;; itself may not be loaded when this suite compiles or runs.
(defvar gptel-model)
(defvar gptel-backend)

(defmacro ogent-ui-models-tests--with-registry (&rest body)
  "Run BODY with a small deterministic registry and role alist.
Animations are disabled so command flashes stay side-effect free."
  (declare (indent 0) (debug t))
  `(let ((ogent-default-model "alpha")
         (ogent-model-registry
          '((:id "alpha" :backend gptel-openai :stream? t
                 :description "Alpha flagship")
            (:id "beta" :backend gptel-anthropic :stream? nil
                 :description "Beta deep model")))
         (ogent-model-roles '((deep . "beta")
                              (fast . deep)))
         (ogent-theme-animation-speed 'none))
     ,@body))

;;; Formatting

(ert-deftest ogent-ui-models-provider-name-maps-known-backends ()
  "Known gptel backends map to friendly provider names."
  (should (equal (ogent-ui-models--provider-name '(:backend gptel-openai))
                 "OpenAI"))
  (should (equal (ogent-ui-models--provider-name '(:backend gptel-anthropic))
                 "Anthropic"))
  (should (equal (ogent-ui-models--provider-name '(:backend gptel-kagi))
                 "Kagi")))

(ert-deftest ogent-ui-models-roles-resolving-to-finds-roles ()
  "Role back-references list every role landing on a model."
  (ogent-ui-models-tests--with-registry
    (let ((roles (ogent-ui-models--roles-resolving-to "beta")))
      (should (memq 'deep roles))
      ;; fast aliases deep, so it also lands on beta.
      (should (memq 'fast roles)))
    (should (memq 'default (ogent-ui-models--roles-resolving-to "alpha")))))

(ert-deftest ogent-ui-models-annotation-marks-default ()
  "Completion annotations carry the description and default marker."
  (ogent-ui-models-tests--with-registry
    (let ((annotation (ogent-ui-models--annotate "alpha" 10)))
      (should (string-match-p "Alpha flagship" annotation))
      (should (string-match-p "←default" annotation)))
    (should (string-match-p "role → beta"
                            (ogent-ui-models--annotate "@deep" 10)))))

(ert-deftest ogent-ui-models-group-splits-providers-and-roles ()
  "Completion groups models by provider and roles separately."
  (ogent-ui-models-tests--with-registry
    (should (equal (ogent-ui-models--group "alpha" nil) "OpenAI"))
    (should (equal (ogent-ui-models--group "beta" nil) "Anthropic"))
    (should (equal (ogent-ui-models--group "@deep" nil) "Roles"))
    (should (equal (ogent-ui-models--group "beta" t) "beta"))))

(ert-deftest ogent-ui-models-read-offers-roles-when-asked ()
  "The designator reader offers @role candidates only on request."
  (ogent-ui-models-tests--with-registry
    (let (captured)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq captured (all-completions "" table))
                   "alpha")))
        (ogent-ui-models-read "Model: " t)
        (should (member "@deep" captured))
        (should (member "alpha" captured))
        (ogent-ui-models-read "Model: ")
        (should-not (member "@deep" captured))))))

;;; Switching

(ert-deftest ogent-ui-models-switch-sets-global-model ()
  "Switching the session model updates the global gptel model."
  (ogent-ui-models-tests--with-registry
    (cl-letf (((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) nil)))
      (let ((gptel-model 'unset)
            (gptel-backend nil))
        (ogent-model-switch "beta")
        (should (eq gptel-model 'beta))))))

(ert-deftest ogent-ui-models-switch-buffer-stays-local ()
  "Buffer-local switching leaves the global gptel model alone."
  (ogent-ui-models-tests--with-registry
    (cl-letf (((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) nil)))
      (let ((gptel-model 'unset)
            (gptel-backend nil))
        (with-temp-buffer
          (ogent-model-switch-buffer "beta")
          (should (eq gptel-model 'beta))
          (should (eq (default-value 'gptel-model) 'unset)))))))

(ert-deftest ogent-ui-models-set-default-updates-var ()
  "Setting the default updates `ogent-default-model'."
  (ogent-ui-models-tests--with-registry
    (cl-letf (((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) nil)))
      (let ((gptel-model 'unset)
            (gptel-backend nil))
        (ogent-model-set-default "beta")
        (should (equal ogent-default-model "beta"))
        (should (eq gptel-model 'beta))))))

(ert-deftest ogent-ui-models-set-default-canonicalizes-alias ()
  "Setting the default via an alias stores the canonical id."
  (let ((ogent-default-model "alpha")
        (ogent-model-registry
         '((:id "alpha" :backend gptel-openai)
           (:id "beta-canonical" :backend gptel-anthropic
                :aliases ("beta"))))
        (ogent-model-roles nil)
        (ogent-theme-animation-speed 'none))
    (cl-letf (((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) nil)))
      (let ((gptel-model 'unset)
            (gptel-backend nil))
        (ogent-model-set-default "beta")
        (should (equal ogent-default-model "beta-canonical"))
        (should (eq gptel-model 'beta-canonical))))))

;;; Org pinning

(ert-deftest ogent-ui-models-pin-heading-sets-property ()
  "Pinning on a heading sets the OGENT_MODEL property."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "* Heading\nBody\n")
      (goto-char (point-max))
      (ogent-model-pin-heading "beta")
      (should (equal (org-entry-get (point) "OGENT_MODEL" t) "beta"))
      (should (equal (ogent-models-effective) '("beta" . org-property))))))

(ert-deftest ogent-ui-models-pin-heading-before-first-heading-pins-file ()
  "Pinning before the first heading falls back to a file keyword."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "Preamble\n* Heading\n")
      (goto-char (point-min))
      (ogent-model-pin-heading "@deep")
      (should (string-match-p "#\\+PROPERTY: OGENT_MODEL @deep"
                              (buffer-string)))
      (goto-char (point-max))
      (should (equal (car (ogent-models-effective)) "beta")))))

(ert-deftest ogent-ui-models-pin-file-replaces-existing-keyword ()
  "File pinning updates an existing OGENT_MODEL keyword in place."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "#+PROPERTY: OGENT_MODEL alpha\n* Heading\n")
      (ogent-model-pin-file "beta")
      (should (= 1 (with-current-buffer (current-buffer)
                     (count-matches "OGENT_MODEL" (point-min) (point-max)))))
      (goto-char (point-max))
      (should (equal (car (ogent-models-effective)) "beta")))))

(ert-deftest ogent-ui-models-unpin-removes-heading-property ()
  "Unpinning removes the subtree property."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "* Heading\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n")
      (goto-char (point-max))
      (ogent-model-unpin)
      (should-not (org-entry-get (point) "OGENT_MODEL" t)))))

(ert-deftest ogent-ui-models-unpin-inherited-asks-and-removes-at-ancestor ()
  "Unpinning under an inherited pin removes it at the ancestor on consent.
A file-wide keyword must survive: the ancestor pin is the effective
source, so only it may be removed."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "#+PROPERTY: OGENT_MODEL alpha\n"
              "* Parent\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n"
              "** Child\nBody\n")
      (org-set-regexps-and-options)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
        (ogent-model-unpin))
      ;; Ancestor pin gone, file keyword still present.
      (should-not (org-entry-get (point) "OGENT_MODEL" nil))
      (should (string-match-p "#\\+PROPERTY: OGENT_MODEL alpha"
                              (buffer-string)))
      ;; The file-wide pin now takes effect for the child.
      (should (equal (car (ogent-models-effective)) "alpha")))))

(ert-deftest ogent-ui-models-unpin-inherited-keeps-pin-on-refusal ()
  "Refusing the inherited-unpin prompt leaves the ancestor pin alone."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n"
              "** Child\nBody\n")
      (goto-char (point-max))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
        (ogent-model-unpin))
      (should (equal (org-entry-get (point) "OGENT_MODEL" t) "beta")))))

(ert-deftest ogent-ui-models-unpin-file-keyword-from-heading-asks ()
  "With only a file-wide pin, unpinning at a heading asks first."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "#+PROPERTY: OGENT_MODEL beta\n* Heading\nBody\n")
      (org-set-regexps-and-options)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
        (ogent-model-unpin))
      (should-not (string-match-p "OGENT_MODEL" (buffer-string)))
      (should (equal (car (ogent-models-effective)) "alpha")))))

(ert-deftest ogent-ui-models-unpin-inherited-works-under-narrowing ()
  "Unpinning an ancestor pin works while narrowed to the child subtree."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n"
              "** Child\nBody\n")
      (goto-char (point-max))
      (org-back-to-heading t)
      (org-narrow-to-subtree)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
        (ogent-model-unpin))
      (widen)
      (goto-char (point-max))
      (should-not (org-entry-get (point) "OGENT_MODEL" t)))))

(ert-deftest ogent-ui-models-pin-requires-org-buffer ()
  "Pinning outside Org signals a user error."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (should-error (ogent-model-pin-heading "beta") :type 'user-error)
      (should-error (ogent-model-unpin) :type 'user-error))))

;;; Roles

(ert-deftest ogent-ui-models-assign-role-stores-alias-as-symbol ()
  "Assigning an @role designator stores a symbol alias."
  (ogent-ui-models-tests--with-registry
    (ogent-model-assign-role 'edit "@deep")
    (should (eq (ogent-models-role-designator 'edit) 'deep))
    (should (equal (ogent-models-resolve-role 'edit) "beta"))))

(ert-deftest ogent-ui-models-assign-default-role-sets-default-model ()
  "Assigning the default role updates `ogent-default-model'."
  (ogent-ui-models-tests--with-registry
    (ogent-model-assign-role 'default "beta")
    (should (equal ogent-default-model "beta"))
    (should-not (assq 'default ogent-model-roles))))

(ert-deftest ogent-ui-models-assign-role-rejects-self-alias ()
  "A role cannot alias itself."
  (ogent-ui-models-tests--with-registry
    (should-error (ogent-model-assign-role 'deep "@deep")
                  :type 'user-error)))

(ert-deftest ogent-ui-models-clear-role-restores-default ()
  "Clearing a role removes its assignment."
  (ogent-ui-models-tests--with-registry
    (ogent-model-clear-role 'deep)
    (should-not (ogent-models-role-designator 'deep))
    (should (equal (ogent-models-resolve-role 'deep) "alpha"))))

;;; Status header

(ert-deftest ogent-ui-models-status-shows-effective-and-roles ()
  "The picker header names the effective model, source, and roles."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (let ((gptel-model nil)
            (transient--original-buffer (current-buffer)))
        (let ((status (ogent-ui-models--status-description)))
          (should (string-match-p "alpha" status))
          (should (string-match-p "via default" status))
          (should (string-match-p "deep" status)))))))

;;; Registry browser

(ert-deftest ogent-ui-models-browse-renders-models-and-roles ()
  "The browser buffer lists every model and role assignment."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (let ((gptel-model nil))
        (save-window-excursion
          (ogent-models-browse)
          (with-current-buffer ogent-ui-models--browser-buffer-name
            (should (derived-mode-p 'ogent-models-browser-mode))
            (should buffer-read-only)
            (let ((text (buffer-string)))
              (should (string-match-p "| alpha" text))
              (should (string-match-p "beta" text))
              (should (string-match-p "Alpha flagship" text))
              (should (string-match-p "@deep" text))
              (should (string-match-p "Effective model: =alpha=" text)))))))
    (when (get-buffer ogent-ui-models--browser-buffer-name)
      (kill-buffer ogent-ui-models--browser-buffer-name))))

(ert-deftest ogent-ui-models-browser-finds-model-on-row ()
  "RET-style selection reads the model id from the table row."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (let ((gptel-model nil))
        (save-window-excursion
          (ogent-models-browse)
          (with-current-buffer ogent-ui-models--browser-buffer-name
            (goto-char (point-min))
            (search-forward "| alpha")
            (should (equal (ogent-ui-models--browser-model-at-point)
                           "alpha"))
            (goto-char (point-min))
            (should-not (ogent-ui-models--browser-model-at-point))))))
    (when (get-buffer ogent-ui-models--browser-buffer-name)
      (kill-buffer ogent-ui-models--browser-buffer-name))))

(ert-deftest ogent-ui-models-browser-refresh-preserves-origin ()
  "Refreshing from inside the browser keeps the origin's effective pin."
  (ogent-ui-models-tests--with-registry
    (with-temp-buffer
      (org-mode)
      (insert "* Pinned\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\nBody\n")
      (goto-char (point-max))
      (let ((gptel-model "alpha"))
        (save-window-excursion
          (ogent-models-browse)
          ;; Simulate `g': re-invoke from inside the browser buffer.
          (with-current-buffer ogent-ui-models--browser-buffer-name
            (ogent-models-browse))
          (with-current-buffer ogent-ui-models--browser-buffer-name
            (should (string-match-p
                     "Effective model: =beta= (via org property)"
                     (buffer-string)))))))
    (when (get-buffer ogent-ui-models--browser-buffer-name)
      (kill-buffer ogent-ui-models--browser-buffer-name))))

(ert-deftest ogent-ui-models-browser-refresh-survives-dead-origin ()
  "Refreshing after the origin buffer dies falls back gracefully."
  (ogent-ui-models-tests--with-registry
    (let ((gptel-model nil))
      (save-window-excursion
        (with-temp-buffer
          (org-mode)
          (insert "* Pinned\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n")
          (goto-char (point-max))
          (ogent-models-browse))
        ;; The temp origin is dead now; refresh must not error and
        ;; must resolve honestly without the stale pin.
        (with-current-buffer ogent-ui-models--browser-buffer-name
          (ogent-models-browse)
          (should (string-match-p "Effective model: =alpha= (via default)"
                                  (buffer-string))))))
    (when (get-buffer ogent-ui-models--browser-buffer-name)
      (kill-buffer ogent-ui-models--browser-buffer-name))))

(provide 'ogent-ui-models-tests)
;;; ogent-ui-models-tests.el ends here

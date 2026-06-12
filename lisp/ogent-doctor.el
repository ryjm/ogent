;;; ogent-doctor.el --- Environment diagnostics for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a read-only health report for ogent's local Emacs/package/provider
;; setup.  The core returns data plists so tests and future automation can use
;; it without scraping a buffer.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'org)
(require 'ogent-gptel)
(require 'ogent-models)

(declare-function transient-define-prefix "ext:transient")
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(declare-function ogent-codex-oauth--auth-file "ogent-codex-oauth")
(declare-function ogent-codex-oauth-mode "ogent-codex-oauth")
(declare-function ogent-codex-oauth-get-api-key "ogent-codex-oauth")
(declare-function ogent-anthropic-oauth--find-existing-token-file "ogent-anthropic-oauth")

(defvar transient-version)
(defvar gptel-backend)
(defvar gptel-use-tools)

(defgroup ogent-doctor nil
  "Diagnostics for ogent setup."
  :group 'ogent)

(defcustom ogent-doctor-required-emacs-version "29.1"
  "Minimum Emacs version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defcustom ogent-doctor-required-org-version "9.8.5"
  "Minimum Org version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defcustom ogent-doctor-required-transient-version "0.13.4"
  "Minimum Transient version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defvar ogent-doctor-buffer-name "*ogent-doctor*"
  "Buffer name for `ogent-doctor' reports.")

(defconst ogent-doctor-checks
  '((:id emacs-version :label "Emacs version" :fn ogent-doctor--check-emacs-version)
    (:id org-version :label "Org version" :fn ogent-doctor--check-org-version)
    (:id gptel :label "gptel transport" :fn ogent-doctor--check-gptel)
    (:id transient :label "Transient menus" :fn ogent-doctor--check-transient)
    (:id model-registry :label "Model registry" :fn ogent-doctor--check-model-registry)
    (:id default-model :label "Default model" :fn ogent-doctor--check-default-model)
    (:id backend :label "gptel backend" :fn ogent-doctor--check-backend)
    (:id gptel-tools :label "gptel tools flag" :fn ogent-doctor--check-gptel-tools)
    (:id br :label "br issue tracker" :fn ogent-doctor--check-br)
    (:id codex-auth :label "Codex OAuth cache" :fn ogent-doctor--check-codex-auth)
    (:id anthropic-auth :label "Claude OAuth cache" :fn ogent-doctor--check-anthropic-auth))
  "Data-driven list of doctor checks.")

(defun ogent-doctor--result (id label status detail)
  "Return a doctor result plist for ID, LABEL, STATUS, and DETAIL."
  (list :id id :label label :status status :detail detail))

(defun ogent-doctor--version-status (current required)
  "Return `ok' when CURRENT is at least REQUIRED, otherwise `error'."
  (if (and current (not (version< current required))) 'ok 'error))

(defun ogent-doctor--version-detail (name current required)
  "Return human-readable version detail for NAME, CURRENT, and REQUIRED."
  (if current
      (format "%s %s (required >= %s)" name current required)
    (format "%s version unknown (required >= %s)" name required)))

(defun ogent-doctor--check-emacs-version (id label)
  "Check current Emacs version for ID and LABEL."
  (let ((status (ogent-doctor--version-status
                 emacs-version ogent-doctor-required-emacs-version)))
    (ogent-doctor--result
     id label status
     (ogent-doctor--version-detail
      "Emacs" emacs-version ogent-doctor-required-emacs-version))))

(defun ogent-doctor--check-org-version (id label)
  "Check Org can load and meets the configured minimum for ID and LABEL."
  (if (require 'org nil t)
      (let* ((version (org-version))
             (status (ogent-doctor--version-status
                      version ogent-doctor-required-org-version)))
        (ogent-doctor--result
         id label status
         (ogent-doctor--version-detail
          "Org" version ogent-doctor-required-org-version)))
    (ogent-doctor--result id label 'error "Org is not loadable")))

(defun ogent-doctor--check-gptel (id label)
  "Check gptel can load and exposes its request entrypoint."
  (if (and (require 'gptel nil t) (fboundp 'gptel-request))
      (ogent-doctor--result id label 'ok "gptel loaded and `gptel-request' is available")
    (ogent-doctor--result id label 'error "gptel is not loadable or lacks `gptel-request'")))

(defun ogent-doctor--check-transient (id label)
  "Check Transient can load and meets the configured minimum when versioned."
  (if (and (require 'transient nil t) (fboundp 'transient-define-prefix))
      (let* ((version (and (boundp 'transient-version) transient-version))
             (status (if version
                         (ogent-doctor--version-status
                          version ogent-doctor-required-transient-version)
                       'ok))
             (detail (if version
                         (ogent-doctor--version-detail
                          "Transient" version ogent-doctor-required-transient-version)
                       "Transient loaded; version variable is unavailable")))
        (ogent-doctor--result id label status detail))
    (ogent-doctor--result id label 'error "Transient is not loadable")))

(defun ogent-doctor--check-model-registry (id label)
  "Check the ogent model registry shape."
  (condition-case err
      (let* ((models (ogent-models-all))
             (bad (seq-filter (lambda (model)
                                (or (not (plist-get model :id))
                                    (not (plist-get model :backend))))
                              models)))
        (if bad
            (ogent-doctor--result
             id label 'error
             (format "%d model entries lack :id or :backend" (length bad)))
          (ogent-doctor--result
           id label 'ok
           (format "%d model entries registered" (length models)))))
    (error (ogent-doctor--result id label 'error (error-message-string err)))))

(defun ogent-doctor--check-default-model (id label)
  "Check `ogent-default-model' resolves to a registered model."
  (if (and (boundp 'ogent-default-model)
           ogent-default-model
           (ogent-models-get ogent-default-model))
      (ogent-doctor--result id label 'ok (format "Default model: %s" ogent-default-model))
    (ogent-doctor--result id label 'error
                          (format "Default model is not registered: %S"
                                  (and (boundp 'ogent-default-model)
                                       ogent-default-model)))))

(defun ogent-doctor--check-backend (id label)
  "Check the default model resolves to a gptel backend candidate."
  (condition-case err
      (let* ((model (ogent-models-default))
             (backend (and model (ogent-gptel-resolve-backend model))))
        (cond
         ((not backend)
          (ogent-doctor--result id label 'warn "Default model has no backend"))
         ((stringp backend)
          (ogent-doctor--result id label 'warn
                                (format "Backend %S has not resolved to an object" backend)))
         ((symbolp backend)
          (ogent-doctor--result id label 'warn
                                (format "Backend %S is unresolved" backend)))
         (t
          (ogent-doctor--result id label 'ok
                                (format "Backend object: %s" (type-of backend))))))
    (error (ogent-doctor--result id label 'warn (error-message-string err)))))

(defun ogent-doctor--check-gptel-tools (id label)
  "Report whether gptel tool execution is enabled."
  (if (and (boundp 'gptel-use-tools) gptel-use-tools)
      (ogent-doctor--result id label 'ok "`gptel-use-tools' is enabled")
    (ogent-doctor--result id label 'info "`gptel-use-tools' is not enabled")))

(defun ogent-doctor--check-br (id label)
  "Check whether br is available for issue integration."
  (if-let ((path (executable-find "br")))
      (ogent-doctor--result id label 'ok (format "br found at %s" path))
    (ogent-doctor--result id label 'warn "br executable not found in PATH")))

(defun ogent-doctor--check-codex-auth (id label)
  "Check local Codex OAuth cache presence without network calls."
  (if (require 'ogent-codex-oauth nil t)
      (let ((file (ogent-codex-oauth--auth-file))
            (mode (ignore-errors (ogent-codex-oauth-mode)))
            (has-key (ignore-errors (ogent-codex-oauth-get-api-key))))
        (cond
         (has-key
          (ogent-doctor--result id label 'ok
                                (format "Codex auth cache is usable%s"
                                        (if mode (format " (%s)" mode) ""))))
         ((file-readable-p file)
          (ogent-doctor--result id label 'warn
                                (format "Codex auth file exists but has no OPENAI_API_KEY: %s" file)))
         (t
          (ogent-doctor--result id label 'info
                                (format "No Codex auth file at %s" file)))))
    (ogent-doctor--result id label 'info "Codex OAuth module is not loadable")))

(defun ogent-doctor--check-anthropic-auth (id label)
  "Check local Claude OAuth token cache presence without network calls."
  (if (require 'ogent-anthropic-oauth nil t)
      (if-let ((file (ignore-errors (ogent-anthropic-oauth--find-existing-token-file))))
          (ogent-doctor--result id label 'ok (format "Claude OAuth token file found at %s" file))
        (ogent-doctor--result id label 'info "No Claude OAuth token file found"))
    (ogent-doctor--result id label 'info "Claude OAuth module is not loadable")))

(defun ogent-doctor-run ()
  "Run all ogent doctor checks and return result plists."
  (mapcar
   (lambda (check)
     (let ((id (plist-get check :id))
           (label (plist-get check :label))
           (fn (plist-get check :fn)))
       (condition-case err
           (funcall fn id label)
         (error (ogent-doctor--result id label 'error
                                      (error-message-string err))))))
   ogent-doctor-checks))

(defun ogent-doctor-summary-status (results)
  "Return worst doctor status in RESULTS."
  (cond
   ((seq-some (lambda (result) (eq (plist-get result :status) 'error)) results)
    'error)
   ((seq-some (lambda (result) (eq (plist-get result :status) 'warn)) results)
    'warn)
   (t 'ok)))

(defun ogent-doctor--status-label (status)
  "Return display label for STATUS."
  (pcase status
    ('ok "OK")
    ('warn "WARN")
    ('error "ERROR")
    ('info "INFO")
    (_ (upcase (format "%s" status)))))

(defun ogent-doctor-format-check (result)
  "Return one formatted line block for doctor RESULT."
  (format "[%s] %s\n     %s"
          (ogent-doctor--status-label (plist-get result :status))
          (plist-get result :label)
          (or (plist-get result :detail) "")))

(defun ogent-doctor-format (results)
  "Return an Org report string for doctor RESULTS."
  (concat
   "* Ogent Doctor\n"
   (format "Status: %s\n\n" (ogent-doctor--status-label
                              (ogent-doctor-summary-status results)))
   (mapconcat #'ogent-doctor-format-check results "\n\n")
   "\n"))

;;;###autoload
(defun ogent-doctor ()
  "Display a read-only health report for the current ogent setup."
  (interactive)
  (let* ((results (ogent-doctor-run))
         (status (ogent-doctor-summary-status results))
         (buffer (get-buffer-create ogent-doctor-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (ogent-doctor-format results))
        (org-mode)
        (view-mode 1)
        (goto-char (point-min))))
    (display-buffer buffer)
    (message "ogent doctor: %s" (ogent-doctor--status-label status))
    results))

(provide 'ogent-doctor)

;;; ogent-doctor.el ends here

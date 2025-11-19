;;; ogent-models.el --- Model registry for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Centralizes metadata about supported LLM backends so UI and request
;; code have a single source of truth.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup ogent-models nil
  "Configuration for ogent model registry."
  :group 'ogent)

(defvar ogent-default-model nil
  "Placeholder for the default model id.")

(defcustom ogent-model-registry
  '((:id "gpt-4o-mini" :backend gptel-openai :stream? t
          :description "OpenAI GPT-4o mini")
    (:id "gpt-4o" :backend gptel-openai :stream? t
          :description "OpenAI GPT-4o")
    (:id "claude-3.5" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude 3.5"))
  "List of model definitions used by ogent.
Each entry is a plist supporting at least :id, :backend, and :stream? keys.
You may add :preset or any other metadata consumed by custom workflows."
  :type '(repeat (plist :options (:id :backend :preset :stream? :description)))
  :group 'ogent-models)

(defun ogent-models-all ()
  "Return every registered ogent model plist."
  (or ogent-model-registry
      (user-error "`ogent-model-registry' does not contain any models")))

(defun ogent-models-get (model-id)
  "Return the plist describing MODEL-ID or nil if unknown."
  (seq-find (lambda (entry)
              (string= (plist-get entry :id) model-id))
            (ogent-models-all)))

(defun ogent-models-ensure (model-id)
  "Return MODEL-ID entry or signal a user error if missing."
  (or (ogent-models-get model-id)
      (user-error "Unknown ogent model: %s" model-id)))

(defun ogent-models-default ()
  "Return the default model plist.
Falls back to the first registry entry if `ogent-default-model' is unset."
  (or (and ogent-default-model
           (ogent-models-get ogent-default-model))
      (car (ogent-models-all))))

(defun ogent-models-ids ()
  "Return a list of known model identifiers."
  (mapcar (lambda (entry) (plist-get entry :id))
          (ogent-models-all)))

(provide 'ogent-models)

;;; ogent-models.el ends here

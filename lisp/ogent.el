;;; ogent.el --- Entry point for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Load the ogent subsystems so users can `(require 'ogent')`.

;;; Code:

(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-core)
(require 'ogent-codemap)
(require 'ogent-ui)
(require 'ogent-onboard)

(provide 'ogent)

;;; ogent.el ends here

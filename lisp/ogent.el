;;; ogent.el --- AI assistant with Org-mode integration -*- lexical-binding: t; -*-

;; Author: Jake Chvatal
;; Maintainer: Jake Chvatal
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9") (transient "0.6") (org "9.6"))
;; Homepage: https://github.com/jake-87/ogent
;; Keywords: ai, llm, org-mode, tools, convenience

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Ogent is an AI assistant for Emacs that integrates deeply with Org-mode.
;; It provides:
;;
;; - Structured context management via @handle references
;; - Model selection and presets via gptel integration
;; - Companion buffers for non-Org files
;; - Inline code editing with smerge-based accept/reject workflow
;; - Codemap generation for codebase exploration
;;
;; Quick start:
;;   (require 'ogent)
;;   (ogent-global-mode 1)
;;
;; Then use C-c o p to open the prompt dispatcher.
;;
;; For more information, see the README at:
;; https://github.com/jake-87/ogent

;;; Code:

;; Ensure the ui/ subdirectory is in load-path before requiring ogent-ui
;; This handles package managers that only add the main lisp/ directory
(let ((ui-dir (expand-file-name "ui" (file-name-directory
                                       (or load-file-name buffer-file-name)))))
  (unless (member ui-dir load-path)
    (add-to-list 'load-path ui-dir)))

(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-companion)
(require 'ogent-core)
(require 'ogent-codemap)
(require 'ogent-ui)
(require 'ogent-onboard)
(require 'ogent-edit)
(require 'ogent-anthropic-oauth)

(provide 'ogent)

;;; ogent.el ends here

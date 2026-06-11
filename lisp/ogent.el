;;; ogent.el --- AI assistant with Org-mode integration -*- lexical-binding: t; -*-

;; Author: Jake Miller
;; Maintainer: Jake Miller
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

;; Ensure sibling modules are available before requiring the package graph.
;; Doom/straight builds local packages as symlinks, and newly added files can
;; exist in the real source tree before the build directory is regenerated.
(let* ((entry-file (or load-file-name buffer-file-name))
       (entry-dir (and entry-file (file-name-directory entry-file)))
       (source-dir (and entry-file
                        (file-name-directory (file-truename entry-file)))))
  (dolist (dir (delete-dups
                (delq nil
                      (list entry-dir
                            source-dir
                            (when entry-dir
                              (expand-file-name "ui" entry-dir))
                            (when source-dir
                              (expand-file-name "ui" source-dir))))))
    (when (and (file-directory-p dir)
               (not (member dir load-path)))
      (add-to-list 'load-path dir))))

(defvar org-capture-templates-contexts nil
  "Alist of Org capture templates and their valid contexts.")

(defun ogent--ensure-org-capture-templates-contexts (&rest _)
  "Ensure stale Org capture builds define `org-capture-templates-contexts'."
  (unless (default-boundp 'org-capture-templates-contexts)
    (setq-default org-capture-templates-contexts nil))
  (unless (boundp 'org-capture-templates-contexts)
    (setq org-capture-templates-contexts
          (default-value 'org-capture-templates-contexts))))

(defun ogent--with-org-capture-templates-contexts (fn &rest args)
  "Call FN with ARGS and `org-capture-templates-contexts' safely bound."
  (ogent--ensure-org-capture-templates-contexts)
  (let ((org-capture-templates-contexts
         (if (boundp 'org-capture-templates-contexts)
             org-capture-templates-contexts
           nil)))
    (apply fn args)))

(defun ogent--advise-org-capture-contexts (symbol)
  "Advise SYMBOL to tolerate stale Org capture builds."
  (unless (advice-member-p #'ogent--with-org-capture-templates-contexts symbol)
    (advice-add symbol :around #'ogent--with-org-capture-templates-contexts)))

(ogent--ensure-org-capture-templates-contexts)

(with-eval-after-load 'org-capture
  (ogent--ensure-org-capture-templates-contexts)
  (ogent--advise-org-capture-contexts 'org-capture)
  (ogent--advise-org-capture-contexts 'org-capture-goto-target)
  (ogent--advise-org-capture-contexts 'org-capture-select-template))

(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-tools)
(require 'ogent-ledger)
(require 'ogent-companion)
(require 'ogent-core)
(require 'ogent-codemap)
(require 'ogent-ui-theme)  ; Design system - load before UI
(require 'ogent-ui)
(require 'ogent-ui-backlinks)
(require 'ogent-ui-graph)
(require 'ogent-onboard)
(require 'ogent-edit)
(require 'ogent-notes)
(require 'ogent-session)
(require 'ogent-debug)
(require 'ogent-anthropic-oauth)
(require 'ogent-codex-oauth)
(require 'ogent-completions)
(require 'ogent-mcp)
(require 'ogent-armory)
(require 'ogent-armory-adapter)
(require 'ogent-armory-conversations)
(require 'ogent-armory-data)
(require 'ogent-armory-git)
(require 'ogent-armory-skills)
(require 'ogent-armory-compose)
(require 'ogent-armory-actions)
(require 'ogent-armory-runner)
(require 'ogent-armory-schedule)
(require 'ogent-armory-palette)
(require 'ogent-armory-settings)
(require 'ogent-ui-armory)
(require 'ogent-armory-status)
(require 'ogent-presets)
(require 'ogent-analytics)
(require 'ob-ogent)

;; Install default tool implementations
(ogent-tools-install-defaults)

;; Enable the ogent Org Babel language so prompt src blocks execute.
(with-eval-after-load 'org
  (when (boundp 'org-babel-load-languages)
    (add-to-list 'org-babel-load-languages '(ogent . t))))

(provide 'ogent)

;;; ogent.el ends here

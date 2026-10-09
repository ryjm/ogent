;;; boot.el --- Round 14 actual offline dependencies -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'jka-compr)
(setq load-suffixes (remove ".elc" load-suffixes))
(dolist (directory (directory-files (getenv "REVIEW_ELPA") t "^[^.].*"))
  (when (file-directory-p directory) (add-to-list 'load-path directory)))
(when (getenv "REVIEW_GPTEL") (add-to-list 'load-path (getenv "REVIEW_GPTEL")))
(require 'org)
(require 'gptel)
(require 'gptel-request)
(require 'gptel-openai)
(require 'gptel-anthropic)
(require 'transient)
(load-file "/work/test/ogent-test-helper.el")
(message "REVIEW14 Emacs=%s Org=%s transient=%s gptel=%s source=%s"
         emacs-version (org-version) transient-version
         (if (boundp 'gptel-version) gptel-version "source") (symbol-file 'gptel-request))

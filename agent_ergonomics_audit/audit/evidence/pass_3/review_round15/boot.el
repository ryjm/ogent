;;; boot.el --- Actual offline dependencies for review 15 -*- lexical-binding: t; -*-
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
(setq temporary-file-directory (file-name-as-directory (getenv "REVIEW_TEMP")))
(load-file "/work/test/ogent-test-helper.el")
(message "REVIEW15 Emacs=%s Org=%s transient=%s gptel=%s gptel_source=%s"
         emacs-version (org-version) transient-version gptel-version
         (symbol-file 'gptel-request))

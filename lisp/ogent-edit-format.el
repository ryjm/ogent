;;; ogent-edit-format.el --- Edit format constants and prompt templates -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines the SEARCH/REPLACE block format for LLM code edits.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)

(defgroup ogent-edit nil
  "Inline code editing for ogent."
  :group 'ogent)

;;; Format Constants

(defconst ogent-edit-search-marker "<<<<<<< SEARCH"
  "Marker indicating the start of old code in an edit block.")

(defconst ogent-edit-separator "======="
  "Separator between old and new code in an edit block.")

(defconst ogent-edit-replace-marker ">>>>>>> REPLACE"
  "Marker indicating the end of new code in an edit block.")

(defconst ogent-edit-search-regex
  (rx bol "<<<<<<< SEARCH" "\n")
  "Regex to match the start of an edit block.")

(defconst ogent-edit-separator-regex
  (rx bol "=======" "\n")
  "Regex to match the separator in an edit block.")

(defconst ogent-edit-replace-regex
  (rx bol ">>>>>>> REPLACE")
  "Regex to match the end of an edit block.")

;;; Data Structures

(cl-defstruct ogent-edit
  "A single code edit extracted from LLM response."
  id              ; unique identifier (ogent-edit-001, etc.)
  old-text        ; exact text to search for
  new-text        ; replacement text
  source-buffer   ; buffer containing source code
  source-file     ; file path (if file-backed)
  start-pos       ; position where old-text was found (after validation)
  end-pos         ; end position of old-text
  source-marker   ; marker in source buffer for navigation
  companion-marker ; marker in companion buffer for navigation
  status          ; pending | applied | rejected | error
  error-message   ; why validation/application failed
  timestamp)      ; when edit was created

;;; Edit ID Generation

(defvar ogent-edit--counter 0
  "Counter for generating unique edit IDs within a session.")

(defun ogent-edit--generate-id ()
  "Generate a unique edit ID."
  (cl-incf ogent-edit--counter)
  (format "ogent-edit-%03d" ogent-edit--counter))

(defun ogent-edit--reset-counter ()
  "Reset the edit ID counter.  Useful for testing."
  (setq ogent-edit--counter 0))

;;; Prompt Templates

(defconst ogent-edit-system-prompt
  "When making code changes, format each edit as a SEARCH/REPLACE block:

<<<<<<< SEARCH
[exact original code to find]
=======
[replacement code]
>>>>>>> REPLACE

Rules:
- The SEARCH section must match the original code EXACTLY (whitespace matters)
- Include enough context lines to make the match unique
- You can have multiple SEARCH/REPLACE blocks in one response
- Explain your changes before or after the blocks"
  "System prompt instructions for edit mode.")

(defun ogent-edit-wrap-prompt (user-prompt filename mode content)
  "Wrap USER-PROMPT with edit context.
FILENAME is the source file name.
MODE is the major mode name (e.g., \"emacs-lisp-mode\").
CONTENT is the source code content."
  (let ((language (ogent-edit--mode-to-language mode)))
    (format "The user wants to modify code in `%s` (%s).

%s

Current code:
```%s
%s
```

Provide your changes using SEARCH/REPLACE blocks."
            filename mode user-prompt language content)))

(defun ogent-edit--mode-to-language (mode)
  "Convert MODE name to a language identifier for code blocks.
MODE is a string like \"emacs-lisp-mode\"."
  (let ((mode-str (if (symbolp mode) (symbol-name mode) mode)))
    (cond
     ((string-match-p "emacs-lisp" mode-str) "elisp")
     ((string-match-p "lisp" mode-str) "lisp")
     ((string-match-p "python" mode-str) "python")
     ((string-match-p "javascript\\|js" mode-str) "javascript")
     ((string-match-p "typescript\\|ts" mode-str) "typescript")
     ((string-match-p "ruby" mode-str) "ruby")
     ((string-match-p "rust" mode-str) "rust")
     ((string-match-p "go-" mode-str) "go")
     ((string-match-p "java" mode-str) "java")
     ((string-match-p "c\\+\\+" mode-str) "cpp")
     ((string-match-p "c-mode" mode-str) "c")
     ((string-match-p "sh-mode\\|bash" mode-str) "bash")
     ((string-match-p "sql" mode-str) "sql")
     ((string-match-p "html" mode-str) "html")
     ((string-match-p "css" mode-str) "css")
     ((string-match-p "json" mode-str) "json")
     ((string-match-p "yaml\\|yml" mode-str) "yaml")
     ((string-match-p "markdown\\|md" mode-str) "markdown")
     ((string-match-p "org" mode-str) "org")
     (t ""))))

(provide 'ogent-edit-format)

;;; ogent-edit-format.el ends here

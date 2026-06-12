;;; ogent-tool-approval.el --- Tool approval policy for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines the allow-list, deny-list, prompting, and effects-based approval
;; policy used before executing model-requested tools.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ogent-tool-effects)

(declare-function ogent-tool-spec-get "ogent-models" (name))

(defcustom ogent-tool-allow-list nil
  "List of patterns for auto-approved tool calls.
Each pattern is a string like \"ToolName(arg:pattern)\" where:
- ToolName matches the tool name exactly
- arg:pattern matches an argument (supports glob wildcards)
- * inside parens matches any arguments
- No parens means any invocation of that tool is allowed

Examples:
  \"read-file\" - allow all read-file calls
  \"bash(command:git *)\" - allow bash with git commands
  \"bash(command:make test:*)\" - allow make test and variations
  \"glob(*)\" - allow all glob calls

Patterns are case-sensitive and checked in order."
  :type '(repeat string)
  :group 'ogent-mode)

(defcustom ogent-tool-require-approval t
  "When non-nil, prompt for approval before executing tools.
Tools matching `ogent-tool-allow-list' are auto-approved.
When nil, all tools execute without prompting."
  :type 'boolean
  :group 'ogent-mode)

(defun ogent-tool--name-string (tool-name)
  "Return TOOL-NAME as a string, or nil when it is not usable."
  (cond
   ((null tool-name) nil)
   ((stringp tool-name) tool-name)
   ((symbolp tool-name) (symbol-name tool-name))
   (t nil)))

(defun ogent-tool--name-symbol (tool-name)
  "Return TOOL-NAME as a symbol, or nil when it is not usable."
  (cond
   ((symbolp tool-name) tool-name)
   ((stringp tool-name) (intern tool-name))
   (t nil)))

(defun ogent-tool--pattern-match-p (pattern tool-name args)
  "Return non-nil if TOOL-NAME with ARGS matches PATTERN.
PATTERN format: \"tool-name\" or \"tool-name(arg:glob)\"."
  (let ((tool-name (ogent-tool--name-string tool-name)))
    (if (and tool-name
             (string-match "^\\([^(]+\\)\\(?:(\\(.*\\))\\)?$" pattern))
        (let ((pat-name (match-string 1 pattern))
              (pat-args (match-string 2 pattern)))
          (and (string= pat-name tool-name)
               (or (null pat-args)
                   (string= pat-args "*")
                   (ogent-tool--args-match-p pat-args args))))
      nil)))

(defun ogent-tool--args-match-p (arg-pattern args)
  "Return non-nil if ARG-PATTERN matches ARGS plist.
ARG-PATTERN format: \"argname:glob\" or \"argname:glob,other:glob\"."
  (let ((patterns (split-string arg-pattern ",")))
    (cl-every
     (lambda (pat)
       (if (string-match "^\\([^:]+\\):\\(.*\\)$" pat)
           (let* ((arg-name (match-string 1 pat))
                  (glob (match-string 2 pat))
                  (arg-keyword (intern (concat ":" arg-name)))
                  (arg-val (plist-get args arg-keyword)))
             (if arg-val
                 (ogent-tool--glob-match-p glob (format "%s" arg-val))
               (string= glob "*")))
         t))
     patterns)))

(defun ogent-tool--glob-match-p (pattern string)
  "Return non-nil if PATTERN matches STRING using `*' as a wildcard."
  (let* ((parts (split-string pattern "\\*"))
         (quoted-parts (mapcar #'regexp-quote parts))
         (regexp (concat "\\`" (string-join quoted-parts ".*") "\\'")))
    (string-match-p regexp string)))

(defun ogent-tool--allowed-p (tool-name args)
  "Return non-nil if TOOL-NAME with ARGS is in the allow-list."
  (cl-some (lambda (pattern)
             (ogent-tool--pattern-match-p pattern tool-name args))
           ogent-tool-allow-list))

(defun ogent-tool--format-preview (tool-name args)
  "Format an approval preview string for TOOL-NAME with ARGS."
  (let* ((tool-symbol (ogent-tool--name-symbol tool-name))
         (spec (and tool-symbol
                    (fboundp 'ogent-tool-spec-get)
                    (ogent-tool-spec-get tool-symbol)))
         (preview (format "Tool: %s\n" tool-name)))
    (when spec
      (setq preview
            (concat preview
                    "Effects:\n"
                    (ogent-tool-effects-format
                     (plist-get spec :effects))
                    "\n")))
    (when args
      (setq preview (concat preview "Arguments:\n"))
      (let ((pairs nil))
        (while args
          (push (format "  %s: %s" (car args) (cadr args)) pairs)
          (setq args (cddr args)))
        (setq preview (concat preview (string-join (nreverse pairs) "\n")))))
    preview))

(defun ogent-tool--prompt-approval (tool-name args)
  "Prompt user to approve TOOL-NAME with ARGS.
Return `approve', `deny', `always', or `never'."
  (let* ((preview (ogent-tool--format-preview tool-name args))
         (prompt (format "%s\n\nAllow? (y)es, (n)o, (a)lways, n(e)ver: " preview))
         (response (read-char-choice prompt '(?y ?n ?a ?e))))
    (pcase response
      (?y 'approve)
      (?n 'deny)
      (?a 'always)
      (?e 'never))))

(defun ogent-tool--add-to-allow-list (tool-name args)
  "Add TOOL-NAME to `ogent-tool-allow-list'.
If ARGS is non-nil, create a pattern matching those specific args."
  (when-let ((name (ogent-tool--name-string tool-name)))
    (let ((pattern (if (and args (plist-get args :command))
                       (let ((cmd (plist-get args :command)))
                         (if (string-match "^\\([^ ]+\\)" cmd)
                             (format "%s(command:%s *)" name (match-string 1 cmd))
                           name))
                     name)))
      (unless (member pattern ogent-tool-allow-list)
        (customize-save-variable 'ogent-tool-allow-list
                                 (cons pattern ogent-tool-allow-list))))))

(defvar ogent-tool--denied-tools nil
  "List of tool patterns permanently denied in this session.")

(defun ogent-tool--add-to-deny-list (tool-name)
  "Add TOOL-NAME to the session deny list."
  (when-let ((name (ogent-tool--name-string tool-name)))
    (unless (member name ogent-tool--denied-tools)
      (push name ogent-tool--denied-tools))))

(defun ogent-tool--denied-p (tool-name)
  "Return non-nil if TOOL-NAME is in the session deny list."
  (when-let ((name (ogent-tool--name-string tool-name)))
    (member name ogent-tool--denied-tools)))

(defun ogent-tool-approval-check (tool-name tool-args)
  "Return approval decision for TOOL-NAME with TOOL-ARGS.
The return value is `approved' or `denied'."
  (let ((tool-symbol (ogent-tool--name-symbol tool-name)))
    (cond
     ((not tool-symbol) 'denied)
     ((not ogent-tool-require-approval) 'approved)
     ((ogent-tool--denied-p tool-name) 'denied)
     ((ogent-tool--allowed-p tool-name tool-args) 'approved)
     ((let ((spec (and (fboundp 'ogent-tool-spec-get)
                       (ogent-tool-spec-get tool-symbol))))
        (and spec
             (not (or (plist-get spec :confirm)
                      (ogent-tool-effects-approval-required-p
                       (plist-get spec :effects))))))
      'approved)
     (t (let ((response (ogent-tool--prompt-approval tool-name tool-args)))
          (pcase response
            ('approve 'approved)
            ('deny 'denied)
            ('always
             (ogent-tool--add-to-allow-list tool-name tool-args)
             'approved)
            ('never
             (ogent-tool--add-to-deny-list tool-name)
             'denied)))))))

(provide 'ogent-tool-approval)

;;; ogent-tool-approval.el ends here

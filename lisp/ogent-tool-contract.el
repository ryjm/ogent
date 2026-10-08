;;; ogent-tool-contract.el --- Validate tool arguments -*- lexical-binding: t; -*-

;;; Commentary:
;; Validate and normalize registry arguments before approval or execution.
;; Preserve nested objects and distinguish absent values from explicit false.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup ogent-tool-contract nil
  "Argument contracts for ogent tools."
  :group 'ogent)

(defun ogent-tool-contract-name-hint (name names)
  "Return a corrective lookup hint for unknown NAME among NAMES."
  (let* ((input (format "%s" name))
         (choices (sort (mapcar (lambda (item) (format "%s" item)) names) #'string<))
         (closest (car (sort (copy-sequence choices)
                             (lambda (a b)
                               (< (string-distance input a)
                                  (string-distance input b)))))))
    (format "Unknown tool: %s; %savailable tools: %s. Use ogent-agent-capabilities to inspect argument names"
            input
            (if (and closest (<= (string-distance input closest) 2))
                (format "did you mean %s? " closest) "")
            (if choices (string-join choices ", ")
              "none; run ogent-tools-install-defaults or register your tools"))))

(defun ogent-tool-contract--key-name (key)
  "Return the canonical argument spelling for KEY."
  (let ((name (cond ((symbolp key) (symbol-name key))
                    ((stringp key) key))))
    (when name
      (replace-regexp-in-string "-" "_" (string-remove-prefix ":" name)))))

(defun ogent-tool-contract--type-p (type value)
  "Return non-nil when VALUE satisfies registry TYPE."
  (pcase type
    ("string" (stringp value))
    ("integer" (integerp value))
    ("number" (numberp value))
    ("boolean" (memq value '(nil t :json-false :false false :json-true :true true)))
    ("array" (or (vectorp value) (proper-list-p value)))
    ("object" (or (hash-table-p value) (proper-list-p value)))
    ("null" (memq value '(nil :null :json-null null)))
    ;; Preserve extension schemas whose types are validated by their owner.
    (_ t)))

(defun ogent-tool-contract-validate-values (spec values)
  "Validate positional VALUES for SPEC and return normalized values.
Reject excess arguments and missing required scalar values before execution.
Preserve nested objects; normalize only declared boolean arguments."
  (let* ((name (plist-get spec :name))
         (arguments (plist-get spec :args))
         (supplied (length values)))
    (when (> supplied (length arguments))
      (user-error "%s received %d arguments but accepts %d; use its declared argument names"
                  name supplied (length arguments)))
    (cl-loop
     for argument in arguments
     for index from 0
     for value = (nth index values)
     for type = (plist-get argument :type)
     for key = (plist-get argument :name)
     for optional = (plist-get argument :optional)
     collect
     (cond
      ((and optional (null value)) nil)
      ((or (and (not optional) (>= index supplied))
           (not (ogent-tool-contract--type-p type value)))
       (user-error "%s argument %s requires %s; provide %s with that type"
                   name key type key))
      (t
       (when-let ((enum (plist-get argument :enum)))
         (unless (member value (append enum nil))
           (user-error "%s argument %s must be one of %S; choose a listed value"
                       name key enum)))
       (if (equal type "boolean")
           (and (memq value '(t :json-true :true true)) t)
         value))))))

(defun ogent-tool-contract-values (spec args)
  "Validate ARGS against SPEC and return ordered positional values.
Accept keyword or symbol keys with hyphens or underscores.  Preserve explicit
false values and reject unknown or duplicate argument names with guidance."
  (unless (and (proper-list-p args) (zerop (% (length args) 2)))
    (user-error "%s arguments must be a property list; use named keyword/value pairs"
                (plist-get spec :name)))
  (let* ((arguments (plist-get spec :args))
         (names (mapcar (lambda (argument) (plist-get argument :name)) arguments))
         seen canonical)
    (cl-loop for (key value) on args by #'cddr
             for name = (ogent-tool-contract--key-name key)
             do
             (unless (member name names)
               (let ((closest (and (stringp name)
                                   (car (sort (copy-sequence names)
                                              (lambda (a b)
                                                (< (string-distance name a)
                                                   (string-distance name b))))))))
                 (user-error "%s has no argument %S; %suse declared arguments %S"
                             (plist-get spec :name) key
                             (if (and closest (<= (string-distance name closest) 2))
                                 (format "did you mean %s? " closest) "")
                             names)))
             (when (member name seen)
               (user-error "%s argument %s was supplied twice; use one spelling"
                           (plist-get spec :name) name))
             (push name seen)
             (push (cons name value) canonical))
    (dolist (argument arguments)
      (unless (or (plist-get argument :optional)
                  (assoc (plist-get argument :name) canonical))
        (user-error "%s requires argument %s; provide that named value"
                    (plist-get spec :name) (plist-get argument :name))))
    (ogent-tool-contract-validate-values
     spec (mapcar (lambda (argument)
                    (cdr (assoc (plist-get argument :name) canonical)))
                  arguments))))

(provide 'ogent-tool-contract)
;;; ogent-tool-contract.el ends here

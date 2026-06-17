;;; ogent-tool-effects.el --- Tool effect metadata for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines a small effect schema for tool permissions and audit trails.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup ogent-tool-effects nil
  "Tool effect metadata and risk scoring."
  :group 'ogent)

(defconst ogent-tool-effects-known-kinds
  '(read write execute network git issue emacs-state)
  "Known tool effect kinds.")

(defconst ogent-tool-effects-approval-kinds
  '(write execute network git issue emacs-state)
  "Effect kinds that require approval by default.")

(defconst ogent-tool-effects--risk-ranks
  '((none . 0)
    (low . 1)
    (medium . 2)
    (high . 3)
    (critical . 4))
  "Risk ordering used when combining tool effects.")

(defun ogent-tool-effects--plist-p (value)
  "Detect whether VALUE is a plist."
  (and (consp value)
       (keywordp (car value))))

(defun ogent-tool-effects--normalize-symbol (value)
  "Return VALUE as a plain symbol."
  (cond
   ((keywordp value) (intern (substring (symbol-name value) 1)))
   ((symbolp value) value)
   ((stringp value) (intern value))
   (t value)))

(defun ogent-tool-effects--default-risk (kind)
  "Return the default risk symbol for effect KIND."
  (pcase kind
    ('read 'low)
    ('issue 'medium)
    ('emacs-state 'medium)
    ('write 'high)
    ('network 'high)
    ('git 'high)
    ('execute 'critical)
    (_ 'medium)))

(defun ogent-tool-effects--risk-rank (risk)
  "Return numeric rank for RISK."
  (or (alist-get risk ogent-tool-effects--risk-ranks) 0))

(defun ogent-tool-effects--normalize-effect (effect)
  "Return normalized plist for EFFECT, or nil when malformed."
  (let* ((plist (cond
                 ((ogent-tool-effects--plist-p effect)
                  (copy-sequence effect))
                 ((symbolp effect)
                  (list :kind effect))
                 ((and (consp effect) (symbolp (car effect)))
                  (list :kind (nth 0 effect)
                        :target (nth 1 effect)
                        :scope (nth 2 effect)))
                 (t nil)))
         (kind (and plist
                    (ogent-tool-effects--normalize-symbol
                     (or (plist-get plist :kind)
                         (plist-get plist :type))))))
    (when (and kind (memq kind ogent-tool-effects-known-kinds))
      (setq plist (plist-put plist :kind kind))
      (setq plist (plist-put plist :risk
                             (ogent-tool-effects--normalize-symbol
                              (or (plist-get plist :risk)
                                  (ogent-tool-effects--default-risk kind)))))
      (unless (plist-member plist :target)
        (setq plist (plist-put plist :target 'unknown)))
      (unless (plist-member plist :scope)
        (setq plist (plist-put plist :scope 'unknown)))
      plist)))

(defun ogent-tool-effects-normalize (effects)
  "Return normalized effect plists for EFFECTS."
  (let ((items (cond
                ((null effects) nil)
                ((ogent-tool-effects--plist-p effects) (list effects))
                ((listp effects) effects)
                (t (list effects)))))
    (delq nil (mapcar #'ogent-tool-effects--normalize-effect items))))

(defun ogent-tool-effects-kinds (effects)
  "Return normalized effect kinds for EFFECTS."
  (mapcar (lambda (effect) (plist-get effect :kind))
          (ogent-tool-effects-normalize effects)))

(defun ogent-tool-effects-risk (effects)
  "Return the highest risk symbol in EFFECTS."
  (let ((max-risk 'none))
    (dolist (effect (ogent-tool-effects-normalize effects))
      (let ((risk (plist-get effect :risk)))
        (when (> (ogent-tool-effects--risk-rank risk)
                 (ogent-tool-effects--risk-rank max-risk))
          (setq max-risk risk))))
    max-risk))

(defun ogent-tool-effects-approval-required-p (effects)
  "Return non-nil when EFFECTS should require user approval."
  (or (cl-some (lambda (kind)
                 (memq kind ogent-tool-effects-approval-kinds))
               (ogent-tool-effects-kinds effects))
      (>= (ogent-tool-effects--risk-rank
           (ogent-tool-effects-risk effects))
          (ogent-tool-effects--risk-rank 'high))))

(defun ogent-tool-effects-format (effects)
  "Return human-readable lines describing EFFECTS."
  (let ((normalized (ogent-tool-effects-normalize effects)))
    (if (null normalized)
        "  (no declared effects)"
      (mapconcat
       (lambda (effect)
         (format "  %s %s [%s, %s]"
                 (plist-get effect :kind)
                 (plist-get effect :target)
                 (plist-get effect :scope)
                 (plist-get effect :risk)))
       normalized
       "\n"))))

(provide 'ogent-tool-effects)

;;; ogent-tool-effects.el ends here

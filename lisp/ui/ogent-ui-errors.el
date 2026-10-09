;;; ogent-ui-errors.el --- Readable request recovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Present complete error records and contextual recovery without changing
;; transport policy or reconstructing immutable request context.

;;; Code:

(require 'org)
(require 'ogent-ui-core)
(require 'ogent-ui-layout)
(require 'ogent-keys)

(defvar ogent-ui--error-history)
(defvar ogent-errors-buffer-name)

(declare-function ogent-ui--format-error-for-display "ogent-ui-engine")
(declare-function ogent-ui--update-error-buffer "ogent-ui-engine")
(declare-function ogent-retry-request "ogent-ui-engine")

(defvar ogent-errors-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-errors-visit-request)
    (define-key map (kbd "<return>") #'ogent-errors-visit-request)
    (define-key map "r" #'ogent-errors-retry-request)
    (define-key map "g" #'ogent-errors-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-errors-mode'.")

(define-derived-mode ogent-errors-mode org-mode "Ogent-Errors"
  "Read request failures and recover using their original context."
  (ogent-ui-layout-configure)
  (setq-local buffer-read-only t)
  (setq-local header-line-format
              '(:eval (ogent-ui-layout-header
                       "Errors" nil '(("RET" . "request") ("r" . "retry")
                                      ("q" . "back"))))))

(defun ogent-errors--id-at-point ()
  "Return the error record identity at point."
  (get-text-property (point) 'ogent-error-request-id))

(defun ogent-errors--request-at-point ()
  "Return the original request for the error at point."
  (let ((id (or (ogent-errors--id-at-point)
                (user-error "Move to an error record first"))))
    (or (gethash id ogent-ui--request-table)
        (seq-find (lambda (request) (equal (ogent-ui-request-id request) id))
                  ogent-ui--request-history)
        (user-error "Request expired from history; return to its transcript"))))

(defun ogent-errors-visit-request ()
  "Visit the original transcript for the error at point."
  (interactive)
  (let* ((request (ogent-errors--request-at-point))
         (buffer (ogent-ui-request-buffer request))
         (marker (ogent-ui-request-request-heading-pos request)))
    (unless (buffer-live-p buffer)
      (user-error "The request buffer was closed; reopen its transcript"))
    (pop-to-buffer buffer)
    (when (and (markerp marker) (eq (marker-buffer marker) buffer))
      (goto-char marker)
      (when (derived-mode-p 'org-mode) (org-fold-show-entry)))))

(defun ogent-errors-retry-request ()
  "Retry the selected error using the original immutable request context."
  (interactive)
  (let* ((request (ogent-errors--request-at-point))
         (buffer (ogent-ui-request-buffer request)))
    (unless (buffer-live-p buffer)
      (user-error "The request buffer was closed; reopen its transcript"))
    (ogent-retry-request (ogent-ui-request-id request))
    (pop-to-buffer buffer)))

(defun ogent-errors-refresh ()
  "Refresh the error reader without changing the selected record."
  (interactive)
  (ogent-ui--update-error-buffer))

(defun ogent-errors--position (position)
  "Return record identity and relative offset for POSITION."
  (let ((id (get-text-property position 'ogent-error-request-id)))
    (list id (if id
                 (- position (or (previous-single-property-change
                                  (min (1+ position) (point-max))
                                  'ogent-error-request-id)
                                 (point-min)))
               (1- position)))))

(defun ogent-errors--restore-position (location)
  "Return a live buffer position for saved LOCATION."
  (let* ((id (car location))
         (start (if id
                    (text-property-any (point-min) (point-max)
                                       'ogent-error-request-id id)
                  (point-min))))
    (if start
        (min (point-max) (+ start (cadr location)))
      (or (text-property-not-all (point-min) (point-max)
                                 'ogent-error-request-id nil)
          (point-min)))))

(defun ogent-errors-render ()
  "Render current error history and return its reader buffer."
  (let ((buffer (get-buffer-create ogent-errors-buffer-name)))
    (with-current-buffer buffer
      (let* ((location (ogent-errors--position (point)))
             (windows (mapcar (lambda (window)
                                (cons window (ogent-errors--position
                                              (window-start window))))
                              (get-buffer-window-list buffer nil t)))
             (inhibit-read-only t))
        (unless (derived-mode-p 'ogent-errors-mode) (ogent-errors-mode))
        (erase-buffer)
        (insert "#+title: ogent Errors\n\n* Error History\n\n")
        (if ogent-ui--error-history
            (dolist (record ogent-ui--error-history)
              (insert (propertize (ogent-ui--format-error-for-display record)
                                  'ogent-error-request-id
                                  (plist-get record :request-id))))
          (insert "No errors recorded.\n"))
        (goto-char (if (car location)
                       (ogent-errors--restore-position location)
                     (or (text-property-not-all (point-min) (point-max)
                                                'ogent-error-request-id nil)
                         (point-min))))
        (dolist (entry windows)
          (when (window-live-p (car entry))
            (set-window-start (car entry)
                              (ogent-errors--restore-position (cdr entry)) t)))))
    buffer))

(with-eval-after-load 'evil
  (ogent-evil-display-mode-setup 'ogent-errors-mode ogent-errors-mode-map
                                 'ogent-errors-mode-hook #'ogent-errors-refresh))

(provide 'ogent-ui-errors)
;;; ogent-ui-errors.el ends here

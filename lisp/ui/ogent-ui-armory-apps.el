;;; ogent-ui-armory-apps.el --- Armory app artifact list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated Armory app artifacts and artifact opening.

;;; Code:

(require 'ogent-ui-armory-core)

(defvar ogent-armory-apps-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-apps-open))
    (define-key map "v" #'ogent-armory-apps-visit-directory)
    (define-key map "g" #'ogent-armory-apps-refresh)
    (define-key map "?" #'ogent-armory-apps-dispatch)
    (define-key map "n" #'ogent-armory-ui-next-item)
    (define-key map "p" #'ogent-armory-ui-previous-item)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-apps-mode'.")

(ogent-armory-ui--define-prefix ogent-armory-apps-dispatch ()
  "Dispatch menu for the Armory app artifact list."
  [["Item"
    ("RET" "Open app" ogent-armory-apps-open)
    ("v" "Visit app directory" ogent-armory-apps-visit-directory)]
   ["View"
    ("g" "Refresh" ogent-armory-apps-refresh :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(define-derived-mode ogent-armory-apps-mode tabulated-list-mode "Armory-Apps"
  "Major mode for Armory app artifacts."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Label" 30 t)
               ("Owner" 18 t)
               ("Modified" 18 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Modified" . t))
  (setq-local revert-buffer-function #'ogent-armory-apps-refresh)
  (setq-local tabulated-list-use-header-line nil)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Apps"
                 (and ogent-armory-apps--root
                      (ogent-armory-ui--root-label ogent-armory-apps--root))
                 '("?" . "menu") '("j" . "jump") '("g" . "refresh"))))
  (tabulated-list-init-header))

(defun ogent-armory-apps--entry (app)
  "Return a tabulated entry for APP."
  (let ((owner (string-join
                (delq nil (list (plist-get app :agent)
                                (plist-get app :job-id)))
                "/")))
    (list
     app
     (vector
      (plist-get app :label)
      owner
      (or (plist-get app :modified) "")
      (plist-get app :path)))))

(defun ogent-armory-apps--entries ()
  "Return app entries for the current Armory apps buffer."
  (let ((apps (ogent-armory-list-apps ogent-armory-apps--root)))
    (if apps
        (mapcar #'ogent-armory-apps--entry apps)
      (list (list nil (vector "No app artifacts" "" "" ""))))))

(defun ogent-armory-apps (&optional directory)
  "Open the Armory app artifact list for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-apps-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-apps-mode)
      (setq ogent-armory-apps--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-apps--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-apps-refresh (&optional force &rest _)
  "Refresh the Armory apps buffer.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-apps--root)
  (tabulated-list-print t))

(defun ogent-armory-apps--item ()
  "Return the app item at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory app at point")))

(defun ogent-armory-apps-open ()
  "Open the app artifact at point in a browser."
  (interactive)
  (ogent-armory-open-file (plist-get (ogent-armory-apps--item) :path)))

(defun ogent-armory-apps-visit-directory ()
  "Visit the app directory at point."
  (interactive)
  (dired (plist-get (ogent-armory-apps--item) :directory)))

(defun ogent-armory-open-app (&optional directory)
  "Open an index.html app artifact under DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (apps (ogent-armory-list-apps root)))
    (unless apps
      (user-error "No Armory index.html apps under %s" root))
    (let* ((app
            (if (= (length apps) 1)
                (car apps)
              (let* ((labels (mapcar (lambda (item)
                                       (plist-get item :label))
                                     apps))
                     (choice (completing-read "App: " labels nil t)))
                (seq-find
                 (lambda (item)
                   (equal (plist-get item :label) choice))
                 apps))))
           (path (plist-get app :path)))
      (browse-url-of-file path)
      path)))

(defun ogent-armory-apps--evil-local-keys ()
  "Install local Evil keys for Armory apps buffers."
  (ogent-armory-evil-install-local-bindings ogent-armory-apps-mode-map))

(defun ogent-armory-apps--setup-evil ()
  "Set up Evil integration for Armory apps buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-apps-mode
   ogent-armory-apps-mode-map
   'ogent-armory-apps-mode-hook
   #'ogent-armory-apps--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-apps--setup-evil))

(provide 'ogent-ui-armory-apps)
;;; ogent-ui-armory-apps.el ends here

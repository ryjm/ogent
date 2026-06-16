;;; ogent-ui-cabinet-apps.el --- Cabinet app artifact list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated Cabinet app artifacts and artifact opening.

;;; Code:

(require 'ogent-ui-cabinet-core)

(defvar ogent-cabinet-apps-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-apps-open))
    (define-key map "v" #'ogent-cabinet-apps-visit-directory)
    (define-key map (kbd "C-c v") #'ogent-cabinet-apps-visit-directory)
    (define-key map "g" #'ogent-cabinet-apps-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-apps-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-apps-mode'.")

(define-derived-mode ogent-cabinet-apps-mode tabulated-list-mode "Cabinet-Apps"
  "Major mode for Cabinet app artifacts."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Label" 30 t)
               ("Owner" 18 t)
               ("Modified" 18 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Modified" . t))
  (setq-local revert-buffer-function #'ogent-cabinet-apps-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-apps--entry (app)
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

(defun ogent-cabinet-apps--entries ()
  "Return app entries for the current Cabinet apps buffer."
  (let ((apps (ogent-cabinet-list-apps ogent-cabinet-apps--root)))
    (if apps
        (mapcar #'ogent-cabinet-apps--entry apps)
      (list (list nil (vector "No app artifacts" "" "" ""))))))

(defun ogent-cabinet-apps (&optional directory)
  "Open the Cabinet app artifact list for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-apps-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-apps-mode)
      (setq ogent-cabinet-apps--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-apps--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-apps-refresh (&rest _)
  "Refresh the Cabinet apps buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-apps--item ()
  "Return the app item at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet app at point")))

(defun ogent-cabinet-apps-open ()
  "Open the app artifact at point in a browser."
  (interactive)
  (ogent-cabinet-open-file (plist-get (ogent-cabinet-apps--item) :path)))

(defun ogent-cabinet-apps-visit-directory ()
  "Visit the app directory at point."
  (interactive)
  (dired (plist-get (ogent-cabinet-apps--item) :directory)))

(defun ogent-cabinet-open-app (&optional directory)
  "Open an index.html app artifact under DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (apps (ogent-cabinet-list-apps root)))
    (unless apps
      (user-error "No Cabinet index.html apps under %s" root))
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

(provide 'ogent-ui-cabinet-apps)
;;; ogent-ui-cabinet-apps.el ends here

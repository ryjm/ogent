;;; ogent-ui-armory-search.el --- Armory record search results -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated Armory record search results.

;;; Code:

(require 'ogent-ui-armory-core)

(defvar ogent-armory-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-search-visit)
    (define-key map (kbd "<return>") #'ogent-armory-search-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-search-visit)
    (define-key map "f" #'ogent-armory-search-edit-query)
    (define-key map "g" #'ogent-armory-search-refresh)
    (define-key map "?" #'ogent-armory-search-dispatch)
    (define-key map "n" #'ogent-armory-ui-next-item)
    (define-key map "p" #'ogent-armory-ui-previous-item)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-search-mode'.")

(ogent-armory-ui--define-prefix ogent-armory-search-dispatch ()
  "Dispatch menu for Armory search results."
  [["Item"
    ("RET" "Visit result" ogent-armory-search-visit)]
   ["View"
    ("f" "Edit query" ogent-armory-search-edit-query :transient t)
    ("g" "Refresh" ogent-armory-search-refresh :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(define-derived-mode ogent-armory-search-mode tabulated-list-mode "Armory-Search"
  "Major mode for Armory search results."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Kind" 10 t)
               ("File" 30 t)
               ("Line" 6 nil :right-align t)
               ("Match" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-search-refresh)
  (setq-local tabulated-list-use-header-line nil)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Search"
                 (and ogent-armory-search--query
                      (format "\"%s\"" ogent-armory-search--query))
                 '("?" . "menu") '("j" . "jump")
                 '("g" . "refresh"))))
  (tabulated-list-init-header))

(defun ogent-armory-search-edit-query ()
  "Edit the current Armory search query and re-render the results."
  (interactive)
  (let ((query (completing-read
                "Search Armory: "
                nil nil nil
                (or ogent-armory-search--query ""))))
    (setq ogent-armory-search--query query)
    (ogent-armory-search-refresh)))

(defun ogent-armory-search--entries ()
  "Return tabulated entries for the current Armory search buffer."
  (if (string-blank-p (or ogent-armory-search--query ""))
      (list (list nil (vector "" "" "" "Enter a search query to search this Armory.")))
    (mapcar
     (lambda (result)
       (let ((path (plist-get result :path)))
         (list
          result
          (vector
           (symbol-name (plist-get result :kind))
           (file-relative-name path ogent-armory-search--root)
           (number-to-string (plist-get result :line))
           (plist-get result :text)))))
     (apply #'ogent-armory-search-records
            ogent-armory-search--root
            ogent-armory-search--query
            ogent-armory-search--filters))))

(defun ogent-armory-search (&optional directory query filters)
  "Search Armory Org records under DIRECTORY for QUERY and FILTERS."
  (interactive
   (let ((root (ogent-armory-ui--root
                (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))))
     (list root (read-string "Search Armory: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (search-query (or query (read-string "Search Armory: ")))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-search-buffer-name-format
                   root
                   search-query))))
    (with-current-buffer buffer
      (ogent-armory-search-mode)
      (setq ogent-armory-search--root root)
      (setq ogent-armory-search--query search-query)
      (setq ogent-armory-search--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-search--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-search-refresh (&optional force &rest _)
  "Refresh the current Armory search results.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-search--root)
  (tabulated-list-print t))

(defun ogent-armory-search-visit ()
  "Visit the Armory search result at point."
  (interactive)
  (let ((result (tabulated-list-get-id)))
    (unless result
      (user-error "No Armory search result at point"))
    (ogent-armory-ui--file-line
     (plist-get result :path)
     (plist-get result :line))))

(defun ogent-armory-search--evil-local-keys ()
  "Install local Evil keys for Armory search buffers."
  (ogent-armory-evil-install-local-bindings ogent-armory-search-mode-map))

(defun ogent-armory-search--setup-evil ()
  "Set up Evil integration for Armory search buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-search-mode
   ogent-armory-search-mode-map
   'ogent-armory-search-mode-hook
   #'ogent-armory-search--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-search--setup-evil))

(provide 'ogent-ui-armory-search)
;;; ogent-ui-armory-search.el ends here

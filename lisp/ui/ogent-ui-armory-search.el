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
    (define-key map "g" #'ogent-armory-search-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-search-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-search-mode'.")

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
  (tabulated-list-init-header))

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

(defun ogent-armory-search-refresh (&rest _)
  "Refresh the current Armory search results."
  (interactive)
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

(provide 'ogent-ui-armory-search)
;;; ogent-ui-armory-search.el ends here

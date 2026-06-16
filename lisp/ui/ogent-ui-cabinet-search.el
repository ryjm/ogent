;;; ogent-ui-cabinet-search.el --- Cabinet record search results -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated Cabinet record search results.

;;; Code:

(require 'ogent-ui-cabinet-core)

(defvar ogent-cabinet-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-search-visit)
    (define-key map "g" #'ogent-cabinet-search-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-search-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-search-mode'.")

(define-derived-mode ogent-cabinet-search-mode tabulated-list-mode "Cabinet-Search"
  "Major mode for Cabinet search results."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Kind" 10 t)
               ("File" 30 t)
               ("Line" 6 nil :right-align t)
               ("Match" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-search-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-search--entries ()
  "Return tabulated entries for the current Cabinet search buffer."
  (if (string-blank-p (or ogent-cabinet-search--query ""))
      (list (list nil (vector "" "" "" "Enter a search query to search this Cabinet.")))
    (mapcar
     (lambda (result)
       (let ((path (plist-get result :path)))
         (list
          result
          (vector
           (symbol-name (plist-get result :kind))
           (file-relative-name path ogent-cabinet-search--root)
           (number-to-string (plist-get result :line))
           (plist-get result :text)))))
     (apply #'ogent-cabinet-search-records
            ogent-cabinet-search--root
            ogent-cabinet-search--query
            ogent-cabinet-search--filters))))

(defun ogent-cabinet-search (&optional directory query filters)
  "Search Cabinet Org records under DIRECTORY for QUERY and FILTERS."
  (interactive
   (let ((root (ogent-cabinet-ui--root
                (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))))
     (list root (read-string "Search Cabinet: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (search-query (or query (read-string "Search Cabinet: ")))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-search-buffer-name-format
                   root
                   search-query))))
    (with-current-buffer buffer
      (ogent-cabinet-search-mode)
      (setq ogent-cabinet-search--root root)
      (setq ogent-cabinet-search--query search-query)
      (setq ogent-cabinet-search--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-search--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-search-refresh (&rest _)
  "Refresh the current Cabinet search results."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-search-visit ()
  "Visit the Cabinet search result at point."
  (interactive)
  (let ((result (tabulated-list-get-id)))
    (unless result
      (user-error "No Cabinet search result at point"))
    (ogent-cabinet-ui--file-line
     (plist-get result :path)
     (plist-get result :line))))

(provide 'ogent-ui-cabinet-search)
;;; ogent-ui-cabinet-search.el ends here

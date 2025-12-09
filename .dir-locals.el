;;; Directory Local Variables for ogent development
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((fill-column . 80)
         (indent-tabs-mode . nil)))
 (emacs-lisp-mode . ((indent-tabs-mode . nil)
                     (sentence-end-double-space . t)
                     (checkdoc-spellcheck-documentation-flag . nil)
                     (eval . (progn
                               ;; Add source directories to load-path
                               (let ((root (locate-dominating-file
                                            default-directory ".dir-locals.el")))
                                 (when root
                                   (add-to-list 'load-path
                                                (expand-file-name "lisp" root))
                                   (add-to-list 'load-path
                                                (expand-file-name "lisp/ui" root))
                                   (add-to-list 'load-path
                                                (expand-file-name "test" root))))))))
 (org-mode . ((org-src-preserve-indentation . t))))

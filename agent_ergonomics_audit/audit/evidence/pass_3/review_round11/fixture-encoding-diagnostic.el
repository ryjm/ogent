;;; fixture-encoding-diagnostic.el --- Inspect filename round trips -*- lexical-binding: t; -*-
(let* ((root (make-temp-file "round11-encoding-" t))
       (unibyte-file (concat root "/" (unibyte-string 255) ".txt"))
       (decoded-file (concat root "/" (decode-coding-string (unibyte-string 255) 'utf-8-unix) ".txt")))
  (princ (format "root=%S\n" root))
  (with-temp-file unibyte-file (insert "created using unibyte name"))
  (princ (format "unibyte=%S decoded=%S\n" (string-to-list unibyte-file) (string-to-list decoded-file)))
  (dolist (coder '(nil utf-8-unix raw-text-unix no-conversion))
    (let ((file-name-coding-system coder))
      (princ (format "coder=%S unibyte-exists=%S decoded-exists=%S unibyte-regular=%S decoded-regular=%S decoded-encoded=%S\n"
                     coder (file-exists-p unibyte-file) (file-exists-p decoded-file)
                     (file-regular-p unibyte-file) (file-regular-p decoded-file)
                     (string-to-list (encode-coding-string decoded-file
                                                          (or coder default-file-name-coding-system)))))))
  (with-temp-file decoded-file (insert "created using decoded name"))
  (princ (format "after decoded creation unibyte=%S decoded=%S names=%S\n"
                 (file-exists-p unibyte-file) (file-exists-p decoded-file)
                 (mapcar (lambda (file) (list (string-to-list file) (file-regular-p file)))
                         (directory-files root t "txt$")))))

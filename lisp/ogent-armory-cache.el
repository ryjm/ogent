;;; ogent-armory-cache.el --- Stamp-based cache for Armory data fetches -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Cheap render caching for Armory buffers.  Every cached value is
;; keyed by (ROOT . KIND) and guarded by a filesystem stamp: the
;; sorted list of (relative-path . mtime) pairs for every `.org' file
;; plus every `apps/*/index.html' under ROOT.  A cache hit requires an
;; `equal' stamp, so content edits (mtime), additions, and removals
;; (path list) all invalidate naturally - including writes performed
;; by subprocess agents outside Emacs.
;;
;; `ogent-armory-cache-invalidate' exists as an optimization for
;; in-Emacs mutations; correctness never depends on explicit
;; invalidation.  `C-u g' in Armory buffers passes FORCE through to
;; `ogent-armory-cache-get' as the documented escape hatch (e.g. for
;; filesystems with coarse mtime granularity).

;;; Code:
(require 'subr-x)


(defvar ogent-armory-cache--table (make-hash-table :test 'equal)
  "Cache table mapping (ROOT . KIND) to (STAMP . VALUE).")

(defun ogent-armory-cache-stamp (root)
  "Return a freshness stamp for the Armory under ROOT.
The stamp is a sorted list of (RELATIVE-PATH . MTIME) conses covering
every `.org' file and every `apps/*/index.html' under ROOT, skipping
`.git'.  Return nil when ROOT is missing or unreadable; callers must
bypass the cache then."
  (when (and (stringp root) (file-directory-p root))
    (condition-case nil
        (let* ((root (file-name-as-directory root))
               (files (directory-files-recursively
                       root
                       "\\(?:\\.org\\|index\\.html\\)\\'"
                       nil
                       (lambda (dir)
                         (not (string= (file-name-nondirectory dir) ".git")))))
               stamp)
          (dolist (file files)
            (let ((relative (file-relative-name file root)))
              (when (or (string-suffix-p ".org" relative)
                        (string-match-p "\\`apps/[^/]+/index\\.html\\'"
                                        relative))
                (push (cons relative
                            (file-attribute-modification-time
                             (file-attributes file)))
                      stamp))))
          (sort stamp (lambda (a b) (string< (car a) (car b)))))
      (file-error nil))))

(defun ogent-armory-cache-get (root kind builder &optional force)
  "Return the cached KIND value for ROOT, rebuilding via BUILDER when stale.
BUILDER is a zero-argument function producing the value.  The entry is
fresh when its stored stamp `equal's the current
`ogent-armory-cache-stamp'.  With FORCE non-nil, always rebuild.  When
ROOT yields no stamp (missing or unreadable), bypass the cache
entirely and call BUILDER."
  (let ((stamp (ogent-armory-cache-stamp root)))
    (if (null stamp)
        (funcall builder)
      (let* ((key (cons root kind))
             (entry (gethash key ogent-armory-cache--table)))
        (if (and entry (not force) (equal (car entry) stamp))
            (cdr entry)
          (let ((value (funcall builder)))
            (puthash key (cons stamp value) ogent-armory-cache--table)
            value))))))

(defun ogent-armory-cache-invalidate (&optional root)
  "Drop cache entries for ROOT, or every entry when ROOT is nil."
  (if (null root)
      (clrhash ogent-armory-cache--table)
    (let (stale)
      (maphash (lambda (key _value)
                 (when (equal (car key) root)
                   (push key stale)))
               ogent-armory-cache--table)
      (dolist (key stale)
        (remhash key ogent-armory-cache--table)))))

(provide 'ogent-armory-cache)
;;; ogent-armory-cache.el ends here

;;; ogent-zen-workspace.el --- Workspace inference for Zen runs -*- lexical-binding: t; -*-

;;; Commentary:
;; Repository-root inference, workspace briefs, and context transforms
;; that bridge Zen scopes to `ogent-context'.

;;; Code:

(require 'ogent-zen-core)
(require 'ogent-context)

(defun ogent-zen--workspace-base-directory ()
  "Return the directory used to resolve relative Zen workspace paths."
  (or (and buffer-file-name (file-name-directory buffer-file-name))
      default-directory))

(defun ogent-zen--project-root ()
  "Return the project root for the current Zen buffer, or nil."
  (let ((base (ogent-zen--workspace-base-directory)))
    (or (and (fboundp 'project-current)
             (let ((default-directory base))
               (when-let ((project (project-current nil)))
                 (project-root project))))
        (when-let ((root (locate-dominating-file base ".git")))
          (file-name-as-directory root)))))

(defun ogent-zen--workspace-resolution-bases ()
  "Return directories used for resolving relative workspace mentions."
  (cl-remove-duplicates
   (delq nil
         (mapcar (lambda (dir)
                   (and dir
                        (file-name-as-directory (expand-file-name dir))))
                 (list (ogent-zen--workspace-base-directory)
                       (ogent-zen--project-root)
                       default-directory)))
   :test #'string=))

(defun ogent-zen--workspace-node-text (node)
  "Return searchable title and body text for NODE."
  (when node
    (string-join
     (delq nil
           (list (ogent-context-node-title node)
                 (ogent-context-node-content node)))
     "\n")))

(defun ogent-zen--workspace-search-texts (context)
  "Return nearest-first text fragments for workspace inference from CONTEXT."
  (let ((root (plist-get context :root))
        (ancestors (plist-get context :ancestors)))
    (delq nil
          (append
           (when root (list (ogent-zen--workspace-node-text root)))
           (mapcar #'ogent-zen--workspace-node-text
                   (reverse ancestors))))))

(defun ogent-zen--workspace-directive-from-text (content)
  "Return the first explicit workspace path declared in CONTENT, or nil.
Recognizes lines like \"Context: ~/repo\" using
`ogent-zen-workspace-directives'.  Only the first shell-like token after
the colon is treated as the path, so users can append prose safely."
  (catch 'path
    (dolist (line (split-string (or content "") "\n"))
      (dolist (label ogent-zen-workspace-directives)
        (when (string-match
               (format "\\`[ \t]*%s:[ \t]*\\([^ \t\n]+\\)"
                       (regexp-quote label))
               line)
          (throw 'path (match-string 1 line)))))))

(defconst ogent-zen--workspace-path-regexp
  "\\(?:[\"'`“‘]\\(\\(?:~\\|/\\|\\.\\.?/\\)[^\"'`“”‘’\n]+\\)[\"'`”’]\\|\\(\\(?:~\\|/\\|\\.\\.?/\\)[^ \t\n\"'`“”‘’()<>;,]+\\)\\)"
  "Regexp matching quoted or bare path-like prose.")

(defconst ogent-zen--workspace-tool-intent-regexp
  "\\b\\(?:look\\|inspect\\|read\\|search\\|grep\\|scan\\|find\\|explore\\|investigate\\|ground\\|grounded\\|code\\|codebase\\|repo\\|repository\\|implementation\\|source\\|file\\|files\\|tool\\)\\b"
  "Regexp matching prose that should actively inspect a workspace.")

(defun ogent-zen--clean-workspace-token (token)
  "Return cleaned path TOKEN, or nil when TOKEN is not a usable path."
  (when token
    (let* ((without-file-scheme
            (replace-regexp-in-string "\\`file://" "" token))
           (trimmed
            (string-trim without-file-scheme
                         "[ \t\n\r\"'`“”‘’([{<]+"
                         "[ \t\n\r\"'`“”‘’.,;:!?)}>\\]]+")))
      (unless (or (string-empty-p trimmed)
                  (string-prefix-p "//" trimmed))
        trimmed))))

(defun ogent-zen--workspace-paths-from-text (content)
  "Return path-like natural language mentions in CONTENT."
  (let (paths)
    (when (and ogent-zen-infer-workspace-from-prose content)
      (let ((pos 0))
        (while (string-match ogent-zen--workspace-path-regexp content pos)
          (when-let ((path (ogent-zen--clean-workspace-token
                            (or (match-string 1 content)
                                (match-string 2 content)))))
            (push path paths))
          (setq pos (max (1+ pos) (match-end 0))))))
    (cl-remove-duplicates (nreverse paths) :test #'string= :from-end t)))

(defun ogent-zen--resolve-workspace-path (raw-path)
  "Return workspace info for RAW-PATH, or nil when it is unusable.
The returned plist contains :root, :target, and :raw.  Files resolve to
their containing directory as :root while preserving the file as :target."
  (when (and raw-path (not (string-empty-p raw-path)))
    (catch 'resolved
      (let ((bases (if (or (file-name-absolute-p raw-path)
                           (string-prefix-p "~" raw-path))
                       '(nil)
                     (ogent-zen--workspace-resolution-bases))))
        (dolist (base bases)
          (let* ((expanded (expand-file-name raw-path base))
                 (directory (and (file-directory-p expanded)
                                 (file-name-as-directory expanded)))
                 (file (and (file-regular-p expanded) expanded)))
            (cond
             (directory
              (throw 'resolved
                     (list :root (file-truename directory)
                           :target (file-truename directory)
                           :raw raw-path)))
             (file
              (throw 'resolved
                     (list :root (file-truename
                                  (file-name-directory file))
                           :target (file-truename file)
                           :raw raw-path))))))))))

(defun ogent-zen--workspace-tool-intent-p (texts)
  "Return non-nil when TEXTS ask for workspace inspection."
  (cl-some
   (lambda (text)
     (and text
          (string-match-p ogent-zen--workspace-tool-intent-regexp
                          (downcase text))))
   texts))

(defun ogent-zen--workspace-info (context)
  "Return inferred workspace info for CONTEXT, nearest scope first."
  (let* ((texts (ogent-zen--workspace-search-texts context))
         (explicit
          (cl-loop for text in texts
                   for raw = (ogent-zen--workspace-directive-from-text text)
                   for resolved = (ogent-zen--resolve-workspace-path raw)
                   when resolved
                   return (plist-put resolved :source 'directive)))
         (natural
          (and ogent-zen-infer-workspace-from-prose
               (cl-loop for text in texts
                        append (ogent-zen--workspace-paths-from-text text)
                        into paths
                        finally return
                        (cl-loop for raw in paths
                                 for resolved = (ogent-zen--resolve-workspace-path raw)
                                 when resolved
                                 return (plist-put resolved :source 'natural)))))
         (implicit
          (and ogent-zen-infer-workspace-from-prose
               (ogent-zen--workspace-tool-intent-p texts)
               (when-let ((root (ogent-zen--project-root)))
                 (list :root (file-truename (file-name-as-directory root))
                       :target (file-truename (file-name-as-directory root))
                       :raw "current project"
                       :source 'project))))
         (info (or explicit natural implicit)))
    (when info
      (plist-put info :tool-intent
                 (and ogent-zen-force-tools-for-workspace-intent
                      (if (or (memq (plist-get info :source)
                                    '(natural project))
                              (ogent-zen--workspace-tool-intent-p texts))
                          t
                        nil)))
      info)))

(defun ogent-zen--workspace-root (context)
  "Return workspace root inferred from CONTEXT, nearest scope first."
  (plist-get (ogent-zen--workspace-info context) :root))

(defun ogent-zen--workspace-brief-files (workspace-root)
  "Return recent source/doc files under WORKSPACE-ROOT for a compact brief."
  (let (files)
    (dolist (dir ogent-zen-workspace-brief-directories)
      (let ((absolute (expand-file-name dir workspace-root)))
        (when (file-directory-p absolute)
          (dolist (file (directory-files-recursively
                         absolute "\\.\\(el\\|org\\|md\\)\\'"))
            (when (file-regular-p file)
              (push file files))))))
    (setq files
          (sort files
                (lambda (a b)
                  (time-less-p
                   (file-attribute-modification-time (file-attributes b))
                   (file-attribute-modification-time (file-attributes a))))))
    (when (> (length files) ogent-zen-workspace-brief-max-files)
      (setq files (cl-subseq files 0 ogent-zen-workspace-brief-max-files)))
    files))

(defun ogent-zen--workspace-brief (workspace-root)
  "Return a compact workspace brief for WORKSPACE-ROOT."
  (let* ((dirs (cl-remove-if-not
                (lambda (dir)
                  (file-directory-p (expand-file-name dir workspace-root)))
                ogent-zen-workspace-brief-directories))
         (files (ogent-zen--workspace-brief-files workspace-root)))
    (string-join
     (delq nil
           (list
            (when dirs
              (format "Source areas: %s" (string-join dirs ", ")))
            (when files
              (format "Recent files:\n%s"
                      (mapconcat
                       (lambda (file)
                         (format "- %s"
                                 (file-relative-name file workspace-root)))
                       files
                       "\n")))))
     "\n")))

(defun ogent-zen--context-transform (context point)
  "Return CONTEXT adjusted for a Zen run rooted at POINT.
Marks the context as a Zen run, records the bullet breadcrumb, resolves
any workspace directive, empties the root content (the bullet text
already is the prompt), and trims each ancestor to its own body so
parents never duplicate the prompt, each other, or earlier transcripts."
  (let* ((next (copy-sequence context))
         (workspace-info (ogent-zen--workspace-info context))
         (workspace-root (plist-get workspace-info :root)))
    (setq next (plist-put next :zen-run t))
    (setq next (plist-put next :zen-path (ogent-zen--breadcrumb point)))
    (when workspace-root
      (setq next (plist-put next :workspace-root workspace-root))
      (setq next (plist-put next :workspace-source
                            (plist-get workspace-info :source)))
      (setq next (plist-put next :workspace-target
                            (plist-get workspace-info :target)))
      (setq next (plist-put next :workspace-tool-intent
                            (plist-get workspace-info :tool-intent)))
      (setq next (plist-put next :workspace-brief
                            (ogent-zen--workspace-brief workspace-root))))
    (when-let* ((root (plist-get context :root))
                (root-copy (copy-ogent-context-node root)))
      (setf (ogent-context-node-content root-copy) "")
      (setq next (plist-put next :root root-copy)))
    (when-let* ((ancestors (plist-get context :ancestors)))
      (setq next
            (plist-put next :ancestors
                       (mapcar (lambda (node)
                                 (let ((copy (copy-ogent-context-node node)))
                                   (setf (ogent-context-node-content copy)
                                         (ogent-zen--own-body
                                          (or (ogent-context-node-content node)
                                              "")))
                                   copy))
                               ancestors))))
    next))

(defun ogent-zen--selection-plist (scope)
  "Return persisted selection metadata for SCOPE."
  (when-let ((text (ogent-zen-scope-original-text scope)))
    (list :text text
          :begin (ogent-zen--marker-position
                  (ogent-zen-scope-start-marker scope))
          :end (ogent-zen--marker-position
                (ogent-zen-scope-end-marker scope))
          :length (length text)
          :sha256 (secure-hash 'sha256 text))))

(defun ogent-zen--context-transform-for-scope (context scope)
  "Return CONTEXT adjusted for a Zen SCOPE."
  (let* ((heading (ogent-zen-scope-heading-point scope))
         (next (ogent-zen--context-transform context heading))
         (kind (ogent-zen-scope-kind scope))
         (selection (ogent-zen--selection-plist scope)))
    (unless (eq kind 'subtree)
      (when-let* ((root (plist-get context :root))
                  (root-copy (copy-ogent-context-node root)))
        (setf (ogent-context-node-content root-copy)
              (ogent-zen--own-body
               (or (ogent-context-node-content root) "")))
        (setq next (plist-put next :root root-copy))))
    (setq next (plist-put next :zen-scope-kind kind))
    (setq next (plist-put next :zen-scope-instruction
                          (ogent-zen-scope-instruction scope)))
    (setq next (plist-put next :zen-edit
                          (ogent-zen-scope-edit-p scope)))
    (setq next (plist-put next :zen-selection selection))
    (setq next (plist-put next :zen-scope scope))
    next))

(provide 'ogent-zen-workspace)
;;; ogent-zen-workspace.el ends here

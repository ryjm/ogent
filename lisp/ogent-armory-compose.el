;;; ogent-armory-compose.el --- Shared Armory composer -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared prompt composer for Armory runs with mentions, attachments, skills,
;; and runtime selection.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-armory)
(require 'ogent-armory-adapter)
(require 'ogent-armory-evil)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)
(require 'ogent-armory-skills)

(defgroup ogent-armory-compose nil
  "Shared composer for Org Armory runs."
  :group 'ogent-armory
  :prefix "ogent-armory-compose-")

(defvar ogent-armory-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-armory-compose-submit-buffer)
    (define-key map (kbd "C-c C-a") #'ogent-armory-compose-add-attachment)
    (define-key map (kbd "C-c C-k") #'kill-buffer)
    map)
  "Keymap for `ogent-armory-compose-mode'.")

(defvar-local ogent-armory-compose--root nil
  "Armory root for the current composer buffer.")

(defvar-local ogent-armory-compose--agent nil
  "Agent slug for the current composer buffer.")

(defvar-local ogent-armory-compose--attachments nil
  "Attachment files selected in the current composer buffer.")

(define-derived-mode ogent-armory-compose-mode org-mode "Armory-Compose"
  "Major mode for Armory composer buffers."
  (add-hook 'completion-at-point-functions
            #'ogent-armory-compose-completion-at-point
            nil t)
  (setq-local header-line-format
              "C-c C-c submit  C-c C-a attach  C-c C-k cancel"))

(defun ogent-armory-compose--mention-regexp ()
  "Return mention regexp."
  "@\\(agent\\|page\\|skill\\|job\\|conversation\\):\\([^[:space:]\n\r,;]+\\)")

(defun ogent-armory-compose--page-record (root token)
  "Return a page mention record for TOKEN under ROOT."
  (let ((path (if (file-name-absolute-p token)
                  token
                (expand-file-name token root))))
    (when (file-readable-p path)
      (list :type 'page
            :key token
            :path path
            :title (file-name-base path)
            :body (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string))))))

(defun ogent-armory-compose--agent-record (root token)
  "Return an agent mention record for TOKEN under ROOT."
  (condition-case nil
      (let ((agent (ogent-armory-resolve-agent
                    root token :include-visible t)))
        (list :type 'agent
              :key token
              :path (plist-get agent :path)
              :title (or (plist-get agent :display-name)
                         (plist-get agent :name))
              :scope (plist-get agent :scope)
              :body (plist-get agent :body)))
    (user-error nil)))

(defun ogent-armory-compose--job-record (root token)
  "Return a job mention record for TOKEN under ROOT."
  (catch 'job
    (dolist (agent (ogent-armory-list-agents root))
      (when-let ((job (seq-find
                       (lambda (candidate)
                         (equal (plist-get candidate :id) token))
                       (ogent-armory-list-jobs root agent))))
        (throw 'job
               (list :type 'job
                     :key token
                     :path (ogent-armory-job-file root agent token)
                     :title (plist-get job :name)
                     :agent agent
                     :body (plist-get job :body)))))))

(defun ogent-armory-compose--conversation-record (root token)
  "Return a conversation mention record for TOKEN under ROOT."
  (when (file-readable-p (ogent-armory-conversation-file root token))
    (let ((detail (ogent-armory-conversation-detail root token)))
      (list :type 'conversation
            :key token
            :path (ogent-armory-conversation-file root token)
            :title (plist-get detail :title)
            :body (or (plist-get detail :context-summary)
                      (string-join
                       (mapcar (lambda (turn)
                                 (plist-get turn :content))
                               (plist-get detail :turns))
                       "\n\n"))))))

(defun ogent-armory-compose--skill-record (root token)
  "Return a skill mention record for TOKEN under ROOT."
  (condition-case nil
      (let ((skill (ogent-armory-skill-read root token)))
        (list :type 'skill
              :key (plist-get skill :key)
              :path (plist-get skill :path)
              :title (plist-get skill :title)
              :origin (plist-get skill :origin)
              :body (plist-get skill :body)))
    (user-error nil)))

(defun ogent-armory-compose--resolve-kind (root kind token)
  "Resolve mention KIND and TOKEN under ROOT."
  (pcase kind
    ("agent" (ogent-armory-compose--agent-record root token))
    ("page" (ogent-armory-compose--page-record root token))
    ("skill" (ogent-armory-compose--skill-record root token))
    ("job" (ogent-armory-compose--job-record root token))
    ("conversation" (ogent-armory-compose--conversation-record root token))
    (_ nil)))

(defun ogent-armory-compose-resolve-mention (root mention)
  "Resolve MENTION under ROOT."
  (unless (string-match "\\`@?\\([^:]+\\):\\(.+\\)\\'" mention)
    (user-error "Malformed Armory mention: %s" mention))
  (let ((kind (match-string 1 mention))
        (token (match-string 2 mention)))
    (or (ogent-armory-compose--resolve-kind root kind token)
        (let ((trimmed (string-trim-right token "[.?!)]+")))
          (unless (equal trimmed token)
            (ogent-armory-compose--resolve-kind root kind trimmed)))
        (user-error "Armory mention not found: %s" mention))))

(defun ogent-armory-compose-mentions (root text)
  "Return mention records in TEXT under ROOT."
  (let (mentions)
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (while (re-search-forward (ogent-armory-compose--mention-regexp) nil t)
        (push (ogent-armory-compose-resolve-mention
               root
               (match-string 0))
              mentions)))
    (nreverse mentions)))

(defun ogent-armory-compose-mention-candidates (root)
  "Return completion candidates for mentions under ROOT."
  (append
   (mapcar (lambda (agent)
             (concat "@agent:" agent))
           (ogent-armory-list-visible-agents
            root :include-visible t))
   (apply
    #'append
    (mapcar
     (lambda (agent)
       (mapcar (lambda (job)
                 (concat "@job:" (plist-get job :id)))
               (ogent-armory-list-jobs root agent)))
     (ogent-armory-list-agents root)))
   (mapcar (lambda (conversation)
             (concat "@conversation:" (plist-get conversation :id)))
           (ogent-armory-conversation-list root))
   (mapcar (lambda (skill)
             (concat "@skill:" (plist-get skill :key)))
           (ogent-armory-skill-list root))
   (mapcar (lambda (file)
             (concat "@page:" (file-relative-name file root)))
           (ogent-armory-org-files root))))

(defun ogent-armory-compose-completion-at-point ()
  "Return Armory mention completion at point."
  (when-let ((root (or ogent-armory-compose--root
                       (ogent-armory-find-root))))
    (let ((end (point))
          (start (save-excursion
                   (skip-chars-backward "^ \t\n\r")
                   (point))))
      (when (and (< start end)
                 (save-excursion
                   (goto-char start)
                   (looking-at "@")))
        (list start
              end
              (ogent-armory-compose-mention-candidates root))))))

(defun ogent-armory-compose--mention-paths (mentions)
  "Return durable paths from MENTIONS."
  (delq nil
        (mapcar (lambda (mention)
                  (plist-get mention :path))
                mentions)))

(defun ogent-armory-compose-build-prompt (root input)
  "Return provider prompt text for composer INPUT under ROOT."
  (let* ((instruction (or (plist-get input :instruction) ""))
         (mentions (or (plist-get input :mentions)
                       (ogent-armory-compose-mentions root instruction)))
         (skills (or (plist-get input :skills)
                     (delq nil
                           (mapcar (lambda (mention)
                                     (when (eq (plist-get mention :type) 'skill)
                                       (plist-get mention :key)))
                                   mentions))))
         (attachments (plist-get input :attachment-paths)))
    (string-join
     (delq
      nil
      (list
       instruction
       (when mentions
         (concat
          "Resolved mentions:\n"
          (string-join
           (mapcar
            (lambda (mention)
              (format "[%s:%s] %s\nPath: %s\n%s"
                      (symbol-name (plist-get mention :type))
                      (plist-get mention :key)
                      (or (plist-get mention :title) "")
                      (or (plist-get mention :path) "")
                      (string-trim
                       (truncate-string-to-width
                        (or (plist-get mention :body) "")
                        2000 nil nil t))))
            mentions)
           "\n\n")))
       (when attachments
         (concat
          "Attachments:\n"
          (string-join
           (mapcar (lambda (path)
                     (format "- %s" path))
                   attachments)
           "\n")))
       (when skills
         (concat
          "Skill instructions with provenance:\n"
          (ogent-armory-skill-bundle root skills)))))
     "\n\n")))

(defun ogent-armory-compose--read-list (prompt)
  "Read comma-separated values with PROMPT."
  (let ((value (read-string prompt)))
    (unless (string-blank-p value)
      (split-string value "[ \t]*,[ \t]*" t))))

;;;###autoload
(cl-defun ogent-armory-compose
    (directory agent-slug instruction
               &key mentions attachments skills runtime)
  "Run AGENT-SLUG from DIRECTORY with composer INSTRUCTION."
  (interactive
   (let* ((root (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))
          (agent (completing-read "Agent: "
                                  (ogent-armory-list-agents root)
                                  nil t))
          (instruction (read-string "Prompt: ")))
     (list root agent instruction
           :mentions (ogent-armory-compose--read-list "Extra mentions: ")
           :attachments (ogent-armory-compose--read-list "Attachments: ")
           :skills (ogent-armory-compose--read-list "Skills: "))))
  (let* ((root (ogent-armory--directory directory))
         (mention-records
          (append (ogent-armory-compose-mentions root instruction)
                  (mapcar (lambda (mention)
                            (ogent-armory-compose-resolve-mention root mention))
                          mentions)))
         (staged (when attachments
                   (ogent-armory-conversation-stage-attachments
                    root attachments)))
         (prompt (ogent-armory-compose-build-prompt
                  root
                  (list :instruction instruction
                        :mentions mention-records
                        :attachment-paths (plist-get staged :attachment-paths)
                        :skills skills)))
         (runtime (or runtime (ogent-armory-runtime-picker "Runtime: ")))
         (plan (ogent-armory-runner-plan
                root agent-slug
                :instruction prompt
                :turn-content instruction
                :runtime-mode (plist-get runtime :runtime-mode)
                :mentions (ogent-armory-compose--mention-paths mention-records)
                :skills skills
                :pending-attachment-id (plist-get staged :pending-id))))
    (when (ogent-armory-runner--confirm plan)
      (ogent-armory-runner-start plan))))

;;;###autoload
(defun ogent-armory-compose-buffer (&optional directory agent-slug)
  "Open a Armory composer buffer for DIRECTORY and AGENT-SLUG."
  (interactive)
  (let* ((root (ogent-armory--directory
                (or directory
                    (ogent-armory-find-root)
                    (read-directory-name "Armory root: "))))
         (agent (or agent-slug
                    (completing-read "Agent: "
                                     (ogent-armory-list-agents root)
                                     nil t)))
         (buffer (generate-new-buffer
                  (format "*ogent-armory-compose:%s*" agent))))
    (with-current-buffer buffer
      (ogent-armory-compose-mode)
      (setq ogent-armory-compose--root root)
      (setq ogent-armory-compose--agent agent)
      (insert "# Prompt\n\n")
      (goto-char (point-max)))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-compose-add-attachment (file)
  "Add FILE as an attachment in the current composer buffer."
  (interactive "fAttachment: ")
  (push file ogent-armory-compose--attachments)
  (save-excursion
    (goto-char (point-max))
    (insert (propertize
             (format "\n[attachment:%s]" (file-name-nondirectory file))
             'read-only t
             'ogent-armory-attachment file
             'help-echo file)
            "\n")))

(defun ogent-armory-compose-submit-buffer ()
  "Submit the current composer buffer."
  (interactive)
  (unless (and ogent-armory-compose--root ogent-armory-compose--agent)
    (user-error "Not in a Armory composer buffer"))
  (let ((instruction (string-trim
                      (buffer-substring-no-properties
                       (point-min)
                       (point-max)))))
    (ogent-armory-compose
     ogent-armory-compose--root
     ogent-armory-compose--agent
     instruction
     :attachments (nreverse ogent-armory-compose--attachments))))

(defun ogent-armory-compose--evil-local-keys ()
  "Install local Evil keys for Armory compose."
  (ogent-armory-evil-install-local-bindings ogent-armory-compose-mode-map))

(defun ogent-armory-compose--setup-evil ()
  "Set up Evil integration for Armory compose."
  (ogent-armory-evil-setup-mode
   'ogent-armory-compose-mode
   ogent-armory-compose-mode-map
   'ogent-armory-compose-mode-hook
   #'ogent-armory-compose--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-compose--setup-evil))

(provide 'ogent-armory-compose)

;;; ogent-armory-compose.el ends here

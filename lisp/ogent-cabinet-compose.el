;;; ogent-cabinet-compose.el --- Shared Cabinet composer -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared prompt composer for Cabinet runs with mentions, attachments, skills,
;; and runtime selection.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-cabinet)
(require 'ogent-cabinet-adapter)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-runner)
(require 'ogent-cabinet-skills)

(defgroup ogent-cabinet-compose nil
  "Shared composer for Org Cabinet runs."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-compose-")

(defvar ogent-cabinet-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-cabinet-compose-submit-buffer)
    (define-key map (kbd "C-c C-a") #'ogent-cabinet-compose-add-attachment)
    (define-key map (kbd "C-c C-k") #'kill-buffer)
    map)
  "Keymap for `ogent-cabinet-compose-mode'.")

(defvar-local ogent-cabinet-compose--root nil
  "Cabinet root for the current composer buffer.")

(defvar-local ogent-cabinet-compose--agent nil
  "Agent slug for the current composer buffer.")

(defvar-local ogent-cabinet-compose--attachments nil
  "Attachment files selected in the current composer buffer.")

(define-derived-mode ogent-cabinet-compose-mode org-mode "Cabinet-Compose"
  "Major mode for Cabinet composer buffers."
  (add-hook 'completion-at-point-functions
            #'ogent-cabinet-compose-completion-at-point
            nil t)
  (setq-local header-line-format
              "C-c C-c submit  C-c C-a attach  C-c C-k cancel"))

(defun ogent-cabinet-compose--mention-regexp ()
  "Return mention regexp."
  "@\\(agent\\|page\\|skill\\|job\\|conversation\\):\\([^[:space:]\n\r,;]+\\)")

(defun ogent-cabinet-compose--page-record (root token)
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

(defun ogent-cabinet-compose--agent-record (root token)
  "Return an agent mention record for TOKEN under ROOT."
  (condition-case nil
      (let ((agent (ogent-cabinet-resolve-agent
                    root token :include-visible t)))
        (list :type 'agent
              :key token
              :path (plist-get agent :path)
              :title (or (plist-get agent :display-name)
                         (plist-get agent :name))
              :scope (plist-get agent :scope)
              :body (plist-get agent :body)))
    (user-error nil)))

(defun ogent-cabinet-compose--job-record (root token)
  "Return a job mention record for TOKEN under ROOT."
  (catch 'job
    (dolist (agent (ogent-cabinet-list-agents root))
      (when-let ((job (seq-find
                       (lambda (candidate)
                         (equal (plist-get candidate :id) token))
                       (ogent-cabinet-list-jobs root agent))))
        (throw 'job
               (list :type 'job
                     :key token
                     :path (ogent-cabinet-job-file root agent token)
                     :title (plist-get job :name)
                     :agent agent
                     :body (plist-get job :body)))))))

(defun ogent-cabinet-compose--conversation-record (root token)
  "Return a conversation mention record for TOKEN under ROOT."
  (when (file-readable-p (ogent-cabinet-conversation-file root token))
    (let ((detail (ogent-cabinet-conversation-detail root token)))
      (list :type 'conversation
            :key token
            :path (ogent-cabinet-conversation-file root token)
            :title (plist-get detail :title)
            :body (or (plist-get detail :context-summary)
                      (string-join
                       (mapcar (lambda (turn)
                                 (plist-get turn :content))
                               (plist-get detail :turns))
                       "\n\n"))))))

(defun ogent-cabinet-compose--skill-record (root token)
  "Return a skill mention record for TOKEN under ROOT."
  (condition-case nil
      (let ((skill (ogent-cabinet-skill-read root token)))
        (list :type 'skill
              :key (plist-get skill :key)
              :path (plist-get skill :path)
              :title (plist-get skill :title)
              :origin (plist-get skill :origin)
              :body (plist-get skill :body)))
    (user-error nil)))

(defun ogent-cabinet-compose--resolve-kind (root kind token)
  "Resolve mention KIND and TOKEN under ROOT."
  (pcase kind
    ("agent" (ogent-cabinet-compose--agent-record root token))
    ("page" (ogent-cabinet-compose--page-record root token))
    ("skill" (ogent-cabinet-compose--skill-record root token))
    ("job" (ogent-cabinet-compose--job-record root token))
    ("conversation" (ogent-cabinet-compose--conversation-record root token))
    (_ nil)))

(defun ogent-cabinet-compose-resolve-mention (root mention)
  "Resolve MENTION under ROOT."
  (unless (string-match "\\`@?\\([^:]+\\):\\(.+\\)\\'" mention)
    (user-error "Malformed Cabinet mention: %s" mention))
  (let ((kind (match-string 1 mention))
        (token (match-string 2 mention)))
    (or (ogent-cabinet-compose--resolve-kind root kind token)
        (let ((trimmed (string-trim-right token "[.?!)]+")))
          (unless (equal trimmed token)
            (ogent-cabinet-compose--resolve-kind root kind trimmed)))
        (user-error "Cabinet mention not found: %s" mention))))

(defun ogent-cabinet-compose-mentions (root text)
  "Return mention records in TEXT under ROOT."
  (let (mentions)
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (while (re-search-forward (ogent-cabinet-compose--mention-regexp) nil t)
        (push (ogent-cabinet-compose-resolve-mention
               root
               (match-string 0))
              mentions)))
    (nreverse mentions)))

(defun ogent-cabinet-compose-mention-candidates (root)
  "Return completion candidates for mentions under ROOT."
  (append
   (mapcar (lambda (agent)
             (concat "@agent:" agent))
           (ogent-cabinet-list-visible-agents
            root :include-visible t))
   (apply
    #'append
    (mapcar
     (lambda (agent)
       (mapcar (lambda (job)
                 (concat "@job:" (plist-get job :id)))
               (ogent-cabinet-list-jobs root agent)))
     (ogent-cabinet-list-agents root)))
   (mapcar (lambda (conversation)
             (concat "@conversation:" (plist-get conversation :id)))
           (ogent-cabinet-conversation-list root))
   (mapcar (lambda (skill)
             (concat "@skill:" (plist-get skill :key)))
           (ogent-cabinet-skill-list root))
   (mapcar (lambda (file)
             (concat "@page:" (file-relative-name file root)))
           (ogent-cabinet-org-files root))))

(defun ogent-cabinet-compose-completion-at-point ()
  "Return Cabinet mention completion at point."
  (when-let ((root (or ogent-cabinet-compose--root
                       (ogent-cabinet-find-root))))
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
              (ogent-cabinet-compose-mention-candidates root))))))

(defun ogent-cabinet-compose--mention-paths (mentions)
  "Return durable paths from MENTIONS."
  (delq nil
        (mapcar (lambda (mention)
                  (plist-get mention :path))
                mentions)))

(defun ogent-cabinet-compose-build-prompt (root input)
  "Return provider prompt text for composer INPUT under ROOT."
  (let* ((instruction (or (plist-get input :instruction) ""))
         (mentions (or (plist-get input :mentions)
                       (ogent-cabinet-compose-mentions root instruction)))
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
          (ogent-cabinet-skill-bundle root skills)))))
     "\n\n")))

(defun ogent-cabinet-compose--read-list (prompt)
  "Read comma-separated values with PROMPT."
  (let ((value (read-string prompt)))
    (unless (string-blank-p value)
      (split-string value "[ \t]*,[ \t]*" t))))

;;;###autoload
(cl-defun ogent-cabinet-compose
    (directory agent-slug instruction
               &key mentions attachments skills runtime)
  "Run AGENT-SLUG from DIRECTORY with composer INSTRUCTION."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (agent (completing-read "Agent: "
                                  (ogent-cabinet-list-agents root)
                                  nil t))
          (instruction (read-string "Prompt: ")))
     (list root agent instruction
           :mentions (ogent-cabinet-compose--read-list "Extra mentions: ")
           :attachments (ogent-cabinet-compose--read-list "Attachments: ")
           :skills (ogent-cabinet-compose--read-list "Skills: "))))
  (let* ((root (ogent-cabinet--directory directory))
         (mention-records
          (append (ogent-cabinet-compose-mentions root instruction)
                  (mapcar (lambda (mention)
                            (ogent-cabinet-compose-resolve-mention root mention))
                          mentions)))
         (staged (when attachments
                   (ogent-cabinet-conversation-stage-attachments
                    root attachments)))
         (prompt (ogent-cabinet-compose-build-prompt
                  root
                  (list :instruction instruction
                        :mentions mention-records
                        :attachment-paths (plist-get staged :attachment-paths)
                        :skills skills)))
         (runtime (or runtime (ogent-cabinet-runtime-picker "Runtime: ")))
         (plan (ogent-cabinet-runner-plan
                root agent-slug
                :instruction prompt
                :turn-content instruction
                :runtime-mode (plist-get runtime :runtime-mode)
                :mentions (ogent-cabinet-compose--mention-paths mention-records)
                :skills skills
                :pending-attachment-id (plist-get staged :pending-id))))
    (when (ogent-cabinet-runner--confirm plan)
      (ogent-cabinet-runner-start plan))))

;;;###autoload
(defun ogent-cabinet-compose-buffer (&optional directory agent-slug)
  "Open a Cabinet composer buffer for DIRECTORY and AGENT-SLUG."
  (interactive)
  (let* ((root (ogent-cabinet--directory
                (or directory
                    (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: "))))
         (agent (or agent-slug
                    (completing-read "Agent: "
                                     (ogent-cabinet-list-agents root)
                                     nil t)))
         (buffer (generate-new-buffer
                  (format "*ogent-cabinet-compose:%s*" agent))))
    (with-current-buffer buffer
      (ogent-cabinet-compose-mode)
      (setq ogent-cabinet-compose--root root)
      (setq ogent-cabinet-compose--agent agent)
      (insert "# Prompt\n\n")
      (goto-char (point-max)))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-compose-add-attachment (file)
  "Add FILE as an attachment in the current composer buffer."
  (interactive "fAttachment: ")
  (push file ogent-cabinet-compose--attachments)
  (save-excursion
    (goto-char (point-max))
    (insert (propertize
             (format "\n[attachment:%s]" (file-name-nondirectory file))
             'read-only t
             'ogent-cabinet-attachment file
             'help-echo file)
            "\n")))

(defun ogent-cabinet-compose-submit-buffer ()
  "Submit the current composer buffer."
  (interactive)
  (unless (and ogent-cabinet-compose--root ogent-cabinet-compose--agent)
    (user-error "Not in a Cabinet composer buffer"))
  (let ((instruction (string-trim
                      (buffer-substring-no-properties
                       (point-min)
                       (point-max)))))
    (ogent-cabinet-compose
     ogent-cabinet-compose--root
     ogent-cabinet-compose--agent
     instruction
     :attachments (nreverse ogent-cabinet-compose--attachments))))

(provide 'ogent-cabinet-compose)

;;; ogent-cabinet-compose.el ends here

;;; ogent-armory-conversations-tests.el --- Tests for Armory conversations -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Org-backed canonical Armory conversation store.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'org)

(defmacro ogent-armory-conversations-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-conversations-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-armory-conversation-round-trips-index ()
  "Conversation metadata is durable in an Org index file."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (let* ((file (ogent-armory-conversation-create
                  dir
                  '(:id "conv-1"
                    :agent "cto"
                    :title "Review architecture"
                    :trigger "manual"
                    :status "running"
                    :started "2026-05-06T09:00:00Z"
                    :provider "codex-cli"
                    :adapter "codex_local"
                    :model "gpt-5.4"
                    :effort "high"
                    :runtime-mode "native"
                    :mentioned-paths ("roadmap.org" "systems/index.org")
                    :attachment-paths ("attachments/design.pdf")
                    :artifact-paths ("architecture.org")
                    :summary "Initial architecture review"
                    :context-summary "Keep architecture tight."
                    :board-order 7
                    :muted nil)))
           (conversation (ogent-armory-conversation-read dir "conv-1")))
      (should (file-exists-p file))
      (should (string-suffix-p ".agents/.conversations/conv-1/index.org" file))
      (should (equal (plist-get conversation :id) "conv-1"))
      (should (equal (plist-get conversation :agent) "cto"))
      (should (equal (plist-get conversation :title) "Review architecture"))
      (should (equal (plist-get conversation :trigger) "manual"))
      (should (equal (plist-get conversation :status) "running"))
      (should (equal (plist-get conversation :provider) "codex-cli"))
      (should (equal (plist-get conversation :adapter) "codex_local"))
      (should (equal (plist-get conversation :model) "gpt-5.4"))
      (should (equal (plist-get conversation :effort) "high"))
      (should (equal (plist-get conversation :runtime-mode) "native"))
      (should (equal (plist-get conversation :mentioned-paths)
                     '("roadmap.org" "systems/index.org")))
      (should (equal (plist-get conversation :attachment-paths)
                     '("attachments/design.pdf")))
      (should (equal (plist-get conversation :artifact-paths)
                     '("architecture.org")))
      (should (equal (plist-get conversation :summary)
                     "Initial architecture review"))
      (should (= (plist-get conversation :board-order) 7))
      (should-not (plist-get conversation :muted)))))

(ert-deftest ogent-armory-conversation-appends-turns-and-events ()
  "Conversation turns and events append as first-class Org records."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-conversation-create
     dir
     '(:id "conv-2"
       :agent "editor"
       :title "Draft update"
       :status "idle"
       :started "2026-05-06T10:00:00Z"))
    (let ((user-turn (ogent-armory-conversation-append-turn
                      dir "conv-2" "user" "Draft the update."
                      :ts "2026-05-06T10:01:00Z"
                      :mentioned-paths '("updates.org")))
          (agent-turn (ogent-armory-conversation-append-turn
                       dir "conv-2" "agent" "Done.\n\n#+begin_armory\nSUMMARY: Drafted update\nARTIFACT: updates.org\n#+end_armory"
                       :ts "2026-05-06T10:02:00Z"
                       :artifacts '("updates.org"))))
      (should (file-exists-p user-turn))
      (should (file-exists-p agent-turn)))
    (ogent-armory-conversation-append-event
     dir "conv-2" "turn.appended"
     :seq 1
     :ts "2026-05-06T10:01:00Z"
     :payload "role=user")
    (let ((turns (ogent-armory-conversation-read-turns dir "conv-2"))
          (events (ogent-armory-conversation-read-events dir "conv-2")))
      (should (= 2 (length turns)))
      (should (equal (plist-get (car turns) :role) "user"))
      (should (equal (plist-get (car turns) :turn) 1))
      (should (equal (plist-get (cadr turns) :role) "agent"))
      (should (equal (plist-get (cadr turns) :artifacts) '("updates.org")))
      (should (= 1 (length events)))
      (should (equal (plist-get (car events) :type) "turn.appended"))
      (should (= (plist-get (car events) :seq) 1)))))

(ert-deftest ogent-armory-conversation-append-turn-does-not-visit-index ()
  "Appending a turn updates index metadata without visiting the index file."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-conversation-create
     dir
     '(:id "conv-buffer"
       :agent "editor"
       :title "Buffer hygiene"
       :status "idle"))
    (let ((index (ogent-armory-conversation-file dir "conv-buffer")))
      (should-not (get-file-buffer index))
      (ogent-armory-conversation-append-turn
       dir "conv-buffer" "user" "Keep metadata edits unvisited."
       :ts "2026-05-06T10:03:00Z")
      (should-not (get-file-buffer index))
      (should (equal (plist-get (ogent-armory-conversation-read
                                 dir "conv-buffer")
                                :last-activity)
                     "2026-05-06T10:03:00Z")))))

(ert-deftest ogent-armory-conversation-demotes-turn-headings ()
  "Org headings in turn content remain nested inside the turn record."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-conversation-create
     dir
     '(:id "conv-headings"
       :agent "editor"
       :title "Heading safety"
       :status "idle"))
    (let* ((content (concat
                     "* Findings\n"
                     "Body.\n"
                     "** Detail\n"
                     "#+begin_src text\n"
                     "* literal code line\n"
                     "#+end_src\n"))
           (file (ogent-armory-conversation-append-turn
                  dir "conv-headings" "agent" content))
           (raw (with-temp-buffer
                  (insert-file-contents file)
                  (buffer-string)))
           (turns (ogent-armory-conversation-read-turns
                   dir "conv-headings"))
           (read-content (plist-get (car turns) :content)))
      (should (string-match-p "^\\* Agent turn 1$" raw))
      (should (string-match-p "^\\*\\* Findings$" raw))
      (should (string-match-p "^\\*\\*\\* Detail$" raw))
      (should (string-match-p "^,\\* literal code line$" raw))
      (should-not (string-match-p "^\\* Findings$" raw))
      (should (string-match-p "\\*\\* Findings" read-content))
      (should (string-match-p "\\*\\*\\* Detail" read-content))
      (should (string-match-p ",\\* literal code line" read-content)))))

(ert-deftest ogent-armory-conversation-parses-armory-blocks ()
  "Armory metadata blocks and ask-user markers are parsed from output."
  (let* ((output (concat
                  "I need one detail.\n\n"
                  "<ask_user>Which audience should this target?</ask_user>\n\n"
                  "```armory\n"
                  "SUMMARY: Need audience\n"
                  "CONTEXT: Waiting on the target reader.\n"
                  "ARTIFACT: none\n"
                  "ARTIFACT: notes/audience.org\n"
                  "```\n"))
         (parsed (ogent-armory-conversation-parse-output output)))
    (should (plist-get parsed :awaiting-input))
    (should (equal (plist-get parsed :ask-user)
                   "Which audience should this target?"))
    (should (equal (plist-get parsed :summary) "Need audience"))
    (should (equal (plist-get parsed :context-summary)
                   "Waiting on the target reader."))
    (should (equal (plist-get parsed :artifact-paths)
                   '("notes/audience.org")))))

(ert-deftest ogent-armory-conversation-list-sorts-by-activity ()
  "Conversation lists sort newest activity first."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-conversation-create
     dir
     '(:id "old"
       :agent "editor"
       :title "Old"
       :status "done"
       :started "2026-05-06T08:00:00Z"
       :last-activity "2026-05-06T08:30:00Z"))
    (ogent-armory-conversation-create
     dir
     '(:id "new"
       :agent "cto"
       :title "New"
       :status "running"
       :started "2026-05-06T09:00:00Z"
       :last-activity "2026-05-06T09:30:00Z"))
    (let ((conversations (ogent-armory-conversation-list dir)))
      (should (equal (mapcar (lambda (conversation)
                               (plist-get conversation :id))
                             conversations)
                     '("new" "old"))))))

(ert-deftest ogent-armory-conversation-migrates-legacy-session ()
  "Legacy per-agent session transcripts can become canonical conversations."
  (ogent-armory-conversations-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (let* ((session-file (expand-file-name
                          "20260506T100000-review.org"
                          (ogent-armory-sessions-directory dir "cto"))))
      (ogent-armory--write-file
       session-file
       (concat
        "#+title: Architecture Review\n\n"
        "* DONE Architecture Review\n"
        ":PROPERTIES:\n"
        ":OGENT_SESSION: t\n"
        ":OGENT_AGENT: cto\n"
        ":OGENT_PROVIDER: codex\n"
        ":OGENT_MODEL: gpt-5.4\n"
        ":OGENT_JOB_ID: weekly-review\n"
        ":OGENT_EXIT_STATUS: 0\n"
        ":OGENT_DURATION: 3s\n"
        ":OGENT_FINISHED: 2026-05-06T10:03:00Z\n"
        ":OGENT_APP_PATHS: apps/review\n"
        ":END:\n"
        "\n** Prompt\n#+begin_src text\nReview the plan.\n#+end_src\n"
        "\n** Output\n#+begin_src text\nLooks coherent.\n#+end_src\n"))
      (let* ((conversation-file
              (ogent-armory-conversation-migrate-session dir session-file "cto"))
             (conversation (ogent-armory-conversation-read
                            dir "20260506T100000-review"))
             (turns (ogent-armory-conversation-read-turns
                     dir "20260506T100000-review")))
        (should (file-exists-p conversation-file))
        (should (equal (plist-get conversation :agent) "cto"))
        (should (equal (plist-get conversation :status) "done"))
        (should (equal (plist-get conversation :job-id) "weekly-review"))
        (should (equal (plist-get conversation :artifact-paths)
                       '("apps/review")))
        (should (= 2 (length turns)))
        (should (string-match-p "Review the plan"
                                (plist-get (car turns) :content)))
        (should (string-match-p "Looks coherent"
                                (plist-get (cadr turns) :content)))))))

(provide 'ogent-armory-conversations-tests)

;;; ogent-armory-conversations-tests.el ends here

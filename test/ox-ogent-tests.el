;;; ox-ogent-tests.el --- Tests for ox-ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the ogent conversation export backends.  A string fixture
;; mirrors the conversation subtree shape ogent-ui writes (Request /
;; Response headlines, OGENT_* property drawers, prompt src block) and
;; is exported from an `org-mode' temp buffer; no network or external
;; process is involved.

;;; Code:

(require 'ogent-test-helper)
(require 'ox-ogent)

(defconst ox-ogent-tests--fixture
  "* Parser deep dive
:PROPERTIES:
:OGENT_CONVERSATION: t
:OGENT_CONVERSATION_ID: conv-0042
:OGENT_MODEL: claude-fable-5
:END:
Intro prose kept in the export.

#+OGENT_TRACE: internal-marker
#+PROPERTY: OGENT_MODEL claude-fable-5

** Request: Explain the parser
:PROPERTIES:
:OGENT_PROMPT: Explain the parser in detail
:OGENT_STYLE: zen
:OGENT_KIND: request
:END:
#+begin_src text :model claude-fable-5 :status done
Explain the parser in detail
#+end_src

*** Response (claude-fable-5)
The parser walks the tree:

#+begin_src emacs-lisp
(defun parse (x) x)
#+end_src
"
  "Conversation subtree fixture in the shape ogent-ui writes.")

(defun ox-ogent-tests--export (backend &optional ext-plist)
  "Export the fixture conversation subtree through BACKEND.
EXT-PLIST overrides export options.  Return the output string."
  (with-temp-buffer
    (insert ox-ogent-tests--fixture)
    (org-mode)
    (goto-char (point-min))
    (org-export-as backend t nil nil ext-plist)))

;;; Markdown backend

(ert-deftest ox-ogent-md-strips-ogent-drawers ()
  "OGENT_* property drawers never reach the Markdown output."
  (let ((md (ox-ogent-tests--export 'ogent-md)))
    (should (stringp md))
    (should-not (string-match-p "OGENT_" md))
    (should-not (string-match-p ":PROPERTIES:" md))))

(ert-deftest ox-ogent-md-strips-drawers-with-properties-enabled ()
  "The parse-tree filter strips drawers even under \\=`:with-properties t'."
  (let ((md (ox-ogent-tests--export 'ogent-md '(:with-properties t))))
    (should-not (string-match-p "OGENT_" md))))

(ert-deftest ox-ogent-md-strips-internal-keywords ()
  "OGENT keywords and OGENT_* property keywords are dropped."
  (let ((md (ox-ogent-tests--export 'ogent-md)))
    (should-not (string-match-p "internal-marker" md))
    (should-not (string-match-p "OGENT_TRACE" md))))

(ert-deftest ox-ogent-md-maps-exchange-headlines ()
  "Request/Response headlines render as ## User / ## MODEL sections."
  (let ((md (ox-ogent-tests--export 'ogent-md)))
    (should (string-match-p "^## User$" md))
    (should (string-match-p "^## claude-fable-5$" md))
    (should-not (string-match-p "Request:" md))
    (should-not (string-match-p "Response (" md))))

(ert-deftest ox-ogent-md-empty-model-maps-to-assistant ()
  "A Response headline with an empty model id renders as ## Assistant."
  (let ((md (with-temp-buffer
              (insert "* Chat\n** Request: hi\n*** Response ()\nHello.\n")
              (org-mode)
              (goto-char (point-min))
              (org-export-as 'ogent-md t))))
    (should (string-match-p "^## Assistant$" md))
    (should (string-match-p "Hello\\." md))))

(ert-deftest ox-ogent-md-keeps-src-blocks-fenced ()
  "Src blocks export as GFM fences, not indented code."
  (let ((md (ox-ogent-tests--export 'ogent-md)))
    (should (string-match-p "```text\nExplain the parser in detail\n```" md))
    (should (string-match-p "```emacs-lisp\n(defun parse (x) x)\n```" md))))

(ert-deftest ox-ogent-md-keeps-ordinary-content ()
  "Prose bodies and ordinary headlines survive the export untouched."
  (let ((md (ox-ogent-tests--export 'ogent-md)))
    (should (string-match-p "Intro prose kept in the export\\." md))
    (should (string-match-p "The parser walks the tree:" md))))

;;; HTML backend

(ert-deftest ox-ogent-html-export-smoke ()
  "The HTML variant exports cleanly with drawers stripped."
  (let ((html (ox-ogent-tests--export 'ogent-html)))
    (should (stringp html))
    (should (string-match-p "User" html))
    (should (string-match-p "claude-fable-5" html))
    (should-not (string-match-p "OGENT_" html))))

;;; Interactive command

(ert-deftest ox-ogent-export-conversation-climbs-to-root ()
  "Invoking the export inside a response exports the whole conversation."
  (with-temp-buffer
    (insert ox-ogent-tests--fixture)
    (org-mode)
    (goto-char (point-min))
    (search-forward "(defun parse")
    (let ((org-export-show-temporary-export-buffer nil))
      (unwind-protect
          (progn
            (ogent-export-conversation)
            (with-current-buffer ox-ogent--export-buffer-name
              (should (string-match-p "^## User$" (buffer-string)))
              (should (string-match-p "^## claude-fable-5$" (buffer-string)))))
        (when (get-buffer ox-ogent--export-buffer-name)
          (kill-buffer ox-ogent--export-buffer-name))))))

(ert-deftest ox-ogent-export-conversation-requires-org-mode ()
  "The export command refuses to run outside `org-mode'."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (ogent-export-conversation) :type 'user-error)))

(ert-deftest ox-ogent-export-conversation-requires-a-subtree ()
  "The export command refuses to run before the first headline."
  (with-temp-buffer
    (insert "no headline here\n")
    (org-mode)
    (goto-char (point-min))
    (should-error (ogent-export-conversation) :type 'user-error)))

(ert-deftest ox-ogent-dispatcher-menu-entry-registered ()
  "The ogent-md backend exposes both conversation exports in the dispatcher."
  (let ((menu (org-export-backend-menu (org-export-get-backend 'ogent-md))))
    (should (equal (car menu) ?g))
    (should (equal (mapcar #'caddr (nth 2 menu))
                   '(ox-ogent-export-conversation-md
                     ox-ogent-export-conversation-html)))))

(ert-deftest ox-ogent-dispatcher-md-climbs-to-root ()
  "The dispatcher Markdown wrapper exports the whole conversation from a child."
  (with-temp-buffer
    (insert ox-ogent-tests--fixture)
    (org-mode)
    (goto-char (point-min))
    (search-forward "(defun parse")
    (let ((org-export-show-temporary-export-buffer nil))
      (unwind-protect
          (progn
            (ox-ogent-export-conversation-md)
            (with-current-buffer ox-ogent--export-buffer-name
              (should (string-match-p "^## User$" (buffer-string)))
              (should (string-match-p "^## claude-fable-5$" (buffer-string)))))
        (when (get-buffer ox-ogent--export-buffer-name)
          (kill-buffer ox-ogent--export-buffer-name))))))

(ert-deftest ox-ogent-dispatcher-html-climbs-to-root ()
  "The dispatcher HTML wrapper exports the whole conversation from a child."
  (with-temp-buffer
    (insert ox-ogent-tests--fixture)
    (org-mode)
    (goto-char (point-min))
    (search-forward "(defun parse")
    (let ((org-export-show-temporary-export-buffer nil))
      (unwind-protect
          (progn
            (ox-ogent-export-conversation-html)
            (with-current-buffer ox-ogent--export-buffer-name
              (let ((html (buffer-string)))
                (should (string-match-p "User" html))
                (should (string-match-p "claude-fable-5" html))
                (should-not (string-match-p "OGENT_" html)))))
        (when (get-buffer ox-ogent--export-buffer-name)
          (kill-buffer ox-ogent--export-buffer-name))))))

(provide 'ox-ogent-tests)

;;; ox-ogent-tests.el ends here

;;; ogent-agent-detail-tests.el --- Tests for ogent-agent-detail -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the agent detail inspector module.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-agent-detail)

;;; Test Fixtures

(defconst ogent-agent-detail-test--crew-data
  '(:name "stallman"
    :rig "ogent"
    :path "/Users/jake/gt/ogent/crew/stallman"
    :branch "master"
    :has_session t
    :session_id "gt-ogent-crew-stallman"
    :git_clean nil
    :git_modified ("lisp/foo.el" "test/bar.el")
    :mail_total 3
    :mail_unread 1)
  "Sample crew member data.")

(defconst ogent-agent-detail-test--polecat-data
  '(:rig "ogent"
    :name "obsidian"
    :state "working"
    :issue "og-ogent-crew-hjt"
    :session_running t)
  "Sample polecat data.")

;;; Mode Tests

(ert-deftest ogent-agent-detail-test-mode-defined ()
  "Test that the mode is properly defined."
  (should (fboundp 'ogent-agent-detail-mode)))

(ert-deftest ogent-agent-detail-test-keymap-exists ()
  "Test that the mode keymap exists."
  (should (keymapp ogent-agent-detail-mode-map)))

(ert-deftest ogent-agent-detail-test-keymap-has-g ()
  "Test that g is bound to refresh."
  (should (eq (lookup-key ogent-agent-detail-mode-map "g")
              #'ogent-agent-detail-refresh)))

(ert-deftest ogent-agent-detail-test-keymap-has-q ()
  "Test that q is bound to quit."
  (should (eq (lookup-key ogent-agent-detail-mode-map "q")
              #'quit-window)))

(ert-deftest ogent-agent-detail-test-keymap-has-M ()
  "Test that M is bound to mail."
  (should (eq (lookup-key ogent-agent-detail-mode-map "M")
              #'ogent-agent-detail-mail)))

(ert-deftest ogent-agent-detail-test-keymap-has-ret ()
  "Test that RET is bound to visit."
  (should (eq (lookup-key ogent-agent-detail-mode-map (kbd "RET"))
              #'ogent-agent-detail-visit)))

;;; Entry Point Tests

(ert-deftest ogent-agent-detail-test-inspect-empty-name ()
  "Test inspect with empty name errors."
  (should-error (ogent-agent-detail-inspect "" 'crew) :type 'user-error))

(ert-deftest ogent-agent-detail-test-inspect-nil-name ()
  "Test inspect with nil name errors."
  (should-error (ogent-agent-detail-inspect nil 'crew) :type 'user-error))

(ert-deftest ogent-agent-detail-test-inspect-creates-buffer ()
  "Test inspect creates buffer with correct name."
  (let ((buf (get-buffer "*Crew: test-agent*")))
    (when buf (kill-buffer buf)))
  (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore)
            ((symbol-function 'ogent-agent-detail--fetch)
             (lambda (cb) (funcall cb))))
    (ogent-agent-detail-inspect "test-agent" 'crew "ogent")
    (let ((buf (get-buffer "*Crew: test-agent*")))
      (should buf)
      (with-current-buffer buf
        (should (derived-mode-p 'ogent-agent-detail-mode))
        (should (equal "test-agent" ogent-agent-detail--name))
        (should (equal 'crew ogent-agent-detail--kind))
        (should (equal "ogent" ogent-agent-detail--rig)))
      (kill-buffer buf))))

(ert-deftest ogent-agent-detail-test-inspect-polecat-buffer-name ()
  "Test polecat inspect creates correct buffer name."
  (let ((buf (get-buffer "*Polecat: alpha*")))
    (when buf (kill-buffer buf)))
  (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore)
            ((symbol-function 'ogent-agent-detail--fetch)
             (lambda (cb) (funcall cb))))
    (ogent-agent-detail-inspect "alpha" 'polecat "ogent")
    (let ((buf (get-buffer "*Polecat: alpha*")))
      (should buf)
      (with-current-buffer buf
        (should (equal 'polecat ogent-agent-detail--kind)))
      (kill-buffer buf))))

;;; Rendering Tests

(ert-deftest ogent-agent-detail-test-insert-field ()
  "Test field rendering produces correct output."
  (with-temp-buffer
    (ogent-agent-detail--insert-field "Name:" "stallman")
    (let ((content (buffer-string)))
      (should (string-match-p "Name:" content))
      (should (string-match-p "stallman" content)))))

(ert-deftest ogent-agent-detail-test-insert-field-nil-value ()
  "Test field rendering with nil value shows dash."
  (with-temp-buffer
    (ogent-agent-detail--insert-field "Name:" nil)
    (let ((content (buffer-string)))
      (should (string-match-p "—" content)))))

(ert-deftest ogent-agent-detail-test-crew-info-fields ()
  "Test crew info fields render name, rig, role, session."
  (with-temp-buffer
    (let ((ogent-agent-detail--kind 'crew))
      (ogent-agent-detail--insert-info-fields
       ogent-agent-detail-test--crew-data)
      (let ((content (buffer-string)))
        (should (string-match-p "stallman" content))
        (should (string-match-p "ogent" content))
        (should (string-match-p "crew" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-agent-detail-test-polecat-info-fields ()
  "Test polecat info fields render name, rig, state, session."
  (with-temp-buffer
    (let ((ogent-agent-detail--kind 'polecat))
      (ogent-agent-detail--insert-info-fields
       ogent-agent-detail-test--polecat-data)
      (let ((content (buffer-string)))
        (should (string-match-p "obsidian" content))
        (should (string-match-p "ogent" content))
        (should (string-match-p "working" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-agent-detail-test-git-fields-dirty ()
  "Test git fields render dirty state with modified files."
  (with-temp-buffer
    (ogent-agent-detail--insert-git-fields "master" nil '("lisp/foo.el" "test/bar.el"))
    (let ((content (buffer-string)))
      (should (string-match-p "master" content))
      (should (string-match-p "dirty" content))
      (should (string-match-p "lisp/foo.el" content))
      (should (string-match-p "test/bar.el" content)))))

(ert-deftest ogent-agent-detail-test-git-fields-clean ()
  "Test git fields render clean state."
  (with-temp-buffer
    (ogent-agent-detail--insert-git-fields "master" t nil)
    (let ((content (buffer-string)))
      (should (string-match-p "master" content))
      (should (string-match-p "clean" content)))))

(ert-deftest ogent-agent-detail-test-work-fields-with-issue ()
  "Test work fields render hooked issue."
  (with-temp-buffer
    (ogent-agent-detail--insert-work-fields "og-abc" 3 1)
    (let ((content (buffer-string)))
      (should (string-match-p "og-abc" content))
      (should (string-match-p "3 total" content))
      (should (string-match-p "1 unread" content)))))

(ert-deftest ogent-agent-detail-test-work-fields-no-issue ()
  "Test work fields render when no hooked work."
  (with-temp-buffer
    (ogent-agent-detail--insert-work-fields nil 0 0)
    (let ((content (buffer-string)))
      (should (string-match-p "(none)" content)))))

(ert-deftest ogent-agent-detail-test-info-section-nil-data ()
  "Test info section renders not-found message with nil data."
  (with-temp-buffer
    (let ((ogent-agent-detail--magit-section-available nil)
          (ogent-agent-detail--kind 'crew))
      (ogent-agent-detail--insert-info-fields nil)
      (let ((content (buffer-string)))
        (should (string-match-p "Agent not found" content))))))

;;; Header Line Tests

(ert-deftest ogent-agent-detail-test-header-line-crew ()
  "Test header line includes agent kind and name."
  (let ((ogent-agent-detail--kind 'crew)
        (ogent-agent-detail--name "stallman"))
    (let ((header (ogent-agent-detail--header-line)))
      (should (string-match-p "Crew" header))
      (should (string-match-p "stallman" header)))))

(ert-deftest ogent-agent-detail-test-header-line-polecat ()
  "Test header line shows polecat kind."
  (let ((ogent-agent-detail--kind 'polecat)
        (ogent-agent-detail--name "alpha"))
    (let ((header (ogent-agent-detail--header-line)))
      (should (string-match-p "Polecat" header))
      (should (string-match-p "alpha" header)))))

;;; Mail Action Tests

(ert-deftest ogent-agent-detail-test-mail-crew-address ()
  "Test mail composes to correct crew address."
  (let ((ogent-agent-detail--rig "ogent")
        (ogent-agent-detail--kind 'crew)
        (ogent-agent-detail--name "stallman")
        (composed-to nil))
    (cl-letf (((symbol-function 'ogent-gastown-mail-compose)
               (lambda (addr) (setq composed-to addr))))
      (ogent-agent-detail-mail)
      (should (equal composed-to "ogent/crew/stallman")))))

(ert-deftest ogent-agent-detail-test-mail-polecat-address ()
  "Test mail composes to correct polecat address."
  (let ((ogent-agent-detail--rig "ogent")
        (ogent-agent-detail--kind 'polecat)
        (ogent-agent-detail--name "obsidian")
        (composed-to nil))
    (cl-letf (((symbol-function 'ogent-gastown-mail-compose)
               (lambda (addr) (setq composed-to addr))))
      (ogent-agent-detail-mail)
      (should (equal composed-to "ogent/polecats/obsidian")))))

;;; Face Tests

(ert-deftest ogent-agent-detail-test-face-section-heading ()
  "Test section heading face is defined."
  (should (facep 'ogent-agent-detail-section-heading)))

(ert-deftest ogent-agent-detail-test-face-active ()
  "Test active face is defined."
  (should (facep 'ogent-agent-detail-active)))

(ert-deftest ogent-agent-detail-test-face-inactive ()
  "Test inactive face is defined."
  (should (facep 'ogent-agent-detail-inactive)))

(ert-deftest ogent-agent-detail-test-face-label ()
  "Test label face is defined."
  (should (facep 'ogent-agent-detail-label)))

(ert-deftest ogent-agent-detail-test-face-header-line ()
  "Test header line face is defined."
  (should (facep 'ogent-agent-detail-header-line)))

(ert-deftest ogent-agent-detail-test-face-header-key ()
  "Test header key face is defined."
  (should (facep 'ogent-agent-detail-header-key)))

;;; Plain-text Rendering Tests

(ert-deftest ogent-agent-detail-test-plain-crew-full ()
  "Test full plain-text crew rendering."
  (with-temp-buffer
    (let ((ogent-agent-detail--magit-section-available nil)
          (ogent-agent-detail--kind 'crew)
          (ogent-agent-detail--data ogent-agent-detail-test--crew-data))
      (ogent-agent-detail--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Agent" content))
        (should (string-match-p "stallman" content))
        (should (string-match-p "Git" content))
        (should (string-match-p "master" content))
        (should (string-match-p "Work" content))))))

(ert-deftest ogent-agent-detail-test-plain-polecat-no-git ()
  "Test polecat plain rendering skips Git section."
  (with-temp-buffer
    (let ((ogent-agent-detail--magit-section-available nil)
          (ogent-agent-detail--kind 'polecat)
          (ogent-agent-detail--data ogent-agent-detail-test--polecat-data))
      (ogent-agent-detail--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Agent" content))
        (should (string-match-p "obsidian" content))
        ;; Polecat should NOT have Git section
        (should-not (string-match-p "Branch:" content))))))

(provide 'ogent-agent-detail-tests)
;;; ogent-agent-detail-tests.el ends here

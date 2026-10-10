;;; ogent-ui-layout-tests.el --- Tests for native layouts -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise responsive presentation, selection, filters and draft actions
;; without authenticating or sending provider requests.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-ui-layout)
(require 'ogent-ui-section)
(require 'ogent-ui-models)
(require 'ogent-ui-armory)
(require 'ogent-armory-compose)

(ert-deftest ogent-ui-layout-location-retains-text-offset-and-window-start ()
  "Changing a reader's preamble keeps the same text under point and viewport."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "Old header\n" (propertize "First line\nSecond line\nThird line\n" 'review-item 'first))
      (goto-char (point-min)) (search-forward "Second")
      (set-window-start nil (line-beginning-position) t)
      (ogent-ui-layout-preserve-location 'review-item
        (erase-buffer)
        (insert "A new header\nWith another line\n"
                (propertize "First line\nSecond line\nThird line\n" 'review-item 'first)))
      (should (looking-back "Second" (line-beginning-position)))
      (should (equal (buffer-substring (window-start) (+ (window-start) 6)) "Second")))))

(ert-deftest ogent-ui-layout-location-clamps-removed-and-shortened-items ()
  "Refreshing a removed or shortened item cannot leave point outside the buffer."
  (with-temp-buffer
    (insert (propertize "Long old item" 'review-item 'first))
    (goto-char 10)
    (ogent-ui-layout-preserve-location 'review-item
      (erase-buffer) (insert (propertize "New" 'review-item 'first)))
    (should (= (point) 3))
    (ogent-ui-layout-preserve-location 'review-item
      (erase-buffer))
    (should (= (point) (point-min)))))

(defmacro ogent-ui-layout-tests--with-registry (&rest body)
  "Run BODY with two models and deterministic roles."
  (declare (indent 0) (debug t))
  `(let ((ogent-default-model "alpha")
         (ogent-model-registry
          '((:id "alpha" :backend gptel-openai :stream? t :description "Alpha flagship")
            (:id "beta" :backend gptel-anthropic :stream? nil :description "Beta deep model")))
         (ogent-model-roles '((deep . "beta")))
         (ogent-theme-animation-speed 'none))
     ,@body))

(defmacro ogent-ui-layout-tests--with-root (root &rest body)
  "Run BODY with ROOT bound to an owned fixture directory."
  (declare (indent 1) (debug t))
  `(let ((,root (directory-file-name
                 (file-truename (ogent-test--provision-store-directory 'ui-layout)))))
     ,@body))

(defun ogent-ui-layout-tests--seed (root)
  "Create an agent and a scheduled job in owned ROOT."
  (ogent-armory-scaffold root "Layout fixture" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
   root '(:slug "cto" :name "CTO" :role "Architecture" :provider "codex"
                :model "gpt-5.4" :active t :tags ("strategy")) "Review the project.")
  (ogent-armory-write-job
   root "cto" '(:id "review" :name "Review" :enabled t :cron "0 9 * * 1")
   "Inspect the project without changing it."))

(defun ogent-ui-layout-tests--render (items)
  "Insert selectable ITEMS into the current test buffer."
  (erase-buffer)
  (insert "Heading\n")
  (dolist (item items)
    (ogent-section-insert-item-line item 'test-item item)))

(defun ogent-ui-layout-tests--goto-item (item)
  "Move point to selectable ITEM in the current test buffer."
  (goto-char (point-min))
  (while (and (not (equal item (ogent-section-item-at-point 'test-item)))
              (not (eobp)))
    (forward-line 1)))

(ert-deftest ogent-ui-layout-header-fits-and-retains-primary-action ()
  "Long context must not hide the primary action at common widths."
  (dolist (width '(60 80 112))
    (cl-letf (((symbol-function 'ogent-ui-layout-width) (lambda () width)))
      (let ((text (ogent-section-header-line
                   "Models" (make-string 200 ?x)
                   '("RET" . "switch") '("/" . "find") '("D" . "layout")
                   '("g" . "refresh") '("q" . "quit"))))
        (should (< (string-width text) width))
        (should (string-match-p "RET:switch" text))
        (should (string-match-p "Models" text))))))

(ert-deftest ogent-ui-layout-wraps-long-readable-text ()
  "Long text wraps without losing words or semantic properties."
  (with-temp-buffer
    (cl-letf (((symbol-function 'ogent-ui-layout-width) (lambda () 60)))
      (let ((text (propertize (mapconcat #'identity (make-list 30 "readable") " ")
                              'font-lock-face 'ogent-theme-muted)))
        (ogent-ui-layout-insert-text text "    ")
        (dolist (line (split-string (buffer-string) "\n"))
          (should (<= (string-width line) 56)))
        (should (= 31 (length (split-string (buffer-string) "readable"))))
        (should (eq (get-text-property 5 'font-lock-face) 'ogent-theme-muted))))))

(ert-deftest ogent-ui-layout-refresh-preserves-column-and-viewport ()
  "A reordered item stays at its viewport offset and column."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let ((rows (mapcar (lambda (n) (format "item-%03d" n)) (number-sequence 0 80))))
        (ogent-ui-layout-tests--render rows)
        (ogent-ui-layout-tests--goto-item "item-030")
        (move-to-column 5)
        (set-window-start (selected-window)
                          (save-excursion (forward-line -4) (point)) t)
        (ogent-section-preserve-point
            ((lambda () (ogent-section-item-at-point 'test-item)))
          (ogent-ui-layout-tests--render (append '("new-a" "new-b") rows)))
        (should (equal (ogent-section-item-at-point 'test-item) "item-030"))
        (should (= (current-column) 5))
        (should (= 4 (count-lines (window-start) (line-beginning-position))))))))

(ert-deftest ogent-ui-layout-model-layouts-preserve-selection-and-origin ()
  "Catalog navigation, table toggling and refresh retain the selected model."
  (ogent-ui-layout-tests--with-registry
    (save-window-excursion
      (with-temp-buffer
        (org-mode)
        (insert "* Pinned\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\n")
        (goto-char (point-max))
        (unwind-protect
            (progn
              (ogent-models-browse)
              (with-current-buffer ogent-ui-models--browser-buffer-name
                (should (eq ogent-ui-models--browser-layout 'catalog))
                (ogent-models-browser-next)
                (should (equal (ogent-ui-models--browser-model-at-point) "alpha"))
                (ogent-models-browser-next)
                (should (equal (ogent-ui-models--browser-model-at-point) "beta"))
                (ogent-models-browser-toggle-layout)
                (should (equal (ogent-ui-models--browser-model-at-point) "beta"))
                (should (string-match-p "Description" (buffer-string)))
                (ogent-models-browser-toggle-layout)
                (should (equal (ogent-ui-models--browser-model-at-point) "beta"))
                (ogent-models-browse)
                (should (equal (ogent-ui-models--browser-model-at-point) "beta"))
                (should (string-match-p "via org property" (buffer-string)))
                (ogent-models-browser-previous)
                (should (equal (ogent-ui-models--browser-model-at-point) "alpha"))))
          (when (get-buffer ogent-ui-models--browser-buffer-name)
            (kill-buffer ogent-ui-models--browser-buffer-name)))))))

(ert-deftest ogent-ui-layout-catalog-reflow-does-not-steal-focus ()
  "Reflow retains origin and selection without switching windows."
  (ogent-ui-layout-tests--with-registry
    (save-window-excursion
      (unwind-protect
          (progn
            (ogent-models-browse)
            (with-current-buffer ogent-ui-models--browser-buffer-name
              (ogent-ui-models--browser-goto "beta")
              (let ((window (selected-window)))
                (cl-letf (((symbol-function 'ogent-ui-layout-width) (lambda () 60))
                          ((symbol-function 'pop-to-buffer)
                           (lambda (&rest _) (ert-fail "Reflow stole focus"))))
                  (with-temp-buffer
                    (ogent-ui-models--browser-resize window)))
                (should (eq window (selected-window)))
                (should (= ogent-ui-models--browser-width 60))
                (should (equal (ogent-ui-models--browser-model-at-point) "beta")))))
        (when (get-buffer ogent-ui-models--browser-buffer-name)
          (kill-buffer ogent-ui-models--browser-buffer-name))))))

(ert-deftest ogent-ui-layout-agent-filter-searches-hidden-fields ()
  "Compact lists search complete records and retain row identity."
  (ogent-ui-layout-tests--with-root root
    (ogent-ui-layout-tests--seed root)
    (save-window-excursion
      (let ((buffer (ogent-armory-agents root)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'ogent-ui-layout-width) (lambda () 60)))
                (ogent-armory-agents-refresh)
                (should (= 3 (length tabulated-list-format)))
                (ogent-armory-agents-filter "strategy")
                (should (equal (mapcar #'car (ogent-armory-agents--entries)) '("cto")))
                (goto-char (point-min))
                (forward-line 1)
                (should (equal (tabulated-list-get-id) "cto"))
                (ogent-armory-agents-toggle-details)
                (should (= 14 (length tabulated-list-format)))
                (should (equal (tabulated-list-get-id) "cto"))
                (ogent-armory-agents-filter "no-such-agent")
                (should (string-match-p "No matches" (buffer-string)))
                (ogent-armory-agents-filter "")
                (should (equal (mapcar #'car (ogent-armory-agents--entries)) '("cto")))))
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-layout-task-columns-preserve-full-records ()
  "Task columns reflow while keeping complete item IDs and metadata."
  (ogent-ui-layout-tests--with-root root
    (ogent-ui-layout-tests--seed root)
    (save-window-excursion
      (let ((buffer (ogent-armory-tasks root)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'ogent-ui-layout-width) (lambda () 60)))
                (ogent-armory-tasks-refresh)
                (let ((entries (ogent-armory-tasks--display-entries)))
                  (should (= 3 (length (cadar entries))))
                  (should (equal (mapcar #'car entries)
                                 (mapcar #'car (ogent-armory-tasks--entries))))
                  (should (seq-some (lambda (entry) (plist-get (car entry) :path))
                                    entries)))
                (ogent-armory-tasks-toggle-details)
                (should (= 6 (length tabulated-list-format)))
                (should (string-match-p "When" (buffer-string)))))
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-layout-home-prioritizes-attention-and-drafts ()
  "Attention appears before navigation and compose opens an owned draft."
  (ogent-ui-layout-tests--with-root root
    (ogent-ui-layout-tests--seed root)
    (save-window-excursion
      (let ((buffer (ogent-armory-home root))
            called)
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (should-not (string-match-p "agentic org-mode" (buffer-string)))
              (search-forward "Needs Attention")
              (should (< (line-number-at-pos) 12))
              (let ((attention (point)))
                (search-forward "Navigate")
                (should (< attention (point))))
              (cl-letf (((symbol-function 'ogent-armory-compose-buffer)
                         (lambda (directory &optional _) (setq called directory))))
                (call-interactively (lookup-key ogent-armory-home-mode-map "c")))
              (should (equal root called)))
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-layout-header-advertises-active-evil-refresh ()
  "A native Evil g prefix advertises gr rather than an inactive bare g."
  (let ((prefix (make-sparse-keymap)))
    (define-key prefix "r" #'ignore)
    (cl-letf (((symbol-function 'key-binding) (lambda (&rest _) prefix)))
      (let ((header (ogent-section-header-line "Agents" nil '("g" . "refresh"))))
        (should (string-match-p "gr:refresh" header))))))

(ert-deftest ogent-ui-layout-compose-keeps-draft-and-local-presentation ()
  "Composer presentation stays local and never becomes prompt content."
  (with-temp-buffer
    (ogent-armory-compose-mode)
    (setq ogent-armory-compose--agent "cto")
    (insert "Inspect @agent:cto and explain the next step.")
    (let ((before (buffer-string)))
      (should (string-match-p "cto" (eval (cadr header-line-format) t)))
      (should (string-match-p "C-c C-c:submit" (eval (cadr header-line-format) t)))
      (should (equal before (buffer-string)))
      (should-not truncate-lines))))

(ert-deftest ogent-ui-layout-section-fontification-preserves-semantic-faces ()
  "Section fontification must not erase semantic status and title faces."
  (with-temp-buffer
    (ogent-section-mode)
    (ogent-section-configure-buffer)
    (let ((inhibit-read-only t))
      (insert (propertize "FAILED" 'face 'ogent-theme-error)))
    (funcall font-lock-unfontify-region-function (point-min) (point-max))
    (should (eq (get-text-property (point-min) 'face) 'ogent-theme-error))
    (should-not truncate-partial-width-windows)))

(provide 'ogent-ui-layout-tests)
;;; ogent-ui-layout-tests.el ends here

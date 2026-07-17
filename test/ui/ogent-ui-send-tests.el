;;; ogent-ui-send-tests.el --- Tests for ogent-ui-send fan-out -*- lexical-binding: t; -*-

;;; Commentary:
;; Covers `ogent-fanout' group orchestration (bead ogent-pje.1): one
;; shared Request block with per-member Response sibling headlines,
;; interleaved streaming isolation, fan-out group ids on analytics
;; records, failover suppression for group members, and the
;; single-member degenerate case matching `ogent-request'.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-context)
(require 'ogent-analytics)
(require 'cl-lib)

(defconst ogent-ui-send-tests--registry
  '((:id "test-model-1" :backend gptel-openai)
    (:id "test-model-2" :backend gptel-anthropic))
  "Two-provider registry used by the fan-out tests.")

(defun ogent-ui-send-tests--goto-details ()
  "Move point to the Details Block heading of the fixture."
  (goto-char (point-min))
  (search-forward "Details Block")
  (org-back-to-heading t))

(defun ogent-ui-send-tests--response-sections ()
  "Return an alist of (MODEL-ID . BODY) for every Response headline.
BODY is the trimmed text between the headline and the next heading."
  (let (sections)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ Response (\\([^)]+\\))$" nil t)
        (let* ((model (match-string-no-properties 1))
               (start (line-beginning-position 2))
               (end (save-excursion
                      (if (re-search-forward org-outline-regexp-bol nil t)
                          (match-beginning 0)
                        (point-max)))))
          (push (cons model (string-trim
                             (buffer-substring-no-properties start end)))
                sections))))
    (nreverse sections)))

(defun ogent-ui-send-tests--count-matches (regexp)
  "Return the number of REGEXP matches in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward regexp nil t)
        (setq count (1+ count)))
      count)))

(defun ogent-ui-send-tests--normalized-transcript ()
  "Return the buffer text normalized for latency and fan-out group."
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (setq text (replace-regexp-in-string ":latency [0-9.]+s" ":latency X" text))
    (replace-regexp-in-string ":OGENT_FANOUT_GROUP: [^\n]*\n" "" text)))

(ert-deftest ogent-fanout-shares-one-request-block ()
  "Fan-out members share one Request block with sibling Response headlines."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (group nil))
       (ogent-test-with-mock-gptel
         (setq group (ogent-fanout "Fanout prompt"
                                   '("test-model-1" "test-model-2")))
         (should (stringp group))
         (should (= 2 (ogent-test-request-count)))
         ;; One Request block for the whole group.
         (should (= 1 (ogent-ui-send-tests--count-matches
                       "^\\*+ Request: Fanout prompt")))
         (should (= 1 (ogent-ui-send-tests--count-matches
                       "^#\\+begin_src text :model test-model-1")))
         (should (= 0 (ogent-ui-send-tests--count-matches
                       "^#\\+begin_src text :model test-model-2")))
         ;; The block records the fan-out group id.
         (should (= 1 (ogent-ui-send-tests--count-matches
                       (concat "^:OGENT_FANOUT_GROUP: "
                               (regexp-quote group) "$"))))
         ;; One Response sibling per member, each with its response.
         (should (= 1 (ogent-ui-send-tests--count-matches
                       "^\\*+ Response (test-model-1)$")))
         (should (= 1 (ogent-ui-send-tests--count-matches
                       "^\\*+ Response (test-model-2)$")))
         (let ((sections (ogent-ui-send-tests--response-sections)))
           (should (equal (cdr (assoc "test-model-1" sections))
                          "Mock response"))
           (should (equal (cdr (assoc "test-model-2" sections))
                          "Mock response")))
         ;; The shared header keeps the first member's model and closes
         ;; done; no member rewrites it to its own id.
         (should (string-match-p
                  "#\\+begin_src text :model test-model-1 :backend gptel-openai :status done"
                  (buffer-string))))))))

(ert-deftest ogent-fanout-interleaved-streams-stay-isolated ()
  "Interleaved member callbacks route chunks without cross-contamination."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (callbacks nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (push (plist-get args :callback) callbacks)
                    'mock-request)))
         (let ((group (ogent-fanout "Fanout prompt"
                                    '("test-model-1" "test-model-2"))))
           (should (= 2 (length callbacks)))
           ;; Every member's live request context carries the group id.
           (let ((groups (delq nil
                               (mapcar
                                (lambda (request)
                                  (plist-get
                                   (ogent-ui-request-context request)
                                   :fanout-group))
                                (ogent-ui-active-requests)))))
             (should (equal groups (list group group)))))
         ;; `push' reverses: nth 1 is the first-dispatched member.
         (let ((cb1 (nth 1 callbacks))
               (cb2 (nth 0 callbacks)))
           (funcall cb1 "alpha-one " nil)
           (funcall cb2 "beta-one " nil)
           (funcall cb1 "alpha-two" nil)
           (funcall cb2 "beta-two" nil)
           (funcall cb2 nil '(:done t))
           (funcall cb1 nil '(:done t)))
         (let ((sections (ogent-ui-send-tests--response-sections)))
           (should (equal (cdr (assoc "test-model-1" sections))
                          "alpha-one alpha-two"))
           (should (equal (cdr (assoc "test-model-2" sections))
                          "beta-one beta-two"))))))))

(ert-deftest ogent-fanout-tags-analytics-records-with-group ()
  "Every member's analytics record carries the shared fan-out group id."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (recorded nil))
       (cl-letf (((symbol-function 'ogent-analytics-record-completion)
                  (lambda (&rest args) (push args recorded))))
         (ogent-test-with-mock-gptel
           (let ((group (ogent-fanout "Fanout prompt"
                                      '("test-model-1" "test-model-2"))))
             (should (= 2 (length recorded)))
             (dolist (args recorded)
               (should (equal (plist-get (nthcdr 4 args) :fanout-group)
                              group)))
             (should (equal (sort (mapcar #'car recorded) #'string<)
                            '("test-model-1" "test-model-2"))))))))))

(ert-deftest ogent-request-analytics-record-stays-untagged ()
  "A plain request records exactly the four historical analytics args."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((recorded nil))
       (cl-letf (((symbol-function 'ogent-analytics-record-completion)
                  (lambda (&rest args) (push args recorded))))
         (ogent-test-with-mock-gptel
           (ogent-request "Solo prompt" '("gpt-4o-mini"))
           (should (= 1 (length recorded)))
           (should (= 4 (length (car recorded))))
           (should (equal (caar recorded) "gpt-4o-mini"))))))))

(ert-deftest ogent-fanout-single-member-degenerates-to-request ()
  "A single-member fan-out produces the same transcript as `ogent-request'."
  (let ((baseline nil)
        (fanout nil))
    (ogent-test-with-fixture
     "data/fixture.org"
     (lambda ()
       (ogent-ui-send-tests--goto-details)
       (ogent-test-with-mock-gptel
         (ogent-request "Solo prompt" '("gpt-4o-mini"))
         (should (= 1 (ogent-test-request-count))))
       (setq baseline (ogent-ui-send-tests--normalized-transcript))))
    (ogent-test-with-fixture
     "data/fixture.org"
     (lambda ()
       (ogent-ui-send-tests--goto-details)
       (ogent-test-with-mock-gptel
         (should (stringp (ogent-fanout "Solo prompt" '("gpt-4o-mini"))))
         (should (= 1 (ogent-test-request-count))))
       (setq fanout (ogent-ui-send-tests--normalized-transcript))))
    (should (equal fanout baseline))))

(ert-deftest ogent-fanout-member-failure-skips-provider-failover ()
  "A failing member is still classified but never retried or failed over."
  (let* ((actions nil)
         (schedules nil)
         (real-handle (symbol-function 'ogent-provider-handle-error)))
    (cl-letf (((symbol-function 'ogent-provider-handle-error)
               (lambda (context)
                 (let ((action (funcall real-handle context)))
                   (push action actions)
                   action)))
              ((symbol-function 'ogent-provider--schedule-retry)
               (lambda (&rest args) (push (cons 'retry args) schedules)))
              ((symbol-function 'ogent-provider--schedule-failover)
               (lambda (&rest args) (push (cons 'failover args) schedules)))
              ((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (when-let ((callback (plist-get args :callback)))
                   (funcall callback nil '(:error "rate limit exceeded")))
                 'mock-request)))
      (let ((ogent-model-registry ogent-ui-send-tests--registry)
            (ogent-ui--error-history nil))
        ;; Control: the same transient failure outside a fan-out enters
        ;; the retry branch.
        (ogent-test-with-fixture
         "data/fixture.org"
         (lambda ()
           (ogent-ui-send-tests--goto-details)
           (ogent-request "Control prompt" '("test-model-1"))))
        (should (equal actions '(retry)))
        (should (= 1 (length schedules)))
        (setq actions nil
              schedules nil
              ogent-ui--error-history nil)
        ;; Fan-out members: classification still runs, but no retry or
        ;; failover is ever scheduled and no recovery state is shown.
        (ogent-test-with-fixture
         "data/fixture.org"
         (lambda ()
           (ogent-ui-send-tests--goto-details)
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
           (should-not (string-match-p "retrying\\|failed over"
                                       (buffer-string)))))
        (should (equal actions '(give-up give-up)))
        (should-not schedules)
        (should (= 2 (length ogent-ui--error-history)))))))

(ert-deftest ogent-fanout-builds-context-once ()
  "Fan-out builds the companion context exactly once for all members."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (builds 0)
           (real-build (symbol-function 'ogent-context-build-with-source)))
       (cl-letf (((symbol-function 'ogent-context-build-with-source)
                  (lambda (&rest args)
                    (setq builds (1+ builds))
                    (apply real-build args))))
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
           (should (= 2 (ogent-test-request-count)))
           (should (= 1 builds))))))))

(ert-deftest ogent-fanout-model-set-resolution-order ()
  "Explicit arg beats selection, defcustom, and the role fallback."
  (let ((ogent-ui--selected-models '("sel-a"))
        (ogent-fanout-models '("cust-b")))
    (should (equal (ogent-fanout--model-set '("arg-c")) '("arg-c")))
    (should (equal (ogent-fanout--model-set) '("sel-a")))
    (let ((ogent-ui--selected-models nil))
      (should (equal (ogent-fanout--model-set) '("cust-b")))
      (let* ((ogent-fanout-models nil)
             (ogent-model-registry '((:id "model-x" :backend prov-a)
                                     (:id "model-y" :backend prov-b)))
             (ogent-default-model "model-x")
             (ogent-model-roles '((fast . "model-y")
                                  (deep . "model-x")
                                  (codemap . fast)))
             (members (ogent-fanout--model-set)))
        ;; The role fallback yields distinct registered model ids.
        (should members)
        (should (equal members (delete-dups (copy-sequence members))))
        (dolist (id members)
          (should (member id '("model-x" "model-y"))))
        (should (member "model-y" members))))))

(provide 'ogent-ui-send-tests)

;;; ogent-ui-send-tests.el ends here

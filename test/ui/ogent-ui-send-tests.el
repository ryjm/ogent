;;; ogent-ui-send-tests.el --- Tests for ogent-ui-send fan-out -*- lexical-binding: t; -*-

;;; Commentary:
;; Covers `ogent-fanout' group orchestration (bead ogent-pje.1): one
;; shared Request block with per-member Response sibling headlines,
;; interleaved streaming isolation, fan-out group ids on analytics
;; records, failover suppression for group members, and the
;; single-member degenerate case matching `ogent-request'.  Also the
;; model-set selection UX (bead ogent-pje.2): alias canonicalization,
;; duplicate/empty-set rejection, source precedence, and the C-u
;; completion prompt.  And the group lifecycle (bead ogent-pje.3):
;; per-member header chips, group abort, watchdog isolation, and
;; `ogent-fanout-group-done-hook'.
;; Plus compare mode (bead ogent-pje.4): pairwise ediff of member
;; bodies, `ogent-fanout-keep' ARCHIVE marking, and the fboundp-guarded
;; rating interplay.  And the persisted-tagging proof (bead
;; ogent-pje.5): the transcript's OGENT_FANOUT_GROUP drawer property
;; and the DB fanout_group column stay a working join key through the
;; real recorder.

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

(defun ogent-ui-send-tests--request-header ()
  "Return the shared Request src block header line."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^#\\+begin_src text :model [^\n]*$")
    (match-string-no-properties 0)))

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
        (ogent-fanout-default-models '("cust-b")))
    (should (equal (ogent-fanout--model-set '("arg-c")) '("arg-c")))
    (should (equal (ogent-fanout--model-set) '("sel-a")))
    (let ((ogent-ui--selected-models nil))
      (should (equal (ogent-fanout--model-set) '("cust-b")))
      (let* ((ogent-fanout-default-models nil)
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

;;; Model-set selection UX (bead ogent-pje.2)

(ert-deftest ogent-fanout-resolve-canonicalizes-aliases ()
  "Aliases and @role designators canonicalize to registry ids."
  (let ((ogent-model-registry
         '((:id "model-canonical" :backend prov-a :aliases ("model-nick"))
           (:id "model-two" :backend prov-b)))
        (ogent-default-model "model-two")
        (ogent-model-roles '((fast . "model-canonical"))))
    (should (equal (ogent-fanout--resolve-model-set
                    '("model-nick" "model-two"))
                   '("model-canonical" "model-two")))
    ;; An @role designator resolves through the role table.
    (should (equal (ogent-fanout--resolve-model-set '("@fast"))
                   '("model-canonical")))
    ;; A member naming no registered model is refused.
    (let ((err (should-error (ogent-fanout--resolve-model-set '("nope"))
                             :type 'user-error)))
      (should (string-match-p "Unknown fan-out model" (cadr err)))
      (should (string-match-p "nope" (cadr err))))))

(ert-deftest ogent-fanout-resolve-rejects-duplicates ()
  "Two designators resolving to one model are refused after canonicalization."
  (let ((ogent-model-registry
         '((:id "model-canonical" :backend prov-a :aliases ("model-nick")))))
    (let ((err (should-error (ogent-fanout--resolve-model-set
                              '("model-canonical" "model-nick"))
                             :type 'user-error)))
      (should (string-match-p "Duplicate fan-out model" (cadr err)))
      (should (string-match-p "model-canonical" (cadr err))))))

(ert-deftest ogent-fanout-resolve-precedence-canonicalizes-every-source ()
  "Explicit arg beats selection and defcustom; each source canonicalizes."
  (let ((ogent-model-registry
         '((:id "model-canonical" :backend prov-a :aliases ("model-nick"))
           (:id "model-two" :backend prov-b :aliases ("two-nick"))))
        (ogent-ui--selected-models '("two-nick"))
        (ogent-fanout-default-models '("model-nick")))
    ;; The explicit argument wins and canonicalizes.
    (should (equal (ogent-fanout--resolve-model-set '("model-nick"))
                   '("model-canonical")))
    ;; The live dispatcher selection beats the defcustom.
    (should (equal (ogent-fanout--resolve-model-set) '("model-two")))
    ;; The defcustom is next once the selection clears.
    (let ((ogent-ui--selected-models nil))
      (should (equal (ogent-fanout--resolve-model-set)
                     '("model-canonical"))))))

(ert-deftest ogent-fanout-empty-set-error-names-sources ()
  "The empty-set error names all three selection sources."
  (let ((ogent-model-registry nil)
        (ogent-ui--selected-models nil)
        (ogent-fanout-default-models nil))
    (let* ((err (should-error (ogent-fanout--resolve-model-set)
                              :type 'user-error))
           (message (cadr err)))
      (should (string-match-p "C-u" message))
      (should (string-match-p "ogent-fanout-default-models" message))
      (should (string-match-p "ogent-model-roles" message)))))

(ert-deftest ogent-fanout-prefix-arg-prompts-with-completion ()
  "A prefix arg reads the member set over registry ids and canonicalizes."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry
            '((:id "model-canonical" :backend gptel-openai
                   :aliases ("model-nick"))))
           (ogent-ui--selected-models nil)
           (crm-collection nil))
       (cl-letf (((symbol-function 'completing-read-multiple)
                  (lambda (_prompt collection &rest _)
                    (setq crm-collection collection)
                    '("model-nick")))
                 ((symbol-function 'ogent-ui--read-prompt)
                  (lambda () "Prefix prompt")))
         (ogent-test-with-mock-gptel
           (let ((current-prefix-arg '(4)))
             (call-interactively #'ogent-fanout))
           ;; Completion ran over the registry ids, and the alias the
           ;; user picked dispatched as the canonical model.
           (should (equal crm-collection '("model-canonical")))
           (should (= 1 (ogent-test-request-count)))
           (should (= 1 (ogent-ui-send-tests--count-matches
                         "^#\\+begin_src text :model model-canonical")))))))))

;;; Group lifecycle: chips, abort, watchdog, done hook (bead ogent-pje.3)

(ert-deftest ogent-fanout-header-chips-track-interleaved-completions ()
  "Per-member chips move through streaming, done, and failed states."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-ui--error-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (callbacks nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (push (plist-get args :callback) callbacks)
                    'mock-request)))
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
         ;; `push' reverses: nth 1 is the first-dispatched member.
         (let ((cb1 (nth 1 callbacks))
               (cb2 (nth 0 callbacks)))
           ;; First chunk rewrites the header with one chip per member.
           (funcall cb2 "beta" nil)
           (should (string-match-p
                    (concat ":status streaming"
                            " :members test-model-1=streaming,"
                            "test-model-2=streaming")
                    (ogent-ui-send-tests--request-header)))
           ;; Member 2 finishes while member 1 still streams.
           (funcall cb2 nil '(:done t))
           (should (string-match-p
                    (concat ":status streaming"
                            " :members test-model-1=streaming,"
                            "test-model-2=done")
                    (ogent-ui-send-tests--request-header)))
           ;; Member 1 fails: its chip flips to failed, the aggregate
           ;; to error, and the done sibling is untouched.
           (funcall cb1 nil '(:error "server exploded"))
           (should (string-match-p
                    (concat ":status error"
                            " :members test-model-1=failed,"
                            "test-model-2=done")
                    (ogent-ui-send-tests--request-header)))
           (let ((sections (ogent-ui-send-tests--response-sections)))
             ;; The failed member shows the classified error in its own
             ;; sibling body, same block format as single requests.
             (should (string-match-p "#\\+begin_quote ogent-error"
                                     (cdr (assoc "test-model-1" sections))))
             (should (equal (cdr (assoc "test-model-2" sections))
                            "beta")))))))))

(ert-deftest ogent-fanout-abort-leaves-done-members-intact ()
  "Group abort marks in-flight members aborted and keeps done ones."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (callbacks nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (push (plist-get args :callback) callbacks)
                    'mock-request)))
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
         (let ((cb1 (nth 1 callbacks))
               (req2 (car (seq-filter
                           (lambda (request)
                             (equal (plist-get (ogent-ui-request-model request)
                                               :id)
                                    "test-model-2"))
                           (ogent-ui-active-requests))))
               (watchdog nil))
           ;; Member 1 completes before the abort.
           (funcall cb1 "alpha" nil)
           (funcall cb1 nil '(:done t))
           (should req2)
           (setq watchdog (ogent-ui-request-watchdog req2))
           (should (timerp watchdog))
           ;; Abort the group from inside the Request subtree.
           (goto-char (point-min))
           (search-forward "Request: Fanout prompt")
           (should (= 1 (ogent-fanout-abort)))
           ;; The done member's response survives; the in-flight member
           ;; is aborted through the normal abort path.
           (let ((sections (ogent-ui-send-tests--response-sections)))
             (should (equal (cdr (assoc "test-model-1" sections)) "alpha"))
             (should (string-match-p "Request aborted by user"
                                     (cdr (assoc "test-model-2" sections)))))
           (should (string-match-p
                    (concat ":status aborted"
                            " :members test-model-1=done,"
                            "test-model-2=aborted")
                    (ogent-ui-send-tests--request-header)))
           ;; The aborted member's watchdog is cancelled, and no active
           ;; request survives the abort.
           (should-not (ogent-ui-request-watchdog req2))
           (should-not (memq watchdog timer-list))
           (should-not (ogent-ui-active-requests))))))))

(ert-deftest ogent-fanout-watchdog-timeout-leaves-siblings-alone ()
  "One member's watchdog timeout never disturbs its group siblings."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-ui--error-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (calls nil)
           (callbacks nil)
           (group nil))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (group-id results)
                      (push (cons group-id results) calls)))))
         (cl-letf (((symbol-function 'gptel-request)
                    (lambda (_prompt &rest args)
                      (push (plist-get args :callback) callbacks)
                      'mock-request)))
           (setq group (ogent-fanout "Fanout prompt"
                                     '("test-model-1" "test-model-2")))
           (let* ((cb2 (nth 0 callbacks))
                  (requests (ogent-ui-active-requests))
                  (req1 (car (seq-filter
                              (lambda (request)
                                (equal (plist-get
                                        (ogent-ui-request-model request) :id)
                                       "test-model-1"))
                              requests)))
                  (req2 (car (seq-filter
                              (lambda (request)
                                (equal (plist-get
                                        (ogent-ui-request-model request) :id)
                                       "test-model-2"))
                              requests))))
             (funcall cb2 "beta" nil)
             ;; Member 1 stalls out.
             (ogent-ui--watchdog-timeout (ogent-ui-request-id req1))
             (should (ogent-ui-request-closed req1))
             ;; Member 2 keeps streaming, untouched.
             (should (memq req2 (ogent-ui-active-requests)))
             (should (string-match-p
                      (concat ":status streaming"
                              " :members test-model-1=failed,"
                              "test-model-2=streaming")
                      (ogent-ui-send-tests--request-header)))
             (should-not calls)
             ;; Member 2 finishes normally; the group closes with the
             ;; timed-out member marked failed.
             (funcall cb2 nil '(:done t))
             (should (= 1 (length calls)))
             (let ((results (cdr (car calls))))
               (should (equal (car (car calls)) group))
               (should (equal (mapcar (lambda (r) (cons (car r) (cadr r)))
                                      results)
                              '(("test-model-1" . failed)
                                ("test-model-2" . done)))))
             (let ((sections (ogent-ui-send-tests--response-sections)))
               (should (string-match-p "timed out"
                                       (cdr (assoc "test-model-1" sections))))
               (should (equal (cdr (assoc "test-model-2" sections))
                              "beta"))))))))))

(ert-deftest ogent-fanout-group-done-hook-fires-once-with-results ()
  "The done hook fires exactly once, after the final terminal transition."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (calls nil)
           (callbacks nil)
           (group nil))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (group-id results)
                      (push (cons group-id results) calls)))))
         (cl-letf (((symbol-function 'gptel-request)
                    (lambda (_prompt &rest args)
                      (push (plist-get args :callback) callbacks)
                      'mock-request)))
           (setq group (ogent-fanout "Fanout prompt"
                                     '("test-model-1" "test-model-2")))
           (let ((cb1 (nth 1 callbacks))
                 (cb2 (nth 0 callbacks)))
             (funcall cb1 "alpha" nil)
             (funcall cb1 nil '(:done t))
             ;; Not yet: one member is still in flight.
             (should-not calls)
             (funcall cb2 "beta" nil)
             (funcall cb2 nil '(:done t))
             (should (= 1 (length calls)))
             (let* ((call (car calls))
                    (results (cdr call)))
               (should (equal (car call) group))
               (should (equal (mapcar #'car results)
                              '("test-model-1" "test-model-2")))
               (should (equal (mapcar #'cadr results) '(done done)))
               ;; Each result carries the member's live response marker.
               (dolist (result results)
                 (let ((marker (cddr result)))
                   (should (markerp marker))
                   (should (eq (marker-buffer marker) (current-buffer))))))
             ;; Both tables drain to zero: no zombie rows.
             (should (= 0 (hash-table-count ogent-ui--request-table)))
             (should (= 0 (hash-table-count ogent-ui--fanout-groups))))))))))

(ert-deftest ogent-fanout-group-done-hook-error-keeps-tables-clean ()
  "A throwing done hook never blocks request or group table cleanup."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (fired 0))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (_group _results)
                      (setq fired (1+ fired))
                      (error "hook exploded")))))
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
           (should (= 1 fired))
           (should (= 0 (hash-table-count ogent-ui--request-table)))
           (should (= 0 (hash-table-count ogent-ui--fanout-groups)))
           ;; The transcript still closed both members as done.
           (should (string-match-p
                    ":status done :members test-model-1=done,test-model-2=done"
                    (ogent-ui-send-tests--request-header)))))))))

;;; Group settlement on aborted dispatch (pje.3 follow-up)

(defconst ogent-ui-send-tests--three-model-registry
  '((:id "test-model-1" :backend gptel-openai)
    (:id "test-model-2" :backend gptel-anthropic)
    (:id "test-model-3" :backend gptel-openai))
  "Three-provider registry for mid-loop dispatch failure tests.")

(ert-deftest ogent-fanout-quit-at-confirmation-leaves-no-group ()
  "A quit at the send confirmation drops the group entry entirely."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-model-registry ogent-ui-send-tests--registry)
           (fired 0)
           (quitted nil))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (_group _results) (setq fired (1+ fired))))))
         (cl-letf (((symbol-function 'ogent-validate-and-prompt)
                    (lambda (_context) (signal 'quit nil)))
                   ((symbol-function 'gptel-request)
                    (lambda (&rest _) (error "Must not dispatch"))))
           (condition-case nil
               (ogent-fanout "Fanout prompt"
                             '("test-model-1" "test-model-2"))
             (quit (setq quitted t)))
           (should quitted)
           ;; No member dispatched: no group state, no hook, no rows.
           (should (= 0 (hash-table-count ogent-ui--fanout-groups)))
           (should (= 0 (hash-table-count ogent-ui--request-table)))
           (should (= 0 fired))))))))

(ert-deftest ogent-fanout-validation-cancel-leaves-no-group ()
  "Context validation returning nil leaves no group entry and no hook."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-model-registry ogent-ui-send-tests--registry)
           (fired 0))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (_group _results) (setq fired (1+ fired))))))
         (cl-letf (((symbol-function 'ogent-validate-and-prompt)
                    (lambda (_context) nil))
                   ((symbol-function 'gptel-request)
                    (lambda (&rest _) (error "Must not dispatch"))))
           ;; Returns normally: the dispatch was canceled, not signaled.
           (should (stringp (ogent-fanout "Fanout prompt"
                                          '("test-model-1" "test-model-2"))))
           (should (= 0 (hash-table-count ogent-ui--fanout-groups)))
           (should (= 0 (hash-table-count ogent-ui--request-table)))
           (should (= 0 fired))))))))

(ert-deftest ogent-fanout-mid-loop-signal-settles-undispatched-members ()
  "A mid-loop signal fails the undispatched members, sparing the live one."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--three-model-registry)
           (real-ensure (symbol-function 'ogent-models-ensure))
           (calls nil)
           (callbacks nil)
           (group nil)
           (erred nil))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (group-id results)
                      (push (cons group-id results) calls)))))
         (cl-letf (((symbol-function 'ogent-models-ensure)
                    (lambda (model-id)
                      (if (equal model-id "test-model-2")
                          (user-error "Registry lookup exploded")
                        (funcall real-ensure model-id))))
                   ((symbol-function 'gptel-request)
                    (lambda (_prompt &rest args)
                      (push (plist-get args :callback) callbacks)
                      'mock-request)))
           (condition-case nil
               (ogent-fanout "Fanout prompt"
                             '("test-model-1" "test-model-2" "test-model-3"))
             (error (setq erred t)))
           (should erred)
           ;; Member 1 dispatched and lives on; members 2-3 settled as
           ;; failed, so the group entry survives with member 1 pending.
           (should (= 1 (length callbacks)))
           (should (= 1 (length (ogent-ui-active-requests))))
           (should (= 1 (hash-table-count ogent-ui--fanout-groups)))
           (should-not calls)
           (setq group (car (hash-table-keys ogent-ui--fanout-groups)))
           ;; Member 1 completes: the group finishes, the hook reports
           ;; the settled members failed with no response marker, and
           ;; both tables drain.
           (funcall (car callbacks) "alpha" nil)
           (funcall (car callbacks) nil '(:done t))
           (should (= 1 (length calls)))
           (let ((results (cdr (car calls))))
             (should (equal (car (car calls)) group))
             (should (equal (mapcar (lambda (r) (cons (car r) (cadr r)))
                                    results)
                            '(("test-model-1" . done)
                              ("test-model-2" . failed)
                              ("test-model-3" . failed))))
             (should (markerp (cddr (nth 0 results))))
             (should-not (cddr (nth 1 results)))
             (should-not (cddr (nth 2 results))))
           (should (= 0 (hash-table-count ogent-ui--request-table)))
           (should (= 0 (hash-table-count ogent-ui--fanout-groups)))))))))

(ert-deftest ogent-fanout-mid-loop-signal-after-synchronous-member-finishes ()
  "Settling the stragglers finishes a group whose live member already closed."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--three-model-registry)
           (real-ensure (symbol-function 'ogent-models-ensure))
           (calls nil)
           (erred nil))
       (let ((ogent-fanout-group-done-hook
              (list (lambda (group-id results)
                      (push (cons group-id results) calls)))))
         (cl-letf (((symbol-function 'ogent-models-ensure)
                    (lambda (model-id)
                      (if (equal model-id "test-model-2")
                          (user-error "Registry lookup exploded")
                        (funcall real-ensure model-id)))))
           ;; The mock completes member 1 synchronously, so the group's
           ;; last outstanding state is settled by the unwind path.
           (ogent-test-with-mock-gptel
             (condition-case nil
                 (ogent-fanout "Fanout prompt"
                               '("test-model-1" "test-model-2"
                                 "test-model-3"))
               (error (setq erred t)))
             (should erred)
             (should (= 1 (length calls)))
             (should (equal (mapcar (lambda (r) (cons (car r) (cadr r)))
                                    (cdr (car calls)))
                            '(("test-model-1" . done)
                              ("test-model-2" . failed)
                              ("test-model-3" . failed))))
             (should (= 0 (hash-table-count ogent-ui--request-table)))
             (should (= 0 (hash-table-count ogent-ui--fanout-groups))))))))))

;;; Real-Recorder Persistence Tests (bead ogent-z0k.3, moved from ogent-pje.1)

(ert-deftest ogent-fanout-persists-group-rows-through-real-recorder ()
  "A stubbed-gptel fan-out lands N tagged rows via the real recorder.
End-to-end (beads ogent-z0k.3 + ogent-pje.5): `ogent-fanout'
dispatches through the mock gptel, request close runs the real
`ogent-analytics-record-completion' into an in-memory database, every
member row carries the shared group id, a plain request's row keeps a
NULL fanout_group, and the group id matches the transcript's
OGENT_FANOUT_GROUP drawer property, so the buffer<->DB join key holds."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (ogent-analytics--pending-completion nil)
           (ogent-analytics--request-start-time nil)
           (ogent-analytics--first-token-time nil)
           (group nil))
       (ogent-test-with-real-store 'analytics
         (ogent-test-with-mock-gptel
           (setq group (ogent-fanout "Fanout prompt"
                                     '("test-model-1" "test-model-2")))
           (ogent-request "Solo prompt" '("test-model-1")))
         (should (stringp group))
         (should (equal (sqlite-select
                         (ogent-analytics--get-db)
                         "SELECT model, fanout_group FROM completions ORDER BY id")
                        (list (list "test-model-1" group)
                              (list "test-model-2" group)
                              (list "test-model-1" nil))))
         ;; Buffer<->DB join key (bead ogent-pje.5): the group id in
         ;; the drawer is byte-for-byte the fanout_group the member
         ;; rows carry, so either side can find the other.
         (goto-char (point-min))
         (re-search-forward "^\\*+ Request: Fanout prompt")
         (let ((drawer (org-entry-get (point) "OGENT_FANOUT_GROUP")))
           (should (equal drawer group))
           (should (equal (sqlite-select
                           (ogent-analytics--get-db)
                           "SELECT DISTINCT fanout_group FROM completions WHERE fanout_group IS NOT NULL")
                          (list (list drawer))))))))))

(ert-deftest ogent-request-stamps-completion-id-into-drawer ()
  "A plain request's block drawer gains OGENT_COMPLETION_ID at record time."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (ogent-analytics--pending-completion nil)
           (ogent-analytics--request-start-time nil)
           (ogent-analytics--first-token-time nil))
       (ogent-test-with-real-store 'analytics
         (ogent-test-with-mock-gptel
           (ogent-request "Solo prompt" '("test-model-1")))
         (let ((id (caar (sqlite-select (ogent-analytics--get-db)
                                        "SELECT id FROM completions"))))
           (should id)
           (goto-char (point-min))
           (should (search-forward
                    (format ":OGENT_COMPLETION_ID: %d" id) nil t))
           ;; The rating action resolves the id from the Response
           ;; headline through property inheritance.
           (re-search-forward "^\\*+ Response (test-model-1)$")
           (beginning-of-line)
           (should (= (ogent-analytics--completion-id-at-point) id))))))))

(ert-deftest ogent-fanout-stamps-per-member-completion-ids ()
  "Fan-out members carry their own row ids on their Response headlines.
The group shares one Request headline, so per-member ids must live on
the member Response headlines to stay distinct and rateable."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (ogent-analytics--pending-completion nil)
           (ogent-analytics--request-start-time nil)
           (ogent-analytics--first-token-time nil))
       (ogent-test-with-real-store 'analytics
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
         (let ((rows (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT id, model FROM completions ORDER BY id")))
           (should (= 2 (length rows)))
           (dolist (row rows)
             (goto-char (point-min))
             (re-search-forward (format "^\\*+ Response (%s)$"
                                        (regexp-quote (nth 1 row))))
             (beginning-of-line)
             (should (= (ogent-analytics--completion-id-at-point)
                        (car row))))))))))

;;; Compare mode: pairwise ediff and keep-this-one (bead ogent-pje.4)

(defun ogent-ui-send-tests--goto-response (model)
  "Move point to the beginning of MODEL's Response headline."
  (goto-char (point-min))
  (re-search-forward (format "^\\*+ Response (%s)" (regexp-quote model)))
  (beginning-of-line))

(defun ogent-ui-send-tests--archived-p (model)
  "Return non-nil when MODEL's Response headline carries the ARCHIVE tag."
  (save-excursion
    (ogent-ui-send-tests--goto-response model)
    (member org-archive-tag (org-get-tags nil t))))

(ert-deftest ogent-fanout-compare-ediffs-member-bodies ()
  "Compare hands the two rendered member bodies to `ediff-buffers'.
A two-member group implies the pair; each body lands verbatim in a
fresh plain-text buffer named for its model, and the transcript
itself is untouched."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (callbacks nil)
           (compared nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (push (plist-get args :callback) callbacks)
                    'mock-request))
                 ((symbol-function 'ediff-buffers)
                  (lambda (buffer-a buffer-b &rest _)
                    (setq compared (list buffer-a buffer-b)))))
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
         ;; `push' reverses: nth 1 is the first-dispatched member.
         (funcall (nth 1 callbacks) "alpha body" nil)
         (funcall (nth 0 callbacks) "beta body" nil)
         (funcall (nth 1 callbacks) nil '(:done t))
         (funcall (nth 0 callbacks) nil '(:done t))
         (unwind-protect
             (let ((before (buffer-string)))
               (ogent-ui-send-tests--goto-response "test-model-2")
               (ogent-fanout-compare)
               (should (equal (buffer-string) before))
               (should (= 2 (length compared)))
               (should (string-match-p "test-model-1"
                                       (buffer-name (nth 0 compared))))
               (should (string-match-p "test-model-2"
                                       (buffer-name (nth 1 compared))))
               (should (equal (with-current-buffer (nth 0 compared)
                                (buffer-string))
                              "alpha body"))
               (should (equal (with-current-buffer (nth 1 compared)
                                (buffer-string))
                              "beta body")))
           (dolist (buffer compared)
             (when (buffer-live-p buffer)
               (kill-buffer buffer)))))))))

(ert-deftest ogent-fanout-compare-reads-pair-on-larger-groups ()
  "A three-member group reads the compare pair with completion.
The second prompt's collection excludes the first pick, so the pair
can never degenerate into diffing a member against itself."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--three-model-registry)
           (collections nil)
           (compared nil))
       (ogent-test-with-mock-gptel
         (ogent-fanout "Fanout prompt"
                       '("test-model-1" "test-model-2" "test-model-3")))
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (_prompt collection &rest _)
                    (push (copy-sequence collection) collections)
                    (if (member "test-model-3" collection)
                        "test-model-3"
                      "test-model-1")))
                 ((symbol-function 'ediff-buffers)
                  (lambda (buffer-a buffer-b &rest _)
                    (setq compared (list buffer-a buffer-b)))))
         (unwind-protect
             (progn
               (ogent-ui-send-tests--goto-response "test-model-1")
               (ogent-fanout-compare)
               (should (= 2 (length collections)))
               ;; First prompt offers every member; the second drops
               ;; the first pick.
               (should (equal (nth 1 collections)
                              '("test-model-1" "test-model-2"
                                "test-model-3")))
               (should (equal (nth 0 collections)
                              '("test-model-1" "test-model-2")))
               (should (string-match-p "test-model-3"
                                       (buffer-name (nth 0 compared))))
               (should (string-match-p "test-model-1"
                                       (buffer-name (nth 1 compared)))))
           (dolist (buffer compared)
             (when (buffer-live-p buffer)
               (kill-buffer buffer)))))))))

(ert-deftest ogent-fanout-compare-refuses-streaming-group ()
  "Compare refuses a group that still has members in flight.
A partial body would diff as a regression that is not one."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (callbacks nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (push (plist-get args :callback) callbacks)
                    'mock-request))
                 ((symbol-function 'ediff-buffers)
                  (lambda (&rest _)
                    (error "ediff-buffers must not run on a live group"))))
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))
         (funcall (nth 1 callbacks) "alpha" nil)
         (funcall (nth 1 callbacks) nil '(:done t))
         ;; The second member is still streaming.
         (ogent-ui-send-tests--goto-response "test-model-1")
         (should-error (ogent-fanout-compare) :type 'user-error)
         ;; Finish the group so no live request leaks into the suite.
         (funcall (nth 0 callbacks) "beta" nil)
         (funcall (nth 0 callbacks) nil '(:done t))
         (should-not (ogent-ui-active-requests)))))))

(ert-deftest ogent-fanout-compare-cleans-up-variants-on-quit ()
  "Quitting ediff reaps the generated variant buffers, never the source.
Compare registers a buffer-local `ediff-after-quit-hook-internal' on
the ediff control buffer that kills exactly the two variants, so a
second compare after cleanup gets fresh buffers and repeated
comparisons never accumulate."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry)
           (transcript (current-buffer))
           (runs nil))
       (cl-letf (((symbol-function 'ediff-buffers)
                  (lambda (buffer-a buffer-b &optional startup-hooks _job)
                    ;; Emulate ediff setup: run the startup hooks in a
                    ;; fresh control buffer, as `ediff-setup' would.
                    (let ((control (generate-new-buffer
                                    " *ediff-control-stub*")))
                      (with-current-buffer control
                        (mapc #'funcall startup-hooks))
                      (push (list buffer-a buffer-b control) runs)))))
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
         (dotimes (_ 2)
           (ogent-ui-send-tests--goto-response "test-model-1")
           (ogent-fanout-compare)
           (pcase-let ((`(,buffer-a ,buffer-b ,control) (car runs)))
             (should (buffer-live-p buffer-a))
             (should (buffer-live-p buffer-b))
             ;; Quit the session: the buffer-local hook on the control
             ;; buffer kills exactly the two variants.
             (with-current-buffer control
               (run-hooks 'ediff-after-quit-hook-internal))
             (kill-buffer control)
             (should-not (buffer-live-p buffer-a))
             (should-not (buffer-live-p buffer-b))
             (should (buffer-live-p transcript))))
         ;; Two full compare/quit cycles ran; nothing accumulated.
         (should (= 2 (length runs)))
         (should-not (seq-filter
                      (lambda (buffer)
                        (string-prefix-p "*ogent fanout diff:"
                                         (buffer-name buffer)))
                      (buffer-list))))))))

(ert-deftest ogent-fanout-keep-archives-losers-only ()
  "Keep tags every losing sibling ARCHIVE and leaves the winner alone.
The marking is the org-native reversible archive tag; nothing moves
and nothing is deleted, and the shared Request heading stays clean."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry))
       (ogent-test-with-mock-gptel
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
       (ogent-ui-send-tests--goto-response "test-model-1")
       (should (equal (ogent-fanout-keep) "test-model-1"))
       (should-not (ogent-ui-send-tests--archived-p "test-model-1"))
       (should (ogent-ui-send-tests--archived-p "test-model-2"))
       ;; No response text moved or vanished; the loser's headline
       ;; merely gained a tag (which unanchors the section helper).
       (should (= 2 (ogent-ui-send-tests--count-matches
                     "^\\*+ Response (")))
       (should (= 2 (ogent-ui-send-tests--count-matches
                     "^Mock response$")))
       (save-excursion
         (goto-char (point-min))
         (re-search-forward "^\\*+ Request: Fanout prompt")
         (should-not (member org-archive-tag (org-get-tags nil t))))))))

(ert-deftest ogent-fanout-keep-rerun-swaps-marking ()
  "Re-running keep on another member swaps the ARCHIVE marking.
The gesture is fully reversible: the new winner loses its tag and the
old winner gains one."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry ogent-ui-send-tests--registry))
       (ogent-test-with-mock-gptel
         (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
       (ogent-ui-send-tests--goto-response "test-model-1")
       (ogent-fanout-keep)
       (ogent-ui-send-tests--goto-response "test-model-2")
       (should (equal (ogent-fanout-keep) "test-model-2"))
       (should (ogent-ui-send-tests--archived-p "test-model-1"))
       (should-not (ogent-ui-send-tests--archived-p "test-model-2"))))))

(ert-deftest ogent-fanout-keep-rates-winner-five ()
  "Keep records rating 5 for the winner's completion row, losers none.
The winner's OGENT_COMPLETION_ID (stamped by the real recorder)
resolves to its analytics row; exactly one rating call happens -- an
unpicked response is not evidence of badness."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (ogent-analytics--pending-completion nil)
           (ogent-analytics--request-start-time nil)
           (ogent-analytics--first-token-time nil)
           (rated nil))
       (ogent-test-with-real-store 'analytics
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
         (let ((winner-id
                (caar (sqlite-select
                       (ogent-analytics--get-db)
                       "SELECT id FROM completions WHERE model = 'test-model-2'"))))
           (should winner-id)
           (cl-letf (((symbol-function 'ogent-analytics-rate-completion)
                      (lambda (id rating) (push (list id rating) rated))))
             (ogent-ui-send-tests--goto-response "test-model-2")
             (ogent-fanout-keep))
           (should (equal rated (list (list winner-id 5))))))))))

(ert-deftest ogent-fanout-keep-skips-rating-without-pipeline ()
  "Without the rating pipeline, keep still archives and never errors.
The soft integration is fboundp-guarded: even with a completion id
stamped on the winner, an absent `ogent-analytics-rate-completion'
means no rating call and no void-function error."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-ui--request-table (make-hash-table :test #'equal))
           (ogent-ui--fanout-groups (make-hash-table :test #'equal))
           (ogent-ui--request-history nil)
           (ogent-model-registry ogent-ui-send-tests--registry)
           (ogent-analytics--pending-completion nil)
           (ogent-analytics--request-start-time nil)
           (ogent-analytics--first-token-time nil))
       (ogent-test-with-real-store 'analytics
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2")))
         ;; Unbind the pipeline entry point for the keep gesture.
         (cl-letf (((symbol-function 'ogent-analytics-rate-completion) nil))
           (ogent-ui-send-tests--goto-response "test-model-2")
           (should (equal (ogent-fanout-keep) "test-model-2")))
         (should (ogent-ui-send-tests--archived-p "test-model-1"))
         (should-not (ogent-ui-send-tests--archived-p "test-model-2"))
         ;; The loser's row is untouched: no rating ever landed.
         (should (equal (sqlite-select
                         (ogent-analytics--get-db)
                         "SELECT rating FROM completions ORDER BY id")
                        ;; The recorder's initial rating survives on
                        ;; both rows: no 5 landed anywhere.
                        '((0) (0)))))))))

;;; Token budget echo at dispatch (bead ogent-3im)

(ert-deftest ogent-request-echoes-token-estimate ()
  "Dispatch echoes a '~N tokens' estimate once validation passes.
The shipped gpt-4o-mini window dwarfs the fixture payload, so the
anchored match also proves no spurious truncation warning."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((messages nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when fmt
                      (car (push (apply #'format fmt args) messages))))))
         (ogent-test-with-mock-gptel
           (ogent-request "Budget prompt" '("gpt-4o-mini"))))
       (let ((budget (seq-find (lambda (m) (string-prefix-p "Ogent: " m))
                               messages)))
         (should budget)
         (should (string-match-p "\\`Ogent: ~[0-9]+ tokens\\'" budget)))))))

(ert-deftest ogent-fanout-echoes-member-multiplied-estimate ()
  "A fan-out echo shows 'N x ~tokens' and warns via the tightest window.
Prompt cost multiplies by the member count (per-member context is
identical by design, see pje.1); the warning is driven by the member
with the smallest declared :context-window while windowless members
never warn."
  (ogent-test-with-fixture
   "data/fixture.org"
   (lambda ()
     (ogent-ui-send-tests--goto-details)
     (let ((ogent-model-registry
            '((:id "test-model-1" :backend gptel-openai)
              (:id "test-model-2" :backend gptel-anthropic
                   :context-window 1)))
           (messages nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when fmt
                      (car (push (apply #'format fmt args) messages))))))
         (ogent-test-with-mock-gptel
           (ogent-fanout "Fanout prompt" '("test-model-1" "test-model-2"))))
       (let ((budget (seq-find (lambda (m) (string-prefix-p "Ogent: " m))
                               messages)))
         (should budget)
         (should (string-match-p "\\`Ogent: 2 x ~[0-9]+ tokens" budget))
         (should (string-match-p
                  "may exceed test-model-2's 1-token context window"
                  budget)))))))

(provide 'ogent-ui-send-tests)

;;; ogent-ui-send-tests.el ends here

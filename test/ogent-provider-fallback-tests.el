;;; ogent-provider-fallback-tests.el --- Tests for provider fallback -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-provider-fallback)

(ert-deftest ogent-provider-access-error-detects-auth-failures ()
  "Provider access errors match built-in authentication and access patterns."
  (dolist (message '("Invalid API key provided"
                     "model_not_found: gpt-x"
                     "You do not have access to this model"
                     "insufficient_quota for account"))
    (should (ogent-provider-access-error-p message))))

(ert-deftest ogent-provider-access-error-ignores-ordinary-errors ()
  "Provider access detection ignores non-access failures."
  (dolist (message '("connection reset by peer"
                     "JSON parse failed"
                     "request timed out"))
    (should-not (ogent-provider-access-error-p message))))

(ert-deftest ogent-provider-error-message-string-normalizes-values ()
  "Error message normalization handles strings, nil, and structured values."
  (should (equal (ogent-provider-error-message-string "bad key") "bad key"))
  (should (equal (ogent-provider-error-message-string nil) ""))
  (should (equal (ogent-provider-error-message-string '(error . denied))
                 "(error . denied)")))

(ert-deftest ogent-provider-login-prompt-truncates-long-errors ()
  "Login prompt keeps provider errors to one readable line."
  (let* ((long-error (make-string 120 ?x))
         (prompt (ogent-provider-login-prompt "gpt-test" long-error)))
    (should (string-prefix-p "gpt-test failed: " prompt))
    (should (string-match-p (regexp-quote "Login to a different provider now? ") prompt))
    (should (< (length prompt) 140))))

;;; Headless retry and failover

(defconst ogent-provider-fallback-tests--registry
  '((:id "alpha-1" :backend prov-a)
    (:id "alpha-2" :backend prov-a)
    (:id "beta-1" :backend prov-b))
  "Fixed model registry used by failover tests.")

(defmacro ogent-provider-fallback-tests--with-timers (timers &rest body)
  "Run BODY with `run-at-time' capturing scheduled calls into TIMERS.
TIMERS is bound to a list of (DELAY FN ARGS) entries, most recent
first.  No real timer is ever created."
  (declare (indent 1))
  `(let ((,timers nil))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (delay _repeat fn &rest args)
                  (push (list delay fn args) ,timers)
                  nil)))
       ,@body)))

(ert-deftest ogent-provider-classify-error-partitions-classes ()
  "Error classification separates auth, transient, and fatal failures."
  (dolist (message '("Invalid API key provided"
                     "quota exceeded for this account"
                     "You do not have access to this model"))
    (should (eq (ogent-provider-classify-error message) 'auth)))
  (dolist (message '("rate limit exceeded, retry soon"
                     "429 Too Many Requests"
                     "503 Service Unavailable"
                     "connection reset by peer"
                     "request timed out"))
    (should (eq (ogent-provider-classify-error message) 'transient)))
  (dolist (message '("JSON parse failed"
                     "unexpected end of input"))
    (should (eq (ogent-provider-classify-error message) 'fatal)))
  ;; Auth patterns beat transient ones: hard auth errors are never
  ;; retried even when the message also carries a retryable status.
  (should (eq (ogent-provider-classify-error "429 insufficient_quota")
              'auth)))

(ert-deftest ogent-provider-retry-delay-backs-off-exponentially ()
  "Retry delay doubles with each performed retry."
  (let ((ogent-provider-retry-base-delay 1.0))
    (should (= (ogent-provider-retry-delay 0) 1.0))
    (should (= (ogent-provider-retry-delay 1) 2.0))
    (should (= (ogent-provider-retry-delay 2) 4.0)))
  (let ((ogent-provider-retry-base-delay 0.5))
    (should (= (ogent-provider-retry-delay 1) 1.0))))

(ert-deftest ogent-provider-handle-error-schedules-transient-retry ()
  "Transient errors schedule a same-model retry with backoff."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry)
        (ogent-provider-max-retries 2)
        (ogent-provider-retry-base-delay 1.0)
        (dispatched nil))
    (ogent-provider-fallback-tests--with-timers timers
      (let ((action (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "rate limit exceeded, retry soon"
                           :dispatch (lambda (model-id context)
                                       (push (list model-id context)
                                             dispatched))))))
        (should (eq action 'retry))
        (should (= (length timers) 1))
        (pcase-let ((`(,delay ,fn ,args) (car timers)))
          (should (= delay 1.0))
          ;; Simulate the timer firing.
          (apply fn args))
        (should (= (length dispatched) 1))
        (pcase-let ((`(,model-id ,context) (car dispatched)))
          (should (equal model-id "alpha-1"))
          (should (= (plist-get context :attempt) 1)))))))

(ert-deftest ogent-provider-handle-error-retry-delay-grows ()
  "A second retry is scheduled with a doubled backoff delay."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry)
        (ogent-provider-max-retries 2)
        (ogent-provider-retry-base-delay 1.0))
    (ogent-provider-fallback-tests--with-timers timers
      (should (eq (ogent-provider-handle-error
                   (list :model "alpha-1"
                         :backend 'prov-a
                         :error "502 bad gateway"
                         :attempt 1
                         :dispatch #'ignore))
                  'retry))
      (pcase-let ((`(,delay ,_fn ,args) (car timers)))
        (should (= delay 2.0))
        (should (= (plist-get (cadr args) :attempt) 2))))))

(ert-deftest ogent-provider-handle-error-fails-over-after-retries ()
  "Exhausted transient retries fail over to a different provider."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry)
        (ogent-provider-max-retries 2)
        (dispatched nil))
    (ogent-provider-fallback-tests--with-timers timers
      (let ((action (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "rate limit exceeded, retry soon"
                           :attempt 2
                           :dispatch (lambda (model-id context)
                                       (push (list model-id context)
                                             dispatched))))))
        (should (eq action 'failover))
        (should (= (length timers) 1))
        (pcase-let ((`(,delay ,fn ,args) (car timers)))
          (should (= delay 0))
          (apply fn args))
        (pcase-let ((`(,model-id ,context) (car dispatched)))
          ;; alpha-2 shares the failed provider and is skipped.
          (should (equal model-id "beta-1"))
          (should (equal (plist-get context :model) "beta-1"))
          (should (eq (plist-get context :backend) 'prov-b))
          (should (= (plist-get context :attempt) 0))
          (should (equal (plist-get context :tried) '("alpha-1"))))))))

(ert-deftest ogent-provider-handle-error-auth-skips-retries ()
  "Auth errors go straight to failover without retrying the model."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry)
        (ogent-provider-max-retries 2)
        (dispatched nil))
    (ogent-provider-fallback-tests--with-timers timers
      (let ((action (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "Invalid API key provided"
                           :dispatch (lambda (model-id context)
                                       (push (list model-id context)
                                             dispatched))))))
        (should (eq action 'failover))
        (should (= (length timers) 1))
        (pcase-let ((`(,delay ,fn ,args) (car timers)))
          (should (= delay 0))
          (apply fn args))
        (should (equal (caar dispatched) "beta-1"))))))

(ert-deftest ogent-provider-failover-candidate-skips-tried-providers ()
  "Failover candidates exclude the failed and already-tried providers."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry))
    (should (equal (plist-get (ogent-provider-failover-candidate
                               '(:model "alpha-1" :backend prov-a))
                              :id)
                   "beta-1"))
    (should-not (ogent-provider-failover-candidate
                 '(:model "beta-1" :backend prov-b :tried ("alpha-1"))))))

(ert-deftest ogent-provider-handle-error-exhausted-offers-login ()
  "With no eligible model, interactive sessions get the login offer."
  (let ((ogent-model-registry '((:id "alpha-1" :backend prov-a)
                                (:id "alpha-2" :backend prov-a)))
        (ogent-prompt-provider-login-on-access-error t)
        (noninteractive nil))
    (ogent-provider-fallback-tests--with-timers timers
      (let ((action (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "unauthorized"
                           :dispatch #'ignore))))
        (should (eq action 'login-offer))
        (should (= (length timers) 1))
        (pcase-let ((`(,delay ,fn ,_args) (car timers)))
          (should (= delay 0))
          (should (eq fn #'ogent-provider-offer-login)))))))

(ert-deftest ogent-provider-handle-error-exhausted-batch-gives-up ()
  "With no eligible model, batch sessions log and give up cleanly."
  (let ((ogent-model-registry '((:id "alpha-1" :backend prov-a)))
        (noninteractive t)
        (logged nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) logged)
                 nil)))
      (ogent-provider-fallback-tests--with-timers timers
        (should (eq (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "unauthorized"
                           :dispatch #'ignore))
                    'give-up))
        (should (null timers))
        (should (= (length logged) 1))
        (should (string-match-p "no fallback available" (car logged)))))))

(ert-deftest ogent-provider-handle-error-fatal-gives-up ()
  "Fatal errors are never retried, failed over, or prompted for."
  (let ((ogent-model-registry ogent-provider-fallback-tests--registry)
        (noninteractive nil)
        (logged nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) logged)
                 nil)))
      (ogent-provider-fallback-tests--with-timers timers
        (should (eq (ogent-provider-handle-error
                     (list :model "alpha-1"
                           :backend 'prov-a
                           :error "JSON parse failed"
                           :dispatch #'ignore))
                    'give-up))
        (should (null timers))
        (should (= (length logged) 1))))))

;;; ogent-provider-fallback-tests.el ends here

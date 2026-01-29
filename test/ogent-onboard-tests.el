;;; ogent-onboard-tests.el --- Tests for ogent-onboard -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-onboard)

(defvar ogent-onboard-tests--backend nil
  "Backend placeholder for ogent-onboard tests.")

(ert-deftest ogent-onboard-providers-defined ()
  "Provider list contains expected entries."
  (should (assq 'anthropic
                (mapcar (lambda (p) (cons (plist-get p :id) p))
                        ogent-onboard-providers)))
  (should (assq 'openai
                (mapcar (lambda (p) (cons (plist-get p :id) p))
                        ogent-onboard-providers))))

(ert-deftest ogent-onboard-provider-has-required-fields ()
  "Each provider has all required fields."
  (dolist (provider ogent-onboard-providers)
    (should (plist-get provider :id))
    (should (plist-get provider :name))
    (should (plist-get provider :host))
    (should (plist-get provider :backend))
    (should (plist-get provider :models))))

(ert-deftest ogent-onboard-add-to-registry ()
  "Adding model to registry works correctly."
  (let ((ogent-model-registry '((:id "existing" :backend foo)))
        (provider '(:id anthropic :backend gptel-anthropic))
        (model '(:id "test-model" :description "Test")))
    (ogent-onboard--add-to-registry provider model)
    (should (ogent-models-get "test-model"))
    (should (eq (plist-get (ogent-models-get "test-model") :backend)
                'gptel-anthropic))))

(ert-deftest ogent-onboard-set-default-model ()
  "Setting default model updates ogent-default-model."
  (let ((ogent-default-model nil))
    (ogent-onboard--set-default-model "claude-sonnet-4-20250514")
    (should (equal ogent-default-model "claude-sonnet-4-20250514"))))

(ert-deftest ogent-onboard-create-backend-anthropic-placeholder ()
  "Anthropic backend uses oauth placeholder when key is nil."
  (let* ((provider '(:name "Anthropic"
                    :backend-creator gptel-make-anthropic
                    :models ((:id "m1") (:id "m2"))))
         (captured nil))
    (cl-letf (((symbol-function 'gptel-make-anthropic)
               (lambda (name &rest args)
                 (setq captured (list name args))
                 'backend)))
      (should (eq (ogent-onboard--create-backend provider nil) 'backend))
      (should (equal (car captured) "Anthropic"))
      (should (equal (plist-get (cadr captured) :key) "oauth-managed"))
      (should (equal (plist-get (cadr captured) :models) '("m1" "m2"))))))

(ert-deftest ogent-onboard-create-backend-openai-key ()
  "OpenAI backend passes API key to gptel-make-openai."
  (let* ((provider '(:name "OpenAI"
                    :backend-creator gptel-make-openai
                    :models ((:id "o1"))))
         (captured nil))
    (cl-letf (((symbol-function 'gptel-make-openai)
               (lambda (name &rest args)
                 (setq captured (list name args))
                 'backend)))
      (should (eq (ogent-onboard--create-backend provider "secret") 'backend))
      (should (equal (car captured) "OpenAI"))
      (should (equal (plist-get (cadr captured) :key) "secret"))
      (should (equal (plist-get (cadr captured) :models) '("o1"))))))

(ert-deftest ogent-onboard-verify-connection-success ()
  "Verify connection sets backend variable on success."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature test-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-onboard--create-backend)
               (lambda (&rest _) 'backend)))
      (should (ogent-onboard--verify-connection provider "key" "m1"))
      (should (eq ogent-onboard-tests--backend 'backend)))))

(ert-deftest ogent-onboard-verify-connection-require-fails ()
  "Verification fails when backend feature cannot be required."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature missing-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
      (should-not (ogent-onboard--verify-connection provider "key" "m1"))
      (should (null ogent-onboard-tests--backend)))))

(ert-deftest ogent-onboard-verify-connection-backend-error ()
  "Verification fails when backend creation errors."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature test-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-onboard--create-backend)
               (lambda (&rest _) (error "boom"))))
      (should-not (ogent-onboard--verify-connection provider "key" "m1"))
      (should (null ogent-onboard-tests--backend)))))

;;; Interactive function tests (require with-simulated-input)

(ert-deftest ogent-onboard-select-provider-interactive ()
  "Test provider selection with simulated input."
  (ogent-test-with-input "Anthropic RET"
			 (let ((provider (ogent-onboard--select-provider)))
			   (should provider)
			   (should (eq (plist-get provider :id) 'anthropic)))))

(ert-deftest ogent-onboard-select-provider-openai ()
  "Test selecting OpenAI provider."
  (ogent-test-with-input "OpenAI RET"
			 (let ((provider (ogent-onboard--select-provider)))
			   (should provider)
			   (should (eq (plist-get provider :id) 'openai)))))

(ert-deftest ogent-onboard-select-model-interactive ()
  "Test model selection with simulated input."
  (let ((_provider (car ogent-onboard-providers)))  ; Anthropic
    (ogent-test-with-input "claude-sonnet-4-5 RET"
			   (let ((model (ogent-onboard--select-model provider)))
			     (should model)
			     (should (string-prefix-p "claude-sonnet-4-5" (plist-get model :id)))))))

(provide 'ogent-onboard-tests)
;;; ogent-onboard-tests.el ends here

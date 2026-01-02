;;; ogent-onboard-tests.el --- Tests for ogent-onboard -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-onboard)

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

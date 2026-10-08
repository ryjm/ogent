;;; ogent-pricing-tests.el --- Source-backed pricing and tier tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Compare retained rows to dated official sources and test tier boundaries.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-analytics)
(require 'json)

(ert-deftest ogent-pricing-official-source-fixture ()
  "Match every retained pricing row against its dated official source."
  (let ((rows (json-read-file (expand-file-name "data/model-pricing.json" ogent-test-root))))
    (should (= (length rows) (length ogent-analytics-model-pricing)))
    (dolist (row (append rows nil))
      (let ((price (ogent-analytics--model-pricing (alist-get 'model row))))
        (should (= (plist-get price :input-per-mtok) (alist-get 'input row)))
        (should (= (plist-get price :output-per-mtok) (alist-get 'output row)))
        (should (string-match-p "^https://\\(developers.openai.com\\|platform.claude.com\\)/"
                                (alist-get 'source row)))
        (when-let ((threshold (alist-get 'threshold row)))
          (let ((base (ogent-analytics--completion-cost (alist-get 'model row) threshold 100))
                (long (ogent-analytics--completion-cost (alist-get 'model row) (1+ threshold) 100)))
            (should (> long base))
            (should (= long (/ (+ (* (1+ threshold) (alist-get 'input row)
                                     (alist-get 'input_multiplier row))
                                  (* 100 (alist-get 'output row)
                                     (alist-get 'output_multiplier row)))
                               1000000.0)))))))))

(provide 'ogent-pricing-tests)
;;; ogent-pricing-tests.el ends here

"""Capture final native variants and exercise input during a real SSE stream."""
import json
import time
import capture

capture.PHASE = "after"
initial = capture.fingerprint()
capture.shot("proposal", '(progn (ogent-armory-actions ogent-workflow-root "review") '
             '(delete-other-windows) (goto-char (point-min)) (forward-line 1) '
             '(execute-kbd-macro (kbd "RET")) (delete-other-windows))', width=60)
capture.evaluate("(load-theme 'modus-vivendi t)")
capture.shot("dark-wide", '(progn (ogent-armory-actions ogent-workflow-root "review") '
             '(delete-other-windows))', width=112, theme="modus-vivendi")
capture.shot("invalid-detail", '(progn (goto-char (point-min)) (forward-line 2) '
             '(execute-kbd-macro (kbd "RET")) (delete-other-windows))', width=60, theme="modus-vivendi")
capture.evaluate("(load-theme 'modus-operandi t)")
capture.shot("error-80", '(progn (select-window (get-largest-window)) '
             '(delete-other-windows) (ogent-show-errors))', width=80)
capture.shot("large-font-ascii", '(progn (setq ogent-theme-use-unicode nil) '
             '(select-window (get-largest-window)) (switch-to-buffer ogent-workflow-draft) '
             '(set-frame-font "DejaVu Sans Mono-18" nil t) (delete-other-windows))', width=60)
capture.evaluate('(set-frame-font "DejaVu Sans Mono-13" nil t)')
capture.evaluate('(progn (select-window (frame-selected-window)) '
                 '(ogent-workflow-request "fixture-slow: keep the keyboard responsive") '
                 '(delete-other-windows) (setq ogent-workflow-stream-window (selected-window)) '
                 '(setq ogent-workflow-stream-id (ogent-ui-request-id (car (ogent-ui-active-requests)))) '
                 '(setq ogent-workflow-input-window (split-window-right)) '
                 '(select-window ogent-workflow-input-window) (switch-to-buffer ogent-workflow-draft) '
                 '(goto-char (point-max)))')
started = time.perf_counter()
capture.evaluate('(progn (select-window ogent-workflow-input-window) '
                 '(execute-kbd-macro (vconcat (kbd "a") '
                 '(string-to-vector "\nA draft remains editable while another request streams.") (kbd "ESC"))) '
                 '(setq ogent-workflow-input-point (point)) t)')
input_elapsed = time.perf_counter() - started
capture.shot("streaming-split", width=112)
capture.evaluate('(progn (cl-assert (eq (selected-window) ogent-workflow-input-window)) '
                 '(cl-assert (= (window-point ogent-workflow-input-window) ogent-workflow-input-point)) '
                 '(ogent-pause-request ogent-workflow-stream-id) '
                 '(cl-assert (eq (ogent-ui-request-status '
                 '(gethash ogent-workflow-stream-id ogent-ui--request-table)) (quote paused))) '
                 '(cl-assert (eq (selected-window) ogent-workflow-input-window)) '
                 '(ogent-abort-request ogent-workflow-stream-id) '
                 '(cl-assert (= 0 (length (ogent-ui-active-requests)))) t)')
proof = {"source_fingerprint": initial, "completed_fingerprint": capture.fingerprint(),
         "keyboard_elapsed_seconds": input_elapsed,
         "keyboard_measurement": "host emacsclient command roundtrip; no universal latency guarantee",
         "checks": ["input accepted during real local SSE", "selected window and point retained",
                    "pause retains original request", "cancel paused request releases registry"],
         "provider_requests": False, "screenshots": capture.RECORDS}
(capture.REPO / "docs/experiments/emacs-workflows/matrix.json").write_text(json.dumps(proof, indent=2) + "\n")
assert initial == proof["completed_fingerprint"]
print("Native variants and streaming keyboard checks passed")

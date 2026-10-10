"""Capture the actual GTK buffers of the owned workflow fixture."""
import datetime
import hashlib
import json
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/assets/emacs-review-polish"
OUT.mkdir(parents=True, exist_ok=True)
RECORDS = []


def call(argv):
    return subprocess.check_output(argv, text=True).strip()


def evaluate(form):
    result = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui",
                   "/usr/bin/emacsclient", "-s", "ogent-review-polish", "--eval", form])
    if result.startswith("*ERROR*"):
        raise RuntimeError(result)
    return result


def fingerprint():
    paths = call(["git", "-C", str(REPO), "ls-files", "lisp", "test", "makem.sh", "Makefile"]).splitlines()
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.encode() + b"\0" + (REPO / path).read_bytes() + b"\0")
    return digest.hexdigest()


def shot(name, form, width=80, dark=False):
    theme = "modus-vivendi" if dark else "modus-operandi"
    evaluate(f"(progn (mapc #'disable-theme custom-enabled-themes) (load-theme '{theme} t) "
             f"(set-frame-size (selected-frame) {width} 38) "
             "(select-window (frame-selected-window)) " + form + " (font-lock-ensure) (message nil) (redisplay t))")
    time.sleep(.25)
    state = evaluate('(format "%s | %s | Emacs %s | Org %s | %s columns" '
                     'major-mode (buffer-name) emacs-version (org-version) (window-body-width))')
    runtime = evaluate('(list :font (frame-parameter nil (quote font)) :evil evil-version '
                       ':icons ogent-theme-use-icons :unicode ogent-theme-use-unicode)')
    window = evaluate('(frame-parameter nil (quote outer-window-id))').strip('"')
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool", "windowraise", window])
    path = OUT / f"{CAPTURE_PREFIX}{name}.png"
    subprocess.run(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "import", "-window", window,
                    "/work/" + str(path.relative_to(REPO))], check=True)
    RECORDS.append({"file": str(path.relative_to(REPO)), "state": state, "theme": theme, "runtime": runtime,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})


def main():
    import sys
    prefix = "before-" if "--before" in sys.argv else "after-"
    global CAPTURE_PREFIX
    CAPTURE_PREFIX = prefix
    initial = fingerprint()
    source = '(switch-to-buffer ogent-workbench-fixture-source) (delete-other-windows) (goto-char (point-min))'
    shot("marked-passages", source)
    reader = '(switch-to-buffer ogent-workbench-fixture-source) (ogent-workbench-comments) (delete-other-windows) (goto-char (point-min))'
    shot("comments-60", reader, width=60)
    shot("comments-112-dark", reader, width=112, dark=True)
    shot("revision-60", '(let ((ogent-edit-diff--magit-available nil)) (pop-to-buffer (ogent-edit-diff-show ogent-workbench-fixture-edits))) (delete-other-windows) (goto-char (point-min))', width=60)
    shot("todo-return", '(switch-to-buffer ogent-workbench-fixture-todo) (delete-other-windows) (goto-char (point-min)) (org-overview) (org-next-visible-heading 1) (org-fold-show-subtree) (org-fold-hide-drawer-all)')
    patch = '(switch-to-buffer ogent-workbench-fixture-todo) (goto-char (point-min)) (org-next-visible-heading 1) (ogent-task-review) (delete-other-windows) (goto-char (point-min))'
    shot("task-patch-80", patch)
    shot("task-patch-60-dark", patch, width=60, dark=True)
    shot("task-result-112", '(ogent-task-result) (delete-other-windows) (goto-char (point-min)) (org-fold-show-all) (org-fold-hide-drawer-all)', width=112)
    shot("source-patch-split", patch + ' (split-window-right) (set-window-buffer (next-window) ogent-workbench-fixture-todo)', width=112)
    if prefix == "after-":
        shot("check-output-80-dark", patch + ' (ogent-task-check-output) (delete-other-windows) (goto-char (point-min))', dark=True)
        proposal = '''(with-current-buffer ogent-workbench-fixture-source
          (cl-mapc (lambda (record edit)
                     (plist-put record :proposal edit)
                     (plist-put record :draft (ogent-edit-new-text edit))
                     (plist-put record :status "proposed"))
                   (list ogent-workbench-fixture-first ogent-workbench-fixture-last)
                   ogent-workbench-fixture-edits))'''
        shot("proposed-comments-60", proposal + reader, width=60)
        shot("empty-comments-80", '(switch-to-buffer (get-buffer-create "empty-review.org")) (org-mode) (ogent-workbench-comments) (delete-other-windows) (goto-char (point-min))')
        stale = '''(with-current-buffer ogent-workbench-fixture-source
          (goto-char (marker-position (plist-get ogent-workbench-fixture-first :marker)))
          (delete-char 1) (insert "X"))'''
        shot("stale-comments-80-dark", stale + reader, dark=True)
        shot("large-font-patch-80", '(set-frame-font "DejaVu Sans Mono-16" nil t) ' + patch)
        evaluate('(set-frame-font "DejaVu Sans Mono-13" nil t)')
        # A real failed command, then a real running check. No invented outcomes.
        failed = '''(let ((record (ogent-task--read (plist-get ogent-workbench-fixture-task :file))))
          (plist-put record :check "python3 -B -c 'print(\\\"Owned failure: required greeting check\\\"); raise SystemExit(7)'")
          (ogent-task--write record)
          (switch-to-buffer ogent-workbench-fixture-todo)
          (goto-char (point-min)) (org-next-visible-heading 1)
          (setq ogent-review-capture-task (ogent-task-revise "Run the owned failing check.")))
          (let ((deadline (+ (float-time) 10)))
            (while (and (gethash (plist-get ogent-review-capture-task :file) ogent-task--active)
                        (< (float-time) deadline)) (accept-process-output nil .02)))
          (cl-assert (equal (plist-get ogent-review-capture-task :checks) "failed"))'''
        shot("failed-check-patch-60", failed + patch, width=60)
        shot("failed-check-output-112-dark", '(ogent-task-check-output) (delete-other-windows) (goto-char (point-min))', width=112, dark=True)
        checking = '''(plist-put ogent-review-capture-task :check "exec python3 -B -c 'import time; time.sleep(30)'")
          (ogent-task--write ogent-review-capture-task)
          (switch-to-buffer ogent-workbench-fixture-todo)
          (goto-char (point-min)) (org-next-visible-heading 1)
          (setq ogent-review-capture-task (ogent-task-revise "Run the owned waiting check."))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not (equal (plist-get ogent-review-capture-task :status) "checking"))
                        (< (float-time) deadline)) (accept-process-output nil .02)))
          (cl-assert (equal (plist-get ogent-review-capture-task :status) "checking"))'''
        shot("checking-patch-80", checking + patch)
        shot("cancelled-patch-80-dark", '(ogent-task-patch-cancel) (goto-char (point-min))', dark=True)
    proof = {"source_head": call(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
             "source_fingerprint": initial, "completed_fingerprint": fingerprint(),
             "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "provider_requests": False, "passages": "owned replacement JSON fixture",
             "task": "actual owned CLI, Git worktree, diff and Python checks (pass, exit 7, canceled wait)", "screenshots": RECORDS}
    (REPO / ("docs/experiments/emacs-review-polish/" + prefix + "captures.json")).write_text(json.dumps(proof, indent=2) + "\n")
    if initial != proof["completed_fingerprint"]:
        raise RuntimeError("Source changed during capture")
    print(f"Captured {len(RECORDS)} actual native workflow windows")


if __name__ == "__main__":
    main()

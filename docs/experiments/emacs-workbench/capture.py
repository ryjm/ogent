"""Capture the actual GTK buffers of the owned workflow fixture."""
import datetime
import hashlib
import json
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/assets/emacs-workbench"
OUT.mkdir(parents=True, exist_ok=True)
RECORDS = []


def call(argv):
    return subprocess.check_output(argv, text=True).strip()


def evaluate(form):
    result = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui",
                   "/usr/bin/emacsclient", "-s", "ogent-workbench", "--eval", form])
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
    window = evaluate('(frame-parameter nil (quote outer-window-id))').strip('"')
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool", "windowraise", window])
    path = OUT / f"{name}.png"
    subprocess.run(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "import", "-window", window,
                    "/work/" + str(path.relative_to(REPO))], check=True)
    RECORDS.append({"file": str(path.relative_to(REPO)), "state": state, "theme": theme,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})


def main():
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
    proof = {"source_head": call(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
             "source_fingerprint": initial, "completed_fingerprint": fingerprint(),
             "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "provider_requests": False, "passages": "owned replacement JSON fixture",
             "task": "actual owned CLI, Git worktree, diff and Python check", "screenshots": RECORDS}
    (REPO / "docs/experiments/emacs-workbench/captures.json").write_text(json.dumps(proof, indent=2) + "\n")
    if initial != proof["completed_fingerprint"]:
        raise RuntimeError("Source changed during capture")
    print(f"Captured {len(RECORDS)} actual native workflow windows")


if __name__ == "__main__":
    main()

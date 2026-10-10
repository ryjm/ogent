"""Capture actual native context windows before/after changes."""
import datetime
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/assets/emacs-context-polish"
PHASE = sys.argv[1] if len(sys.argv) > 1 else "before"
RECORDS = []


def call(argv):
    return subprocess.check_output(argv, text=True).strip()


def evaluate(form):
    result = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui",
                   "/usr/bin/emacsclient", "-s", "ogent-context-polish", "--eval", form])
    if result.startswith("*ERROR*"):
        raise RuntimeError(result)
    return result


def fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "-z", "lisp", "test", "makem.sh", "Makefile"], cwd=REPO).split(b"\0")
    digest = hashlib.sha256()
    for path in sorted(filter(None, paths)):
        digest.update(path + b"\0" + (REPO / path.decode()).read_bytes() + b"\0")
    return digest.hexdigest()


def shot(name, form, width=80, dark=False, large=False):
    theme = "modus-vivendi" if dark else "modus-operandi"
    evaluate(f"(progn (mapc #'disable-theme custom-enabled-themes) (load-theme '{theme} t) "
             f'(set-frame-font "DejaVu Sans Mono-{16 if large else 13}" nil t) '
             f"(set-frame-size (selected-frame) {width} 38))")
    time.sleep(.3)
    evaluate("(with-selected-window (frame-selected-window) " + form + ")")
    evaluate("(with-selected-window (frame-selected-window) (redisplay t) (sit-for .2) t)")
    time.sleep(.3)
    state = evaluate('(with-selected-window (frame-selected-window) '
                     '(list :buffer (buffer-name) :mode major-mode :columns (window-body-width) '
                     ':font (frame-parameter nil (quote font)) :emacs emacs-version '
                     ':org (org-version) :transient transient-version :evil (and (boundp (quote evil-version)) evil-version)))')
    window = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool", "search", "--onlyvisible", "--name", "ogent-context-polish"]).splitlines()[-1]
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool", "windowraise", window])
    time.sleep(.2)
    path = OUT / f"{PHASE}-{name}.png"
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "import", "-window", window, "/work/" + str(path.relative_to(REPO))])
    RECORDS.append({"file": str(path.relative_to(REPO)), "state": state, "theme": theme,
                    "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    initial = fingerprint()
    manager = '(progn (ogent-context-lab-open) (delete-other-windows) (goto-char (point-min)))'
    for width, dark in [(60, False), (80, False), (112, True)]:
        shot(f"manager-{width}{'-dark' if dark else ''}", manager, width, dark)
    shot("formatted-80", '(progn (ogent-context-lab-format) (delete-other-windows))')
    if PHASE == "after":
        shot("manager-60-dark", manager, 60, True)
        shot("manager-large-80", manager, 80, False, True)
        shot("manager-split-112", '(progn (ogent-context-lab-open) (delete-other-windows) (split-window-right) (set-window-buffer (next-window) ogent-context-lab-org) (goto-char (point-min)))', 112)
        shot("details-60", '(progn (ogent-context-lab-open) (delete-other-windows) (ogent-context-lab-select-handle "native-context-selection-preservation") (ogent-ui-context-preview-element) (delete-other-windows) (goto-char (point-min)))', 60)
        shot("missing-80-dark", '(progn (ogent-context-lab-open) (delete-other-windows) (ogent-context-lab-select-handle "missing-context-evidence") (ogent-ui-context-preview-element) (delete-other-windows) (goto-char (point-min)))', 80, True)
        shot("empty-80", '(progn (ogent-context-manage (list :dependencies nil) ogent-context-lab-org) (delete-other-windows) (goto-char (point-min)))')
    shot("picker-60", '(progn (switch-to-buffer ogent-context-lab-org) (delete-other-windows) (ogent-model-picker))', 60)
    evaluate('(execute-kbd-macro (kbd "q"))')
    final = fingerprint()
    if initial != final:
        raise RuntimeError("Source changed during capture")
    proof = {"phase": PHASE, "source_head": call(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
             "source_state": "working tree; fingerprint identifies exact source bytes",
             "source_fingerprint": initial, "provider_requests": False, "screenshots": RECORDS}
    (REPO / f"docs/experiments/emacs-context-polish/{PHASE}-captures.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(f"Captured {len(RECORDS)} actual native windows")


if __name__ == "__main__":
    main()

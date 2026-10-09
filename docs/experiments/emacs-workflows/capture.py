"""Capture actual native workflow windows, with provenance and no provider use."""
import datetime
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/assets/emacs-workflows"
OUT.mkdir(parents=True, exist_ok=True)
PHASE = sys.argv[1] if len(sys.argv) > 1 else "before"
RECORDS = []


def call(argv):
    return subprocess.check_output(argv, text=True).strip()


def evaluate(form):
    result = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui",
                   "/usr/bin/emacsclient", "-s", "ogent-workflows", "--eval", form])
    if result.startswith("*ERROR*"):
        raise RuntimeError(result)
    return result


def fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "-z", "lisp", "test", "makem.sh", "Makefile"], cwd=REPO).split(b"\0")
    digest = hashlib.sha256()
    for path in sorted(filter(None, paths)):
        digest.update(path + b"\0" + (REPO / path.decode()).read_bytes() + b"\0")
    return digest.hexdigest()


def shot(name, form=None, width=80, theme="modus-operandi"):
    evaluate(f"(set-frame-size (selected-frame) {width} 38)")
    time.sleep(.2)
    if form:
        evaluate("(progn (select-window (frame-selected-window)) " + form + ")")
    evaluate("(with-selected-window (frame-selected-window) (redisplay t) (sit-for .1) t)")
    state = evaluate('(with-selected-window (frame-selected-window) '
                     '(format "%s | %s | Emacs %s | Org %s | %s columns" '
                     'major-mode (buffer-name) emacs-version (org-version) (window-body-width)))')
    time.sleep(.1)
    window = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool",
                   "search", "--onlyvisible", "--class", "Emacs"]).splitlines()[-1]
    path = OUT / f"{PHASE}-{name}.png"
    subprocess.run(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "import", "-window", window,
                    "/work/" + str(path.relative_to(REPO))], check=True)
    RECORDS.append({"file": str(path.relative_to(REPO)), "state": state, "theme": theme,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})


def main():
    initial = fingerprint()
    shot("composer", '(progn (delete-other-windows) (setq ogent-workflow-draft '
         '(ogent-armory-compose-buffer ogent-workflow-root "builder")) '
         '(insert "Review @page:notes/review.org and explain the next step.") '
         '(condition-case err (ogent-armory-compose-add-attachment '
         '(expand-file-name "notes/review.org" ogent-workflow-root)) '
         '(error (message "Attachment failed: %s" (error-message-string err)))) (delete-other-windows))', width=60)
    shot("actions", '(progn (ogent-armory-actions ogent-workflow-root "review") (delete-other-windows))', width=60)
    shot("conversation", '(progn (ogent-armory-conversation ogent-workflow-root '
         '(ogent-armory-conversation-file ogent-workflow-root "review")) (delete-other-windows))', width=60)
    shot("streaming", '(progn (ogent-workflow-request "fixture-slow: inspect the local native interface") (delete-other-windows))')
    time.sleep(.3)
    shot("cancelled", '(progn (ogent-abort-request (ogent-ui-request-id (car (ogent-ui-active-requests)))) '
         '(goto-char (point-min)))')
    shot("error", '(progn (ogent-workflow-request "fixture-error: inspect the local native interface") (delete-other-windows) '
         '(sit-for .3) (ogent-show-errors))', width=60)
    proof = {"phase": PHASE, "source_head": call(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
             "source_fingerprint": initial, "completed_fingerprint": fingerprint(),
             "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "provider_requests": False, "http": "actual gptel Responses loopback fixture", "screenshots": RECORDS}
    (REPO / f"docs/experiments/emacs-workflows/{PHASE}-captures.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(f"Captured {len(RECORDS)} actual native workflow windows")
    if initial != proof["completed_fingerprint"]:
        raise RuntimeError("Source changed during capture")


if __name__ == "__main__":
    main()

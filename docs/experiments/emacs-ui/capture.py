"""Capture real Emacs windows from the isolated provider-free fixture."""
import datetime
import hashlib
import json
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/assets/emacs-ui"
RECORDS = []


def call(args):
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    if "ERROR:" in result.stdout or "*ERROR*" in result.stdout:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


def evaluate(form, server="ogent-ui"):
    return call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui",
                 "/usr/bin/emacsclient", "-s", server, "--eval", form])


def fingerprint():
    digest = hashlib.sha256()
    for path in sorted(REPO.glob("lisp/**/*.el")):
        digest.update(str(path.relative_to(REPO)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def capture(name, form, width, theme="modus-operandi", terminal=False):
    server = "ogent-ui-tty" if terminal else "ogent-ui"
    if not terminal:
        # X configure notifications arrive after set-frame-size returns.
        # Establish geometry before opening/rendering the requested surface.
        evaluate(f"(set-frame-size (selected-frame) {width} 42)", server)
        time.sleep(0.3)
    evaluate("(with-selected-window (frame-selected-window) " + form + ")", server)
    # Evaluator completion precedes X painting; allow the actual idle redisplay.
    time.sleep(0.4)
    evaluate("(with-selected-window (frame-selected-window) (redisplay t) (sit-for 0.2) t)", server)
    time.sleep(0.2)
    state = evaluate('(with-selected-window (frame-selected-window) '
                     '(format "%s | %s | Emacs %s | Org %s | transient %s | %s columns" '
                     'major-mode (buffer-name) emacs-version (org-version) transient-version (frame-width)))', server)
    if not terminal:
        reflow = evaluate('(with-selected-window (frame-selected-window) '
                          '(if (derived-mode-p (quote ogent-models-browser-mode)) '
                          '(and (= ogent-ui-models--browser-width (ogent-ui-layout-width)) '
                          '(save-excursion (goto-char (point-min)) (let ((fits t)) '
                          '(while (not (eobp)) (when (> (- (line-end-position) (line-beginning-position)) '
                          '(window-body-width)) (setq fits nil)) (forward-line 1)) fits))) t))', server)
        if reflow != "t":
            raise RuntimeError("Catalog has not reflowed: " + reflow)
    time.sleep(0.2)
    selector = ["--name", "ogent terminal"] if terminal else ["--class", "Emacs"]
    window = call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool",
                   "search", "--onlyvisible", *selector]).splitlines()[-1]
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "xdotool", "windowraise", window])
    time.sleep(0.2)
    call(["docker", "exec", "-e", "DISPLAY=:99", "ogent-ui", "import", "-window", window,
          "/work/docs/assets/emacs-ui/" + name])
    RECORDS.append({"file": "docs/assets/emacs-ui/" + name, "width": width, "theme": theme,
                    "terminal": terminal, "state": state, "optional": "Magit, Evil, Vertico",
                    "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "sha256": hashlib.sha256((OUT / name).read_bytes()).hexdigest()})


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    before = fingerprint()
    result = evaluate('(load-file "/work/docs/experiments/emacs-ui/keyboard.el.in")')
    if result != "t":
        raise RuntimeError("Keyboard journey failed: " + result)
    for theme, suffix in [("modus-operandi", "light"), ("modus-vivendi", "dark")]:
        for width in (112, 60):
            narrow = "-narrow" if width == 60 else ""
            capture(f"after-home-{suffix}{narrow}.png",
                    f"(progn (mapc #'disable-theme custom-enabled-themes) (load-theme '{theme} t) "
                    f"(ogent-armory-home ogent-ui-capture-root) (delete-other-windows) "
                    f"(set-frame-size (selected-frame) {width} 42) (goto-char (point-min)) (redisplay t))", width, theme)
        capture(f"after-models-{suffix}.png",
                "(progn (ogent-models-browse) (delete-other-windows) "
                "(set-frame-size (selected-frame) 80 38) (goto-char (point-min)) (redisplay t))", 80, theme)
    capture("after-models-narrow.png", "(progn (mapc #'disable-theme custom-enabled-themes) "
            "(load-theme 'modus-operandi t) (set-frame-size (selected-frame) 60 38) "
            "(goto-char (point-min)) (redisplay t))", 60)
    capture("after-agents-light.png", "(progn (ogent-armory-agents ogent-ui-capture-root) "
            "(delete-other-windows) (set-frame-size (selected-frame) 112 42) (redisplay t))", 112)
    capture("after-tasks-narrow.png", "(progn (ogent-armory-tasks ogent-ui-capture-root) "
            "(delete-other-windows) (set-frame-size (selected-frame) 60 38) (redisplay t))", 60)
    capture("after-models-split.png", "(progn (set-frame-size (selected-frame) 112 42) "
            "(ogent-armory-home ogent-ui-capture-root) (delete-other-windows) "
            "(split-window-right) (other-window 1) (ogent-models-browse) "
            "(goto-char (point-min)) (redisplay t))", 112)
    capture("after-terminal-ascii.png", "(progn (ogent-armory-home ogent-ui-capture-root) "
            "(delete-other-windows) (goto-char (point-min)) (redisplay t))", 80, terminal=True)
    after = fingerprint()
    if before != after:
        raise RuntimeError("UI source changed during capture")
    proof = {"source_head": call(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
             "source_state": "working tree; fingerprint identifies implemented Lisp exactly",
             "lisp_fingerprint": before, "provider_requests": False,
             "keyboard_journey": "passed with real Evil/Vertico/Magit and active provider guards",
             "screenshots": RECORDS}
    (REPO / "docs/experiments/emacs-ui/captures.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(f"Captured {len(RECORDS)} actual Emacs windows; keyboard journey passed; source unchanged")


if __name__ == "__main__":
    main()

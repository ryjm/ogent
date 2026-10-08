"""Transcript-only command runner for the fresh-context usability simulation."""
import argparse
import datetime
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--task", required=True)
parser.add_argument("--kind", default="attempt")
parser.add_argument("--note", default="")
parser.add_argument("--stderr-tail", type=int, default=1800)
parser.add_argument("argv", nargs=argparse.REMAINDER)
args = parser.parse_args()
argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
t0 = time.monotonic()
result = subprocess.run(argv, cwd="/workspace/ogent", text=True, capture_output=True)
record = {
    "task": args.task, "kind": args.kind, "note": args.note,
    "started_utc": started, "duration_seconds": time.monotonic() - t0,
    "argv": argv, "cwd": "/workspace/ogent", "stdout": result.stdout,
    "stderr": result.stderr, "status": result.returncode,
}
with (ROOT / "transcript.jsonl").open("a") as stream:
    stream.write(json.dumps(record) + "\n")
display = dict(record)
if len(display["stderr"]) > args.stderr_tail:
    display["stderr"] = "[Display tail only; full stderr is in transcript.jsonl]\n" + display["stderr"][-args.stderr_tail:]
print(json.dumps(display, indent=2))

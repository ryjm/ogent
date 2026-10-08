"""Inventory the primary agent-facing SDK and development surfaces."""
import datetime
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIT = ROOT / "agent_ergonomics_audit/audit"
SURFACES = [
    ("sdk_method", "tools", "read-file", "lisp/ogent-tools.el", "ogent-tool--read-file", False),
    ("sdk_method", "tools", "glob", "lisp/ogent-tools.el", "ogent-tool--glob", False),
    ("sdk_method", "tools", "grep", "lisp/ogent-tools.el", "ogent-tool--grep", False),
    ("sdk_method", "tools", "grep-async", "lisp/ogent-tools.el", "ogent-tool--grep-async", False),
    ("sdk_method", "tools", "bash", "lisp/ogent-tools.el", "ogent-tool--bash", True),
    ("sdk_method", "tools", "bash-async", "lisp/ogent-tools.el", "ogent-tool--bash-async", True),
    ("sdk_method", "tools", "write-file", "lisp/ogent-tools.el", "ogent-tool--write-file", True),
    ("sdk_method", "tools", "edit-file", "lisp/ogent-tools.el", "ogent-tool--edit-file", True),
    ("sdk_method", "registry", "tool-get", "lisp/ogent-models.el", "ogent-tool-get", False),
    ("sdk_method", "registry", "tool-spec-get", "lisp/ogent-models.el", "ogent-tool-spec-get", False),
    ("sdk_method", "registry", "available-tools", "lisp/ogent-models.el", "ogent-tools-enabled-list", False),
    ("sdk_method", "execution", "wrapper", "lisp/ogent-tool-execution.el", "ogent-tool-execution-wrapper", True),
    ("sdk_method", "doctor", "run", "lisp/ogent-doctor.el", "ogent-doctor-run", False),
    ("sdk_method", "doctor", "batch", "lisp/ogent-doctor.el", "ogent-doctor-batch", False),
    ("verb", "make", "help", "Makefile", "help", False),
    ("verb", "make", "compile", "Makefile", "compile", True),
    ("verb", "make", "recompile", "Makefile", "recompile", True),
    ("verb", "make", "clean", "Makefile", "clean", True),
    ("verb", "make", "offline-test", "Makefile", "offline-test", True),
]

def main():
    discovered = datetime.datetime.now(datetime.timezone.utc).isoformat()
    rows = []
    for kind, subtree, name, file, symbol, mutates in SURFACES:
        text = (ROOT / file).read_text()
        pattern = (r"^" + re.escape(symbol) + r":" if file == "Makefile"
                   else r"^\(defun " + re.escape(symbol) + r"\s")
        match = re.search(pattern, text, re.MULTILINE)
        if match is None:
            raise SystemExit(f"Surface not found: {file}: {symbol}")
        line = text[:match.start()].count("\n") + 1
        rows.append({"surface_id": f"{kind}__{subtree}__{name}",
                     "kind": kind, "subtree": subtree, "name": symbol,
                     "source": {"file": file, "line": line},
                     "is_sdk_surface": kind == "sdk_method",
                     "required": False, "deprecated": False,
                     "mutates": mutates, "discovered_at": discovered})
    (AUDIT / "surface_inventory.jsonl").write_text(
        "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))
    print(f"Inventoried {len(rows)} primary surfaces")

if __name__ == "__main__":
    main()

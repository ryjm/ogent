#!/usr/bin/env bash

# * makem.sh --- Script to aid building and testing Emacs Lisp packages

# URL: https://github.com/alphapapa/makem.sh
# Version: 0.8-pre

# * Commentary:

# makem.sh is a script that helps to build, lint, and test Emacs Lisp
# packages.  It aims to make linting and testing as simple as possible
# without requiring per-package configuration.

# It works similarly to a Makefile in that "rules" are called to
# perform actions such as byte-compiling, linting, testing, etc.

# Source and test files are discovered automatically from the
# project's Git repo, and package dependencies within them are parsed
# automatically.

# Output is simple: by default, there is no output unless errors
# occur.  With increasing verbosity levels, more detail gives positive
# feedback.  Output is colored by default to make reading easy.

# The script can run Emacs with the developer's local Emacs
# configuration, or with a clean, "sandbox" configuration that can be
# optionally removed afterward.  This is especially helpful when
# upstream dependencies may have released new versions that differ
# from those installed in the developer's personal configuration.

# * License:

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# * Functions

function usage {
    cat <<EOF
$0 [OPTIONS] RULES...

Linter- and test-specific rules will error when their linters or tests
are not found.  With -vv, rules that run multiple rules will show a
message for unavailable linters or tests.

Rules:
  all      Run all lints and tests.
  compile  Byte-compile source files.

  lint           Run all linters, ignoring unavailable ones.
  lint-checkdoc  Run checkdoc.
  lint-compile   Byte-compile source files with warnings as errors.
  lint-declare   Run check-declare.
  lint-elsa      Run Elsa (not included in "lint" rule).
  lint-indent    Lint indentation.
  lint-package   Run package-lint.
  lint-regexps   Run relint.

  test, tests           Run all tests, ignoring missing test types.
  test-buttercup        Run Buttercup tests.
  test-ert              Run ERT tests.
  test-ert-interactive  Run ERT tests interactively.

  batch        Run Emacs in batch mode, loading project source and test files
               automatically, with remaining args (after "--") passed to Emacs.
  interactive  Run Emacs interactively, loading project source and test files
               automatically, with remaining args (after "--") passed to Emacs.

Options:
  -d, --debug    Print debug info.
  -h, --help     I need somebody!
  -v, --verbose  Increase verbosity, up to -vvv.
  --no-color     Disable color output.
  --json         Return a versioned JSON report; send diagnostics to stderr.
  --capabilities Show rules, reporting contracts, and exit codes without Emacs.

  --debug-load-path  Print load-path from inside Emacs.

  -E, --emacs PATH  Run Emacs at PATH.

  -e, --exclude FILE  Exclude FILE from linting and testing.
  -f, --file FILE     Check FILE in addition to discovered files.

  -c, --compile-batch  Batch-compile files (instead of separately; quicker, but
                                            may hide problems).
  -C, --no-compile     Don't compile files automatically.

Sandbox options:
  -s[DIR], --sandbox[=DIR]  Run Emacs with an empty config in a sandbox DIR.
                            If DIR does not exist, make it.  If DIR is not
                            specified, use a temporary sandbox directory and
                            delete it afterward, implying --install-deps and
                            --install-linters.
  --install-deps            Automatically install package dependencies.
  --install-linters         Automatically install linters.
  -i, --install PACKAGE     Install PACKAGE before running rules.

  An Emacs version-specific subdirectory is automatically made inside
  the sandbox, allowing testing with multiple Emacs versions.  When
  specifying a sandbox directory, use options --install-deps and
  --install-linters on first-run and omit them afterward to save time.

Source files are automatically discovered from git, or may be
specified with options.  Package dependencies are discovered from
"Package-Requires" headers in source files, from -pkg.el files, and
from a Cask file.

Checkdoc's spell checker may not recognize some words, causing the
\`lint-checkdoc' rule to fail.  Custom words can be added in file-local
or directory-local variables using the variable
\`ispell-buffer-session-localwords', which should be set to a list of
strings.

JSON exit codes: 0 success, 1 task failure, 2 invalid invocation,
3 missing prerequisite, 130 interrupted, 143 terminated.
JSON requires Python 3 and supports noninteractive rules only.  NO_COLOR and
non-terminal stderr disable color in ordinary output too.
EOF
}

# ** Structured reporting

# Reporting observes the real runner: Emacs commands still execute in
# run_emacs, with their output captured before the same task checks run.
# No environment values are included in reports.
function report-event {
    [[ $report_dir ]] || return 0
    python3 - "$report_dir/events.jsonl" "$@" <<'PY'
import json
import pathlib
import sys

kind, *values = sys.argv[2:]
event = {"kind": kind, "values": values}
if kind == "process":
    event["output"] = pathlib.Path(values[2]).read_text(errors="replace")
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, ensure_ascii=False) + "\n")
PY
}

function report-bootstrap-failure {
    # The prerequisite itself cannot serialize JSON yet.  These messages are
    # fixed literals so this minimal contract needs no ad-hoc JSON escaping.
    local message
    case "$1" in
        python3) message='JSON reporting requires python3; install Python 3 or omit --json.' ;;
        *) message='JSON reporting requires GNU mktemp and a writable temporary directory.' ;;
    esac
    printf 'ERROR: %s\n' "$message" >&2
    printf '%s\n' '{"contract_version":"1","tool":"makem.sh","status":"error","exit_code":3,"exit_kind":"missing_prerequisite","exit_codes":{"0":"success","1":"task_failure","2":"invalid_invocation","3":"missing_prerequisite","130":"interrupted","143":"terminated"},"project_root":null,"requested_tasks":[],"tasks":[],"commands":[],"diagnostics":[{"source":"makem","command_index":null,"task":null,"severity":"error","file":null,"line":null,"column":null,"message":"'"$message"'"}],"next_actions":["Install the missing prerequisite or omit --json."]}'
    exit 3
}

function report-finish {
    local status=$1
    # EXIT runs once; signal traps only set the status and leave through EXIT.
    trap - EXIT INT TERM
    if [[ $report_dir ]]
    then
        python3 - "$report_dir/events.jsonl" "$status" "$PWD" <<'PY' >&3
import json
import pathlib
import re
import sys

events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
exit_code = int(sys.argv[2])
rules = ["all", "compile", "lint", "lint-checkdoc", "lint-compile",
         "lint-declare", "lint-elsa", "lint-elint", "lint-indent", "lint-package",
         "lint-regexps", "test", "tests", "test-buttercup", "test-ert", "batch",
         "interactive", "test-ert-interactive"]
exit_codes = {"0": "success", "1": "task_failure", "2": "invalid_invocation",
              "3": "missing_prerequisite", "130": "interrupted", "143": "terminated"}
report = {"contract_version": "1", "tool": "makem.sh", "status":
          "success" if exit_code == 0 else "error", "exit_code": exit_code,
          "exit_kind": exit_codes.get(str(exit_code), "task_failure"),
          "exit_codes": exit_codes, "project_root": sys.argv[3], "requested_tasks": [],
          "tasks": [], "commands": [], "diagnostics": [], "next_actions": []}
ansi = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
for event in events:
    kind, values = event["kind"], event["values"]
    if kind == "requested":
        report["requested_tasks"] = values
    elif kind == "task":
        task, status, code, reason = values
        report["tasks"].append({"name": task, "status": status, "exit_code": int(code),
                                "reason": reason or None})
    elif kind == "process":
        task, code, _, purpose, pid, *argv = values
        output = ansi.sub("", event["output"])
        index = len(report["commands"])
        command = {"task": task, "purpose": purpose, "pid": int(pid) if pid else None, "argv": argv,
                   "exit_code": int(code), "output": output}
        summary = re.search(r"Ran (\d+) tests?, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?", output)
        if summary:
            count, expected, unexpected, skipped = summary.groups()
            command["tests"] = {"total": int(count), "expected": int(expected),
                                "unexpected": int(unexpected), "skipped": int(skipped or 0)}
        report["commands"].append(command)
        # Keep raw output above so diagnostics are lossless even when an Emacs
        # version changes its presentation.  Normalize familiar compiler/ERT
        # lines as an additional convenience, not as the source of truth.
        for line in output.splitlines():
            if purpose == "availability_probe":
                continue
            location = re.match(r"^(.*\.el):(\d+)(?::(\d+))?:\s*(.*)$", line)
            if location:
                path, number, column, message = location.groups()
                report["diagnostics"].append({"source": "emacs", "command_index": index,
                    "task": task, "severity": "warning" if "Warning:" in message else "error",
                    "file": path, "line": int(number), "column": int(column) if column else None,
                    "message": message})
            elif re.search(r"\bFAILED\b|\b[1-9]\d* unexpected\b|^Error:|^error:", line):
                report["diagnostics"].append({"source": "emacs", "command_index": index,
                    "task": task, "severity": "error", "file": None, "line": None,
                    "column": None, "message": line})
    elif kind in ("error", "warning"):
        report["diagnostics"].append({"source": "makem", "command_index": None,
            "task": values[0] or None, "severity": kind, "file": None,
            "line": None, "column": None, "message": values[1]})
    elif kind == "next":
        report["next_actions"].extend(values)
    elif kind == "help":
        report["help"] = values[0]
    elif kind == "capabilities":
        report["capabilities"] = {"rules": rules,
            "report_option": "--json", "discovery_command": "./makem.sh --capabilities --json",
            "requirements": {"execution": ["bash", "git", "GNU getopt", "GNU coreutils", "gzip", "Emacs"],
                             "json": ["python3"]},
            "environment": {"NO_COLOR": "Disable ANSI color, including when empty"},
            "noninteractive_json_only": True,
            "examples": ["make test format=json", "make lint format=json",
                         "./makem.sh --json --emacs=/path/to/emacs compile"]}
print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
PY
        local report_status=$?
        [[ $report_status == 0 ]] || status=3
    fi
    cleanup
    exit "$status"
}

function report-interrupt {
    local status=$1
    if [[ $report_child_pid ]]
    then
        kill -TERM "$report_child_pid" 2>/dev/null
        wait "$report_child_pid" 2>/dev/null
        report-event process "${report_task:-setup}" "$status" "$report_child_output" "${report_command_purpose:-task}" "$report_child_pid" "${report_child_argv[@]}"
        report-event task "${report_task:-setup}" error "$status" "Execution interrupted."
    fi
    report-event error "$report_task" "Execution interrupted."
    exit "$status"
}

function run-rule {
    local task=$1
    shift
    local report_task=$task report_skipped= before_errors=$errors
    "$task" "$@"
    local status=$?
    if [[ $status != 0 && $errors == "$before_errors" ]]
    then
        error "Task '$task' failed with exit $status. Inspect its diagnostics and rerun make $task."
    fi
    [[ $errors -gt $before_errors ]] && status=1
    if [[ $report_skipped && $status == 0 ]]
    then
        report-event task "$task" skipped 0 "$report_skipped"
    elif [[ $status == 0 ]]
    then
        report-event task "$task" success 0 ""
    else
        report-event task "$task" error "$status" "Task diagnostics are included in this report."
        report-event next "${report_rerun% }"
    fi
    return "$status"
}

# ** Elisp

# These functions return a path to an elisp file which can be loaded
# by Emacs on the command line with -l or --load.

function elisp-buttercup-file {
    # The function buttercup-run, which is called by buttercup-run-discover,
    # signals an error if it can't find any Buttercup test suites.  We don't
    # want that to be an error, so we define advice which ignores that error.
    if ! [[ $elisp_buttercup_file ]]
    then
        elisp_buttercup_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-buttercup-file-XXX")
        cat >"$elisp_buttercup_file" <<EOF
(defun makem-buttercup-run (oldfun &rest r)
  "Call buttercup-run only if \`buttercup-suites' is non-nil."
  (when buttercup-suites
    (apply oldfun r)))

(advice-add #'buttercup-run :around #'makem-buttercup-run)
EOF
    fi
    echo "$elisp_buttercup_file"
}

function elisp-elint-file {
    if ! [[ $elisp_elint_file ]]
    then
        elisp_elint_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-elint-file-XXX")
        cat >"$elisp_elint_file" <<EOF
(require 'cl-lib)
(require 'elint)
(defun makem-elint-file (file)
  (let ((errors 0))
    (cl-letf (((symbol-function 'orig-message) (symbol-function 'message))
              ((symbol-function 'message) (symbol-function 'ignore))
              ((symbol-function 'elint-output)
               (lambda (string)
                 (cl-incf errors)
                 (orig-message "%s" string))))
      (elint-file file)
      ;; NOTE: \`errors' is not actually the number of errors, because
      ;; it's incremented for non-error header strings as well.
      (kill-emacs errors))))
EOF
    fi
    echo "$elisp_elint_file"
}

function elisp-checkdoc-file {
    # Since checkdoc doesn't have a batch function that exits non-zero
    # when errors are found, we make one.
    if ! [[ $elisp_checkdoc_file ]]
    then
        elisp_checkdoc_file=$(mktemp --tmpdir --suffix=".el"  "makem-elisp-checkdoc-file-XXX")
        cat >"$elisp_checkdoc_file" <<EOF
(defvar makem-checkdoc-errors-p nil)

(defun makem-checkdoc-files-and-exit ()
  "Run checkdoc-file on files remaining on command line, exiting non-zero if there are warnings."
  (let* ((files (mapcar #'expand-file-name command-line-args-left))
         (checkdoc-create-error-function
          (lambda (text start end &optional unfixable)
            (let ((msg (concat (checkdoc-buffer-label) ":"
                               (int-to-string (count-lines (point-min) (or start (point-min))))
                               ": " text)))
              (message msg)
              (setq makem-checkdoc-errors-p t)
              ;; Return nil because we *are* generating a buffered list of errors.
              nil))))
    (put 'ispell-buffer-session-localwords 'safe-local-variable #'list-of-strings-p)
    (mapcar #'checkdoc-file files)
    (when makem-checkdoc-errors-p
      (kill-emacs 1))))

(setq checkdoc-spellcheck-documentation-flag nil)
(makem-checkdoc-files-and-exit)
EOF
    fi
    echo "$elisp_checkdoc_file"
}

function elisp-byte-compile-file {
    # This seems to be the only way to make byte-compilation signal
    # errors for warnings AND display all warnings rather than only
    # the first one.
    if ! [[ $elisp_byte_compile_file ]]
    then
        elisp_byte_compile_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-byte-compile-file-XXX")
        # TODO: Add file to $paths_temp in other elisp- functions.
        cat >"$elisp_byte_compile_file" <<EOF
(defun makem-batch-byte-compile (&rest args)
  ""
  (let ((num-errors 0)
        (num-warnings 0))
    ;; NOTE: Only accepts files as args, not directories.
    (dolist (file command-line-args-left)
      (pcase-let ((\`(,errors ,warnings) (makem-byte-compile-file file)))
        (cl-incf num-errors errors)
        (cl-incf num-warnings warnings)))
    (zerop num-errors)))

(defun makem-byte-compile-file (filename &optional load)
  "Call \`byte-compile-warn', returning the number of errors and the number of warnings."
  (let ((num-warnings 0)
        (num-errors 0))
    (let ((byte-compile-log-warning-function
           (lambda (string position fill level)
             (pcase-exhaustive level
               (:warning (cl-incf num-warnings))
               (:error (cl-incf num-errors)))
             (byte-compile--log-warning-for-byte-compile string position fill level))))
      (byte-compile-file filename load))
    (list num-errors num-warnings)))
EOF
    fi
    echo "$elisp_byte_compile_file"
}

function elisp-check-declare-file {
    # Since check-declare doesn't have a batch function that exits
    # non-zero when errors are found, we make one.
    if ! [[ $elisp_check_declare_file ]]
    then
        elisp_check_declare_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-check-declare-file-XXX")
        cat >"$elisp_check_declare_file" <<EOF
(require 'check-declare)

(defun makem-check-declare-files-and-exit ()
  "Run check-declare-files on files remaining on command line, exiting non-zero if there are warnings."
  (let* ((files (mapcar #'expand-file-name command-line-args-left))
         (errors (apply #'check-declare-files files)))
    (when errors
      (with-current-buffer check-declare-warning-buffer
        (print (buffer-string)))
      (kill-emacs 1))))
EOF
    fi
    echo "$elisp_check_declare_file"
}

function elisp-lint-indent-file {
    # This function prints warnings for indentation errors and exits
    # non-zero when errors are found.
    if ! [[ $elisp_lint_indent_file ]]
    then
        elisp_lint_indent_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-lint-indent-file-XXX")
        cat >"$elisp_lint_indent_file" <<EOF
(require 'cl-lib)

(defun makem-lint-indent-batch-and-exit ()
  "Print warnings for files which are not indented properly, then exit.
Exits non-zero if mis-indented lines are found.  Checks files in
'command-line-args-left'."
  (let ((errors-p))
    (cl-labels ((lint-file (file)
                           (find-file file)
                           (let ((inhibit-message t))
                             (indent-region (point-min) (point-max)))
                           (when buffer-undo-list
                             ;; Indentation changed: warn for each line.
                             (dolist (line (undo-lines buffer-undo-list))
                               (message "%s:%s: Indentation mismatch" (buffer-name) line))
                             (setf errors-p t)))
                (undo-pos (entry)
                           (cl-typecase (car entry)
                             (number (car entry))
                             (string (abs (cdr entry)))))
                (undo-lines (undo-list)
                            ;; Return list of lines changed in UNDO-LIST.
                            (nreverse (cl-loop for elt in undo-list
                                               for pos = (undo-pos elt)
                                               when pos
                                               collect (line-number-at-pos pos)))))
      (mapc #'lint-file (mapcar #'expand-file-name command-line-args-left))
      (when errors-p
        (kill-emacs 1)))))
EOF
    fi
    echo "$elisp_lint_indent_file"
}

function elisp-package-initialize-file {
    if ! [[ $elisp_package_initialize_file ]]
    then
        elisp_package_initialize_file=$(mktemp --tmpdir --suffix=".el" "makem-elisp-package-initialize-file-XXX")
        cat >"$elisp_package_initialize_file" <<EOF
(require 'package)
(setq package-archives (list (cons "gnu" "https://elpa.gnu.org/packages/")
                             (cons "melpa" "https://melpa.org/packages/")
                             (cons "melpa-stable" "https://stable.melpa.org/packages/")))
(package-initialize)
EOF
    fi
    echo "$elisp_package_initialize_file"
}

# ** Emacs

function run_emacs {
    # NOTE: The sandbox args need to come before the package
    # initialization so Emacs will use the sandbox's packages.
    local emacs_command=(
        "${emacs_command[@]}"
        -Q
        --eval "(setq load-prefer-newer t)"
        "${args_debug[@]}"
        "${args_sandbox[@]}"
        $arg_batch
        "${args_load_paths[@]}"
    )

    # Nix-built Emacs often ships core Lisp only as .el.gz.  Some batch rules
    # recurse while loading compressed core libraries, so surface uncompressed
    # copies of the small subset this project actually touches.
    local emacs_lisp_compat_dir
    emacs_lisp_compat_dir=$(mktemp --tmpdir -d "makem-emacs-compat-dir-XXX") || die "Unable to make Emacs compat dir."
    paths_temp+=("$emacs_lisp_compat_dir")
    local emacs_lisp_dir
    emacs_lisp_dir=$("${emacs_command[0]}" --batch --eval '(princ lisp-directory)')
    local relative source_file source_target
    for relative in \
        jka-compr.el \
        emacs-lisp/package.el \
        emacs-lisp/bytecomp.el \
        emacs-lisp/benchmark.el \
        progmodes/flymake.el \
        emacs-lisp/elp.el
    do
        source_file="$emacs_lisp_dir/$relative"
        source_target="$emacs_lisp_compat_dir/$(basename "$source_file")"
        if [[ -f "$source_file.gz" ]]
        then
            gzip -dc "$source_file.gz" > "$source_target"
        elif [[ -f "$source_file" ]]
        then
            cp "$source_file" "$source_target"
        fi
    done
    if [[ -f "$emacs_lisp_compat_dir/jka-compr.el" ]]
    then
        emacs_command+=(-L "$emacs_lisp_compat_dir" --load jka-compr)
    fi

    # Local fast checks may rely on newer package installs than the Emacs
    # bundled transient.  If the maintainer has user-installed transient bits,
    # surface them ahead of the bundled copy.
    if ! [[ $sandbox ]]
    then
        local user_elpa_dir="$HOME/.emacs.d/elpa"
        local pattern dep_dir latest_dep
        for pattern in compat-* cond-let-* transient-*
        do
            latest_dep=
            for dep_dir in "$user_elpa_dir"/$pattern
            do
                [[ -d "$dep_dir" ]] && latest_dep="$dep_dir"
            done
            [[ $latest_dep ]] && emacs_command+=(-L "$latest_dep")
        done
    fi

    # Show debug message with load-path from inside Emacs.
    [[ $debug_load_path ]] \
        && debug $("${emacs_command[@]}" \
                       --batch \
                       --eval "(message \"LOAD-PATH: %s\" load-path)" \
                    2>&1)

    # Set output file.
    output_file=$(mktemp --tmpdir --suffix=".txt" "makem-emacs-output-XXX") || die "Unable to make output file."
    paths_temp+=("$output_file")

    # Run Emacs.
    debug "run_emacs: ${emacs_command[@]} $@ &>\"$output_file\""
    local exit process_pid
    if [[ $report_dir ]]
    then
        report_child_output=$output_file
        report_child_argv=("${emacs_command[@]}" "$@")
        "${emacs_command[@]}" "$@" &>"$output_file" &
        report_child_pid=$!
        process_pid=$report_child_pid
        wait "$report_child_pid"
        exit=$?
        unset report_child_pid
        unset report_child_output report_child_argv
    else
        "${emacs_command[@]}" "$@" &>"$output_file"
        exit=$?
    fi

    report-event process "${report_task:-setup}" "$exit" "$output_file" "${report_command_purpose:-task}" "$process_pid" "${emacs_command[@]}" "$@"

    # Check exit code and output.
    [[ $exit != 0 ]] \
        && debug "Emacs exited non-zero: $exit"

    [[ $verbose -gt 1 || $exit != 0 ]] \
        && cat "$output_file" >&2

    return $exit
}

# ** Compilation

function batch-byte-compile {
    debug "batch-byte-compile: ERROR-ON-WARN:$compile_error_on_warn"

    [[ $compile_error_on_warn ]] && local error_on_warn=(--eval "(setq byte-compile-error-on-warn t)")
    [[ $sandbox ]] && local source_first=(--eval "(setq load-suffixes '(\".el\" \".elc\"))")

    run_emacs \
        --load "$elisp_byte_compile_file" \
        "${error_on_warn[@]}" \
        "${source_first[@]}" \
        --eval "(unless (makem-batch-byte-compile) (kill-emacs 1))" \
        "$@"
}

function byte-compile-file {
    debug "byte-compile: ERROR-ON-WARN:$compile_error_on_warn"
    local file="$1"

    [[ $compile_error_on_warn ]] && local error_on_warn=(--eval "(setq byte-compile-error-on-warn t)")
    [[ $sandbox ]] && local source_first=(--eval "(setq load-suffixes '(\".el\" \".elc\"))")

    # FIXME: Why is the line starting with "&& verbose 3" not indented properly?  Emacs insists on indenting it back a level.
    run_emacs \
        --load "$elisp_byte_compile_file" \
        "${error_on_warn[@]}" \
        "${source_first[@]}" \
        --eval "(pcase-let ((\`(,num-errors ,num-warnings) (makem-byte-compile-file \"$file\"))) (when (or (and byte-compile-error-on-warn (not (zerop num-warnings))) (not (zerop num-errors))) (kill-emacs 1)))" \
        && verbose 3 "Compiling $file finished without errors." \
            || { verbose 3 "Compiling file failed: $file"; return 1; }
}

# ** Files

function submodules {
    # Echo a list of submodules's paths relative to the repo root.
    # TODO: Parse with bash regexp instead of cut.
    git submodule status | awk '{print $2}'
}

function project-root {
    # Echo the root of the project (or superproject, if running from
    # within a submodule).
    root_dir=$(git rev-parse --show-superproject-working-tree)
    [[ $root_dir ]] || root_dir=$(git rev-parse --show-toplevel)
    [[ $root_dir ]] || error "Can't find repo root."

    echo "$root_dir"
}

function files-project {
    # Echo a list of files in project; or with $1, files in it
    # matching that pattern with "git ls-files".  Excludes submodules.
    [[ $1 ]] && pattern="/$1" || pattern="."

    local excludes=()
    for submodule in $(submodules)
    do
        excludes+=(":!:$submodule")
    done

    git ls-files -- "$pattern" "${excludes[@]}"
}

function dirs-project {
    # Echo list of directories to be used in load path.
    files-project-feature | dirnames
    files-project-test | dirnames
}

function files-project-elisp {
    # Echo list of Elisp files in project.
    files-project 2>/dev/null \
        | grep -E "\.el$" \
        | filter-files-exclude-default \
        | filter-files-exclude-args
}

function files-project-feature {
    # Echo list of Elisp files that are not tests and provide a feature.
    files-project-elisp \
        | grep -E -v "$test_files_regexp" \
        | filter-files-feature
}

function files-project-test {
    # Echo list of Elisp test files.
    files-project-elisp | grep -E "$test_files_regexp"
}

function dirnames {
    # Echo directory names for files on STDIN.
    while read file
    do
        dirname "$file"
    done
}

function filter-files-exclude-default {
    # Filter out paths (STDIN) which should be excluded by default.
    grep -E -v "(/\.cask/|-autoloads\.el|\.dir-locals)"
}

function filter-files-exclude-args {
    # Filter out paths (STDIN) which are excluded with --exclude.
    if [[ ${files_exclude[@]} ]]
    then
        (
            # We use a subshell to set IFS temporarily so we can send
            # the list of files to grep -F.  This is ugly but more
            # correct than replacing spaces with line breaks.  Note
            # that, for some reason, using IFS="\n" or IFS='\n' doesn't
            # work, and a literal line break seems to be required.
            IFS="
"
            grep -Fv "${files_exclude[*]}"
        )
    else
        cat
    fi
}

function filter-files-feature {
    # Read paths on STDIN and echo ones that (provide 'a-feature).
    while read path
    do
        grep -E "^\\(provide '" "$path" &>/dev/null \
            && echo "$path"
    done
}

function args-load-files {
    # For file in $@, echo "--load $file" using the source path.
    for file in "$@"
    do
        printf -- '--load %q ' "$file"
    done
}

function args-load-path {
    # Echo load-path arguments.
    for path in $(dirs-project | sort -u)
    do
        printf -- '-L %q ' "$path"
    done
}

function test-files-p {
    # Return 0 if $files_project_test is non-empty.
    [[ "${files_project_test[@]}" ]]
}

function buttercup-tests-p {
    # Return 0 if Buttercup tests are found.
    test-files-p || return 1
    debug "Checking for Buttercup tests..."

    grep "(require 'buttercup)" "${files_project_test[@]}" &>/dev/null
}

function ert-tests-p {
    # Return 0 if ERT tests are found.
    test-files-p || return 1
    debug "Checking for ERT tests..."

    # We check for this rather than "(require 'ert)", because ERT may
    # already be loaded in Emacs and might not be loaded with
    # "require" in a test file.
    grep "(ert-deftest" "${files_project_test[@]}" &>/dev/null
}

function package-main-file {
    # Echo the package's main file.
    file_pkg=$(files-project "*-pkg.el" 2>/dev/null)

    if [[ $file_pkg ]]
    then
        # Use *-pkg.el file if it exists.
        echo "$file_pkg"
    else
        if printf '%s\n' "${files_project_feature[@]}" | grep -q '^lisp/ogent\.el$'
        then
            echo "lisp/ogent.el"
            return
        fi
        # Prefer the file with the package header; shortest filename picks
        # helper files such as lint.el in multi-file packages.
        for file in "${files_project_feature[@]}"
        do
            if grep -q '^;; Package-Requires: ' "$file"
            then
                echo "$file"
                return
            fi
        done
        # Fallback: use shortest filename (a sloppy heuristic).
        for file in "${files_project_feature[@]}"
        do
            echo ${#file} "$file"
        done \
            | sort -h \
            | head -n1 \
            | sed -r 's/^[[:digit:]]+ //'
    fi
}

function dependencies {
    # Echo list of package dependencies.

    # Search package headers.  Use -a so grep won't think that an Elisp file containing
    # control characters (rare, but sometimes necessary) is binary and refuse to search it.
    grep -E -a -i '^;; Package-Requires: ' $(files-project-feature) $(files-project-test) \
        | grep -E -o '\([^([:space:]][^)]*\)' \
        | grep -E -o '^[^[:space:])]+' \
        | sed -r 's/\(//g' \
        | grep -E -v '^emacs$'  # Ignore Emacs version requirement.

    # Search Cask file.
    if [[ -r Cask ]]
    then
        grep -E '\(depends-on "[^"]+"' Cask \
            | sed -r -e 's/\(depends-on "([^"]+)".*/\1/g'
    fi

    # Search -pkg.el file.
    if [[ $(files-project "*-pkg.el" 2>/dev/null) ]]
    then
        sed -nr 's/.*\(([-[:alnum:]]+)[[:blank:]]+"[.[:digit:]]+"\).*/\1/p' $(files-project- -- -pkg.el 2>/dev/null)
    fi
}

# ** Sandbox

function sandbox {
    verbose 2 "Initializing sandbox..."

    # *** Sandbox arguments

    # MAYBE: Optionally use branch-specific sandbox?

    # Check or make user-emacs-directory.
    if [[ $sandbox_dir ]]
    then
        # Directory given as argument: ensure it exists.
        if ! [[ -d $sandbox_dir ]]
        then
            debug "Making sandbox directory: $sandbox_dir"
            mkdir -p "$sandbox_dir" || die "Unable to make sandbox dir."
        fi

        # Add Emacs version-specific subdirectory, creating if necessary.
        sandbox_dir="$sandbox_dir/$(emacs-version)"
        if ! [[ -d $sandbox_dir ]]
        then
            mkdir "$sandbox_dir" || die "Unable to make sandbox subdir: $sandbox_dir"
        fi
    else
        # Not given: make temp directory, and delete it on exit.
        sandbox_dir=$(mktemp --tmpdir -d "makem-emacs-sandbox-dir-XXX") || die "Unable to make sandbox dir."
        paths_temp+=("$sandbox_dir")
    fi

    # Make argument to load init file if it exists.
    init_file="$sandbox_dir/init.el"

    # Set sandbox args.  This is a global variable used by the run_emacs function.
    args_sandbox=(
        --title "makem.sh: $(basename $(pwd)) (sandbox: $sandbox_dir)"
        --eval "(setq user-emacs-directory (file-truename \"$sandbox_dir\"))"
        --eval "(setq package-user-dir (expand-file-name \"elpa\" user-emacs-directory))"
        --eval "(setq user-init-file (file-truename \"$init_file\"))"
    )

    # Add package-install arguments for dependencies.
    if [[ $install_deps ]]
    then
        local deps=($(dependencies))
        debug "Installing dependencies: ${deps[@]}"

        # Ensure built-in packages get upgraded to newer versions from ELPA.
        args_sandbox_package_install+=(--eval "(setq package-install-upgrade-built-in t)")
        # Transient 0.13.x compiles against the external Compat package on
        # Emacs 30; installing Compat first avoids loading the built-in stub.
        if printf '%s\n' "${deps[@]}" | grep -qx transient
        then
            args_sandbox_package_install+=(--eval "(package-install 'compat)")
            args_sandbox_package_install+=(--eval "(package-install 'transient)")
        fi

        for package in "${deps[@]}"
        do
            if [[ $package == transient || $package == compat ]]
            then
                continue
            fi
            args_sandbox_package_install+=(--eval "(package-install '$package)")
        done
    fi

    # Add package-install arguments for linters.
    if [[ $install_linters ]]
    then
        debug "Installing linters: package-lint relint"

        args_sandbox_package_install+=(
            --eval "(package-install 'elsa)"
            --eval "(package-install 'package-lint)"
            --eval "(package-install 'relint)")
    fi

    # *** Install packages into sandbox

    if [[ ${args_sandbox_package_install[@]} ]]
    then
        # Initialize the sandbox (installs packages once rather than for every rule).
        verbose 1 "Installing packages into sandbox..."

        run_emacs \
            --eval "(setq package-user-dir (expand-file-name \"elpa\" user-emacs-directory))" \
            -l "$elisp_package_initialize_file" \
            --eval "(package-refresh-contents)" \
            "${args_sandbox_package_install[@]}" \
            && success "Packages installed." \
                || die "Unable to initialize sandbox."
    fi

    verbose 2 "Sandbox initialized."
}

function args-load-path-sandbox {
    # Echo list of Emacs arguments to add paths of packages installed
    # in sandbox to load-path.
    if ! [[ -d "$sandbox_dir/elpa" ]]
    then
        warn "Sandbox's \"elpa/\" directory not found: no packages installed."
    else
        for path in $(find "$sandbox_dir/elpa" -maxdepth 1 -type d -not -name "archives" -print \
                          | tail -n+2)
        do
            printf -- '-L %q ' "$path"
        done
    fi
}

# ** Utility

function cleanup {
    # Remove temporary paths (${paths_temp[@]}).
    for path in "${paths_temp[@]}"
    do
        if [[ $debug ]]
        then
            debug "Debugging enabled: not deleting temporary path: $path"
        elif [[ -r $path ]]
        then
            rm -rf "$path"
        else
            debug "Temporary path doesn't exist, not deleting: $path"
        fi
    done
    [[ $report_dir ]] && rm -rf "$report_dir"
    return 0
}

function echo-unset-p {
    # Echo 0 if $1 is set, otherwise 1.  IOW, this returns the exit
    # code of [[ $1 ]] as STDOUT.
    [[ $1 ]]
    echo $?
}

function ensure-package-available {
    # If package $1 is available, return 0.  Otherwise, return 1, and
    # if $2 is set, give error otherwise verbose.  Outputting messages
    # here avoids repetition in callers.
    local package=$1
    local direct_p=$2
    local report_command_purpose=availability_probe

    if ! run_emacs --load $package &>/dev/null
    then
        report_skipped="$package is not installed; use --install-linters in a sandbox to install optional linters."
        if [[ $direct_p ]]
        then
            error "$package not available."
        else
            verbose 2 "$package not available."
        fi
        return 1
    fi
}

function ensure-tests-available {
    # If tests of type $1 (like "ERT") are available, return 0.  Otherwise, if
    # $2 is set, give an error and return 1; otherwise give verbose message.  $1
    # should have a corresponding predicate command, like ert-tests-p for ERT.
    local test_name=$1
    local test_command="$(printf '%s' "$test_name" | tr '[:upper:]' '[:lower:]')-tests-p"
    local direct_p=$2

    if ! $test_command
    then
        report_skipped="$test_name tests are not present in the project."
        if [[ $direct_p ]]
        then
            error "$test_name tests not found."
        else
            verbose 2 "$test_name tests not found."
        fi
        return 1
    fi
}

function echo_color {
    # This allows bold, italic, etc. without needing a function for
    # each variation.
    local color_code="COLOR_$1"
    shift

    if [[ $color ]]
    then
        echo -e "${!color_code}${@}${COLOR_off}"
    else
        echo "$@"
    fi
}
function debug {
    if [[ $debug ]]
    then
        function debug {
            echo_color yellow "DEBUG ($(ts)): $@" >&2
        }
        debug "$@"
    else
        function debug {
            true
        }
    fi
}
function error {
    echo_color red "ERROR ($(ts)): $@" >&2
    report-event error "$report_task" "$*"
    ((errors++))
    return 1
}
function die {
    [[ $@ ]] && error "$@"
    exit $errors
}
function warn {
    echo_color yellow "WARNING ($(ts)): $@" >&2
    report-event warning "$report_task" "$*"
    ((warnings++))
}
function log {
    echo "LOG ($(ts)): $@" >&2
}
function log_color {
    local color_name=$1
    shift
    echo_color $color_name "LOG ($(ts)): $@" >&2
}
function success {
    if [[ $verbose -ge 2 ]]
    then
        log_color green "$@" >&2
    fi
}
function verbose {
    # $1 is the verbosity level, rest are echoed when appropriate.
    if [[ $verbose -ge $1 ]]
    then
        [[ $1 -eq 1 ]] && local color_name=blue
        [[ $1 -eq 2 ]] && local color_name=cyan
        [[ $1 -ge 3 ]] && local color_name=white

        shift
        log_color $color_name "$@" >&2
    fi
}

function ts {
    date "+%Y-%m-%d %H:%M:%S"
}

function emacs-version {
    # Echo Emacs version number.

    # Don't use run_emacs function, which does more than we need.
    "${emacs_command[@]}" -Q --batch --eval "(princ emacs-version)" \
        || die "Unable to get Emacs version."
}

function rule-p {
    # Return 0 if $1 is a rule.
    case "$1" in
        all|compile|lint|lint-checkdoc|lint-compile|lint-declare|lint-elsa|lint-elint|lint-indent|lint-package|lint-regexps|test|tests|test-buttercup|test-ert|test-ert-interactive|batch|interactive)
            return 0 ;;
        *) return 1 ;;
    esac
}

function invalid-rule {
    local task=$1 hint
    case "$task" in
        tset|tets|tes|testing) hint=test ;;
        compiel|comiple|compil|build) hint=compile ;;
        lnit|litn|lints) hint=lint ;;
        *) hint=help ;;
    esac
    error "Unknown task '$task'. Try make $hint; run make help or ./makem.sh --capabilities --json for the complete task list."
    report-event next "make $hint" "./makem.sh --capabilities --json"
    exit 2
}

# * Rules

# These functions are intended to be called as rules, like a Makefile.
# Some rules test $1 to determine whether the rule is being called
# directly or from a meta-rule; if directly, an error is given if the
# rule can't be run, otherwise it's skipped.

function all {
    verbose 1 "Running all rules..."

    run-rule lint
    run-rule tests
}

function compile-batch {
    [[ $compile ]] || return 0
    unset compile  # Only compile once.

    verbose 1 "Compiling..."
    verbose 2 "Batch-compiling files..."
    debug "Byte-compile files: ${files_project_byte_compile[@]}"

    batch-byte-compile "${files_project_byte_compile[@]}"
}

function compile-each {
    [[ $compile ]] || return 0
    unset compile  # Only compile once.

    verbose 1 "Compiling..."
    debug "Byte-compile files: ${files_project_byte_compile[@]}"

    local compile_errors
    for file in "${files_project_byte_compile[@]}"
    do
        verbose 2 "Compiling file: $file..."
        byte-compile-file "$file" \
            || compile_errors=t
    done

    [[ ! $compile_errors ]]
}

function compile {
    if [[ $compile = batch ]]
    then
        compile-batch "$@"
    else
        compile-each "$@"
    fi
    local status=$?

    if [[ $compile_error_on_warn ]]
    then
        # Linting: just return status code, because lint rule will print messages.
        [[ $status = 0 ]]
    else
        # Not linting: print messages here.
        [[ $status = 0 ]] \
            && success "Compiling finished without errors." \
                || error "Compiling failed."
    fi
}

function batch {
    # Run Emacs in batch mode with ${args_batch_interactive[@]} and
    # with project source and test files loaded.
    verbose 1 "Executing Emacs with arguments: ${args_batch_interactive[@]}"

    run_emacs \
        $(args-load-files "${files_project_feature[@]}" "${files_project_test[@]}") \
        "${args_batch_interactive[@]}"
}

function interactive {
    # Run Emacs interactively.  Most useful with --sandbox and --install-deps.
    local load_file_args=$(args-load-files "${files_project_feature[@]}" "${files_project_test[@]}")
    verbose 1 "Running Emacs interactively..."
    verbose 2 "Loading files: ${load_file_args//--load /}"

    [[ $compile ]] && compile

    unset arg_batch
    run_emacs \
        $load_file_args \
        --eval "(load user-init-file)" \
        "${args_batch_interactive[@]}"
    arg_batch="--batch"
}

function lint {
    verbose 1 "Linting..."

    run-rule lint-checkdoc
    run-rule lint-compile
    run-rule lint-declare
    # NOTE: Elint doesn't seem very useful at the moment.  See comment
    # in lint-elint function.
    # lint-elint
    run-rule lint-indent
    run-rule lint-package
    run-rule lint-regexps
}

function lint-checkdoc {
    verbose 1 "Linting checkdoc..."

    run_emacs \
        --load="$elisp_checkdoc_file" \
        "${files_project_feature[@]}" \
        && success "Linting checkdoc finished without errors." \
            || error "Linting checkdoc failed."
}

function lint-compile {
    verbose 1 "Linting compilation..."

    compile_error_on_warn=true
    compile "${files_project_byte_compile[@]}" \
        && success "Linting compilation finished without errors." \
            || error "Linting compilation failed."
    unset compile_error_on_warn
}

function lint-declare {
    verbose 1 "Linting declarations..."

    run_emacs \
        --load "$elisp_check_declare_file" \
        -f makem-check-declare-files-and-exit \
        "${files_project_feature[@]}" \
        && success "Linting declarations finished without errors." \
            || error "Linting declarations failed."
}

function lint-elsa {
    verbose 1 "Linting with Elsa..."

    # MAYBE: Install Elsa here rather than in sandbox init, to avoid installing
    # it when not needed.  However, we should be careful to be clear about when
    # packages are installed, because installing them does execute code.
    run_emacs \
        --load elsa \
        -f elsa-run-files-and-exit \
        "${files_project_feature[@]}" \
        && success "Linting with Elsa finished without errors." \
            || error "Linting with Elsa failed."
}

function lint-elint {
    # NOTE: Elint gives a lot of spurious warnings, apparently because it doesn't load files
    # that are `require'd, so its output isn't very useful.  But in case it's improved in
    # the future, and since this wrapper code already works, we might as well leave it in.
    verbose 1 "Linting with Elint..."

    local errors=0
    for file in "${files_project_feature[@]}"
    do
        verbose 2 "Linting with Elint: $file..."
        run_emacs \
            --load "$elisp_elint_file" \
            --eval "(makem-elint-file \"$file\")" \
            && verbose 3 "Linting with Elint found no errors." \
                || { error "Linting with Elint failed: $file"; ((errors++)) ; }
    done

    [[ $errors = 0 ]] \
        && success "Linting with Elint finished without errors." \
            || error "Linting with Elint failed."
}

function lint-indent {
    verbose 1 "Linting indentation..."

    # Load project source files plus most test files so custom macros can
    # publish their indentation rules before we check for drift.  A few tests
    # require compressed core libraries on Nix runners; skip preloading those
    # and provide the small amount of indentation metadata they need directly.
    local lint_indent_load_files=("${files_project_feature[@]}")
    for file in "${files_project_test[@]}"
    do
        case "$file" in
            test/ogent-bench.el|test/ogent-edit-tests.el|test/ogent-profile.el)
                ;;
            *)
                lint_indent_load_files+=("$file")
                ;;
        esac
    done

    run_emacs \
        --load "$(elisp-lint-indent-file)" \
        --eval "(put 'ogent-bench 'lisp-indent-function 'defun)" \
        --eval "(put 'ogent-bench-multi 'lisp-indent-function 0)" \
        --eval "(put 'ogent-with-profile 'lisp-indent-function 0)" \
        $(args-load-files "${lint_indent_load_files[@]}") \
        --funcall makem-lint-indent-batch-and-exit \
        "${files_project_feature[@]}" "${files_project_test[@]}" \
        && success "Linting indentation finished without errors." \
            || error "Linting indentation failed."
}

function lint-package {
    ensure-package-available package-lint "$1" || { [[ $1 ]] && return 1; return 0; }

    verbose 1 "Linting package..."

    run_emacs \
        --load package-lint \
        --eval "(setq package-lint-main-file \"$(package-main-file)\")" \
        --funcall package-lint-batch-and-exit \
        "$(package-main-file)" \
        && success "Linting package finished without errors." \
            || error "Linting package failed."
}

function lint-regexps {
    ensure-package-available relint "$1" || { [[ $1 ]] && return 1; return 0; }

    verbose 1 "Linting regexps..."

    run_emacs \
        --load relint \
        --funcall relint-batch \
        "${files_project_source[@]}" \
        && success "Linting regexps finished without errors." \
            || error "Linting regexps failed."
}

function tests {
    verbose 1 "Running all tests..."

    run-rule test-ert
    run-rule test-buttercup
}

function test-ert-interactive {
    verbose 1 "Running ERT tests interactively..."

    unset arg_batch
    run_emacs \
        $(args-load-files "${files_project_test[@]}") \
        --eval "(ert-run-tests-interactively t)"
    arg_batch="--batch"
}

function test-buttercup {
    ensure-tests-available Buttercup "$1" || { [[ $1 ]] && return 1; return 0; }
    compile || die

    verbose 1 "Running Buttercup tests..."

    run_emacs \
        $(args-load-files "${files_project_test[@]}") \
        --load "$elisp_buttercup_file" \
        --eval "(progn (setq backtrace-on-error-noninteractive nil) (buttercup-run))" \
        && success "Buttercup tests finished without errors." \
            || error "Buttercup tests failed."
}

function test-ert {
    ensure-tests-available ERT "$1" || { [[ $1 ]] && return 1; return 0; }
    compile || die

    verbose 1 "Running ERT tests..."
    debug "Test files: ${files_project_test[@]}"

    run_emacs \
        $(args-load-files "${files_project_test[@]}") \
        -f ert-run-tests-batch-and-exit \
        && success "ERT tests finished without errors." \
            || error "ERT tests failed."
}

# * Defaults

test_files_regexp='^((tests?|t)/)|-tests?.el$|^test-'

emacs_command=("emacs")
errors=0
# TODO: Do something with number of warnings?
warnings=0
verbose=0
compile=true
arg_batch="--batch"
compile=each

# Diagnostics use stderr.  Honor the standard presence-based NO_COLOR contract.
[[ -t 2 && ! ${NO_COLOR+x} ]] && color=true

# TODO: Using the current directory (i.e. a package's repo root directory) in
# load-path can cause weird errors in case of--you guessed it--stale .ELC files,
# the zombie problem that just won't die.  It's incredible how many different ways
# this problem presents itself.  In this latest example, an old .ELC file, for a
# .EL file that had since been renamed, was present on my local system, which meant
# that an example .EL file that hadn't been updated was able to "require" that .ELC
# file's feature without error.  But on another system (in this case, trying to
# setup CI using GitHub Actions), the old .ELC was not present, so the example .EL
# file was not able to load the feature, which caused a byte-compilation error.

# In this case, I will prevent such example files from being compiled.  But in
# general, this can cause weird problems that are tedious to debug.  I guess
# the best way to fix it would be to actually install the repo's code as a
# package into the sandbox, but doing that would require additional tooling,
# pulling in something like Quelpa or package-build--and if the default recipe
# weren't being used, the actual recipe would have to be fetched off MELPA or
# something, which seems like getting too smart for our own good.

# TODO: Emit a warning if .ELC files that don't match any .EL files are detected.

# ** Colors

COLOR_off='\e[0m'
COLOR_black='\e[0;30m'
COLOR_red='\e[0;31m'
COLOR_green='\e[0;32m'
COLOR_yellow='\e[0;33m'
COLOR_blue='\e[0;34m'
COLOR_purple='\e[0;35m'
COLOR_cyan='\e[0;36m'
COLOR_white='\e[0;37m'

# ** Package system args

args_package_archives=(
    --eval "(add-to-list 'package-archives '(\"gnu\" . \"https://elpa.gnu.org/packages/\") t)"
    --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)"
)

args_package_init=(
    --eval "(package-initialize)"
)

# * Args

# Initialize reporting before getopt, so invalid options also have a contract.
original_args=("$@")
printf -v report_rerun '%q ' "$0" "${original_args[@]}"
for argument in "$@"
do
    [[ $argument == -- ]] && break
    if [[ $argument == --json ]]
    then
        if ! command -v python3 >/dev/null 2>&1
        then
            report-bootstrap-failure python3
        fi
        report_dir=$(mktemp --tmpdir -d "makem-report-XXXXXX") || report-bootstrap-failure mktemp
        : > "$report_dir/events.jsonl"
        exec 3>&1
        exec 1>&2
        unset color
        break
    fi
done
trap 'report-finish "$?"' EXIT
trap 'report-interrupt 130' INT
trap 'report-interrupt 143' TERM

if ! command -v getopt >/dev/null 2>&1
then
    error "GNU getopt is required to parse options. Install GNU getopt and run ./makem.sh --help."
    report-event next "Install GNU getopt and run ./makem.sh --help."
    exit 3
fi

args=$(getopt -n "$0" \
              -o dhce:E:i:s::vf:C \
              -l compile-batch,exclude:,emacs:,install-deps,install-linters,debug,debug-load-path,help,install:,verbose,file:,no-color,no-compile,sandbox::,json,capabilities \
              -- "$@") \
    || {
        error "Invalid option. Run ./makem.sh --help or make help for supported options."
        for argument in "${original_args[@]}"
        do
            case "$argument" in
                --emax*|--emacsx*)
                    error "Use --emacs=/path/to/emacs to select Emacs."
                    report-event next "./makem.sh --json --emacs=/path/to/emacs test" ;;
                --jason|--jsno)
                    error "Use --json for machine-readable reports."
                    report-event next "./makem.sh --json test" ;;
            esac
        done
        report-event next "./makem.sh --help"
        exit 2
    }
eval set -- "$args"

while true
do
    case "$1" in
        --install-deps)
            install_deps=true
            ;;
        --install-linters)
            install_linters=true
            ;;
        -d|--debug)
            debug=true
            verbose=2
            args_debug=(--eval "(setq init-file-debug t)"
                        --eval "(setq debug-on-error t)")
            ;;
        --debug-load-path)
            debug_load_path=true
            ;;
        -h|--help)
            if [[ $report_dir ]]; then report-event help "$(usage)"; else usage; fi
            exit
            ;;
        -c|--compile-batch)
            debug "Compiling files in batch mode"
            compile=batch
            ;;
        -E|--emacs)
            shift
            emacs_command=("$1")
            ;;
        -i|--install)
            shift
            args_sandbox_package_install+=(--eval "(package-install '$1)")
            ;;
        -s|--sandbox)
            sandbox=true
            shift
            sandbox_dir="$1"

            if ! [[ $sandbox_dir ]]
            then
                debug "No sandbox dir: installing dependencies."
                install_deps=true
            else
                debug "Sandbox dir: $1"
            fi
            ;;
        -v|--verbose)
            ((verbose++))
            ;;
        -e|--exclude)
            shift
            debug "Excluding file: $1"
            files_exclude+=("$1")
            ;;
        -f|--file)
            shift
            args_files+=("$1")
            ;;
        --no-color)
            unset color
            ;;
        --json)
            ;;
        --capabilities)
            capabilities=true
            ;;
        -C|--no-compile)
            unset compile
            ;;
        --)
            # Remaining args (required; do not remove)
            shift
            rest=("$@")
            break
            ;;
    esac

    shift
done

if [[ $capabilities ]]
then
    if [[ $report_dir ]]; then report-event capabilities; else usage; fi
    exit 0
fi

# Validate the complete plan before generating helpers or starting Emacs.
if [[ ${#rest[@]} == 0 ]]
then
    error "No task selected. Try make test, make lint, or ./makem.sh --capabilities --json."
    report-event next "make test format=json" "./makem.sh --capabilities --json"
    exit 2
fi
requested_tasks=()
for rule in "${rest[@]}"
do
    rule-p "$rule" || invalid-rule "$rule"
    requested_tasks+=("$rule")
    if [[ $rule == batch || $rule == interactive ]]
    then
        break
    fi
done
report-event requested "${requested_tasks[@]}"
if [[ $report_dir && " ${requested_tasks[*]} " =~ " interactive "|" test-ert-interactive " ]]
then
    error "JSON reports require noninteractive tasks. Use batch or test-ert, or omit --json."
    report-event next "./makem.sh --json batch" "./makem.sh --json test-ert"
    exit 2
fi
for executable in "${emacs_command[0]}" git getopt mktemp gzip
do
    if ! command -v "$executable" >/dev/null 2>&1
    then
        error "Required executable '$executable' is unavailable. Install it or select Emacs with --emacs=/path/to/emacs (make EMACS=/path/to/emacs)."
        report-event next "Install the missing executable or pass --emacs=/path/to/emacs."
        exit 3
    fi
done

debug "ARGS: $args"
debug "Remaining args: ${rest[@]}"

# Elisp load files (output these once only).
elisp_buttercup_file=$(elisp-buttercup-file)
elisp_elint_file=$(elisp-elint-file)
elisp_checkdoc_file=$(elisp-checkdoc-file)
elisp_byte_compile_file=$(elisp-byte-compile-file)
elisp_check_declare_file=$(elisp-check-declare-file)
elisp_lint_indent_file=$(elisp-lint-indent-file)
elisp_package_initialize_file=$(elisp-package-initialize-file)

# Since those variables' values come from functions called in
# subshells, those functions can't assign to the global value of
# paths_temp, so we add their values in this loop (this is a bit
# messy, but Bash scripting makes this awkward).
variable_names=(elisp_buttercup_file elisp_elint_file
                elisp_checkdoc_file elisp_byte_compile_file
                elisp_check_declare_file elisp_lint_indent_file
                elisp_package_initialize_file)
for var in "${variable_names[@]}"
do
    paths_temp+=("${!var}")
done

# * Main

# Change to project root directory first.
root_dir=$(project-root) || exit 3
if [[ ! $root_dir ]] || ! cd "$root_dir"
then
    error "No project Git root found. Run makem.sh from a Git project with tracked Elisp files."
    exit 3
fi

# Discover project files.
files_project_feature=($(files-project-feature))
files_project_test=($(files-project-test))
files_project_byte_compile=("${files_project_feature[@]}" "${files_project_test[@]}")

if [[ ${args_files[@]} ]]
then
    # Add specified files.
    files_project_feature+=("${args_files[@]}")
    files_project_byte_compile+=("${args_files[@]}")
fi

debug "EXCLUDING FILES: ${files_exclude[@]}"
debug "FEATURE FILES: ${files_project_feature[@]}"
debug "TEST FILES: ${files_project_test[@]}"
debug "BYTE-COMPILE FILES: ${files_project_byte_compile[@]}"
debug "PACKAGE-MAIN-FILE: $(package-main-file)"

if ! [[ ${files_project_feature[@]} ]]
then
    error "No files specified and not in a git repo."
    exit 3
fi

# Set load path.
args_load_paths=($(args-load-path))

# If rules include linters and sandbox-dir is unspecified, install
# linters automatically.
if [[ $sandbox && ! $sandbox_dir ]] && [[ "${rest[@]}" =~ lint ]]
then
    debug "Installing linters automatically."
    install_linters=true
fi

# Initialize sandbox.
[[ $sandbox ]] && {
    sandbox
    args_load_paths+=($(args-load-path-sandbox))
}

debug "LOAD PATH ARGS: ${args_load_paths[@]}"

# Run rules.
for rule in "${rest[@]}"
do
    if [[ $batch || $interactive ]]
    then
        debug "Adding batch/interactive argument: $rule"
        args_batch_interactive+=("$rule")

    elif [[ $rule = batch ]]
    then
        # Remaining arguments are passed to Emacs.
        batch=true
    elif [[ $rule = interactive ]]
    then
        # Remaining arguments are passed to Emacs.
        interactive=true

    elif [[ $rule != test ]] && rule-p "$rule"
    then
        # Pass called-directly as $1 to indicate that the rule is
        # being called directly rather than from a meta-rule.
        run-rule "$rule" called-directly
    elif [[ $rule = test ]]
    then
        # Allow the "tests" rule to be called as "test".  Since "test"
        # is a shell builtin, this workaround is required.
        run-rule tests
    else
        invalid-rule "$rule"
    fi
done

# Batch/interactive rules.
[[ $batch ]] && run-rule batch
[[ $interactive ]] && run-rule interactive

if [[ $errors -gt 0 ]]
then
    log_color red "Finished with $errors errors."
else
    success "Finished without errors."
fi

if [[ $report_dir && $errors -gt 0 ]]
then
    exit 1
fi
exit "$errors"

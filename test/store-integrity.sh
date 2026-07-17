#!/usr/bin/env bash
# store-integrity.sh --- E2E store-integrity hash audit for the ogent suite.
#
# ogent-aq8.4: belt to the tripwire's suspenders (test/ogent-test-helper.el).
# Hashes every real-store path, runs the full ert suite, re-hashes, and
# fails loudly on any drift.  This catches write channels the in-Lisp
# chokepoint advice misses: raw write-region, native sqlite mutation,
# subprocesses, and store code that does not exist yet.
#
# Path list: mirrors the module defaults documented at
# `ogent-test-store-guard-paths' (AUDIT 2026-07-16, ogent-aq8.1) in
# test/ogent-test-helper.el.  When a new persistent store lands, extend
# the guard there AND the derivation below.
#
# Contract per audited path:
#   absent before -> must still be absent after (recorded as `absent')
#   file          -> sha256, size, and mtime must all be identical
#   directory     -> exact recursive inventory (files hashed with size
#                    and mtime, subdirectories listed) must be identical
#
# Exit status: 0 clean; 1 suite failed (stores clean); 2 store drift.

set -u -o pipefail
LC_ALL=C
export LC_ALL

EMACS="${EMACS:-emacs}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2
cd "$ROOT" || exit 2

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
  else
    shasum -a 256 -- "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# Print "size|mtime" for a path (GNU stat, BSD fallback).
stat_sm() {
  stat -c '%s|%Y' -- "$1" 2>/dev/null || stat -f '%z|%m' -- "$1" 2>/dev/null
}

# Emit every real-store path, one per line: the project-root stores plus
# each location the audited module defaults resolve under
# user-emacs-directory, org-directory, HOME, CODEX_HOME, XDG_DATA_HOME,
# or DOOMDIR.  Emacs computes the Emacs-side bases so the list matches
# exactly what the suite's own batch Emacs would resolve.
derive_store_paths() {
  {
    # ogent-analytics-db-name / ogent-ledger-file: relative defaults
    # resolved against the project root at use time.
    printf '%s\n' \
      "$ROOT/.ogent-analytics.db" \
      "$ROOT/.ogent/ledger.org"
    "$EMACS" --batch --eval '(progn
      (require (quote org))
      (let ((paths
             (list
              ;; ogent-companion-link-registry-file (ogent-companion.el)
              (expand-file-name "ogent-companion-links.el" user-emacs-directory)
              ;; ogent-capture-notes-file / -companion-file (ogent-notes.el)
              (expand-file-name "ogent-notes.org" org-directory)
              (expand-file-name "ogent-companion.org" org-directory)
              ;; ogent-session-directory (ogent-session.el)
              (expand-file-name "ogent-sessions/" user-emacs-directory)
              ;; ogent-anthropic-oauth-tokens-dir, which also contains the
              ;; ogent-anthropic-oauth--token-file default target tokens.el
              (expand-file-name "ogent/anthropic-oauth/" user-emacs-directory)
              ;; ogent-codemap-cache-directory (ogent-codemap-task.el)
              (expand-file-name "codemap-cache" user-emacs-directory)
              ;; ogent-prompts-snippet-dir (ogent-prompts-yasnippet.el)
              (expand-file-name "ogent-snippets" user-emacs-directory)
              ;; ogent-issues-agenda-file nil-derivation root
              ;; (ogent-issues-bd.el: ogent/beads/<project>-<hash>.org)
              (expand-file-name "ogent/beads/" user-emacs-directory)
              ;; ogent-codex-oauth-auth-file nil fallback (ogent-codex-oauth.el)
              (expand-file-name "auth.json" (or (getenv "CODEX_HOME") "~/.codex"))
              ;; ogent-anthropic-oauth--find-existing-token-file probes
              (expand-file-name ".local/cache/ogent/anthropic-oauth/tokens.el"
                                user-emacs-directory)
              (expand-file-name "emacs/ogent/anthropic-oauth/tokens.el"
                                (or (getenv "XDG_DATA_HOME")
                                    (expand-file-name "~/.local/share")))))
            (doomdir (getenv "DOOMDIR")))
        (when doomdir
          (push (expand-file-name ".local/cache/ogent/anthropic-oauth/tokens.el"
                                  doomdir)
                paths))
        ;; ogent-anthropic-oauth--known-token-paths: HOME probes; the
        ;; primary --token-file write would land on whichever exists.
        (dolist (known (list
                        "~/.emacs.d/ogent/anthropic-oauth/tokens.el"
                        "~/.emacs.d/.local/cache/ogent/anthropic-oauth/tokens.el"
                        "~/.config/emacs/ogent/anthropic-oauth/tokens.el"
                        "~/.config/doom/ogent/anthropic-oauth/tokens.el"
                        "~/.doom.d/ogent/anthropic-oauth/tokens.el"
                        "~/vault/projects/config/nixconfig/home-nixpkgs/doom-emacs/.local/cache/ogent/anthropic-oauth/tokens.el"))
          (push (expand-file-name known) paths))
        (dolist (p (nreverse paths))
          (princ (directory-file-name p))
          (terpri))))' 2>/dev/null
  } | awk 'NF && !seen[$0]++'
}

# Write one sorted snapshot line per audited object to $1:
#   <sha256>|<size>|<mtime>|<path>   regular file (or resolvable symlink)
#   present-dir|||<path>             existing directory
#   absent|||<path>                  nonexistent guard path
snapshot() {
  local out="$1" p f h sm
  {
    for p in "${GUARD_PATHS[@]}"; do
      if [ -d "$p" ]; then
        printf 'present-dir|||%s\n' "$p"
        while IFS= read -r f; do
          if [ -d "$f" ]; then
            printf 'present-dir|||%s\n' "$f"
          else
            h="$(sha256 "$f")"
            [ -n "$h" ] || h=unreadable
            sm="$(stat_sm "$f")"
            [ -n "$sm" ] || sm='|'
            printf '%s|%s|%s\n' "$h" "$sm" "$f"
          fi
        done < <(find "$p" -mindepth 1 2>/dev/null)
      elif [ -e "$p" ] || [ -L "$p" ]; then
        h="$(sha256 "$p")"
        [ -n "$h" ] || h=unreadable
        sm="$(stat_sm "$p")"
        [ -n "$sm" ] || sm='|'
        printf '%s|%s|%s\n' "$h" "$sm" "$p"
      else
        printf 'absent|||%s\n' "$p"
      fi
    done
  } | sort > "$out"
}

# Run the full ert suite exactly the way CI's Test step does, including
# the Nix jka-compr preload workaround (see .github/workflows/ci.yml).
run_suite() {
  local compat_dir lisp_dir
  compat_dir="$(mktemp -d "${TMPDIR:-/tmp}/ogent-jka-compat.XXXXXX")" || return 2
  lisp_dir="$("$EMACS" --batch --eval '(princ lisp-directory)' 2>/dev/null)"
  if [ -n "$lisp_dir" ] && [ -f "$lisp_dir/jka-compr.el.gz" ]; then
    gzip -dc "$lisp_dir/jka-compr.el.gz" > "$compat_dir/jka-compr.el"
  elif [ -n "$lisp_dir" ] && [ -f "$lisp_dir/jka-compr.el" ]; then
    cp "$lisp_dir/jka-compr.el" "$compat_dir/jka-compr.el"
  fi
  "$EMACS" --batch \
    -L "$compat_dir" \
    -l jka-compr \
    -L lisp -L lisp/ui -L test -L test/ui \
    -l test/ogent-test-helper.el \
    --eval '(progn
              (dolist (file (ogent-test--files))
                (load-file file))
              (ert-run-tests-batch-and-exit))'
}

# Compare snapshots $1 (before) and $2 (after); log every drifted path
# with hash, size delta, and mtime.  Increments the global drift_count.
report_drift() {
  local bfile="$1" afile="$2" h s m p vb va bh bs bm ah as am
  declare -A B A
  while IFS='|' read -r h s m p; do B["$p"]="$h|$s|$m"; done < "$bfile"
  while IFS='|' read -r h s m p; do A["$p"]="$h|$s|$m"; done < "$afile"
  while IFS= read -r p; do
    vb="${B[$p]-absent||}"
    va="${A[$p]-removed||}"
    [ "$vb" = "$va" ] && continue
    drift_count=$((drift_count + 1))
    IFS='|' read -r bh bs bm <<<"$vb"
    IFS='|' read -r ah as am <<<"$va"
    printf 'DRIFT: %s\n' "$p"
    printf '  before: %s size=%s mtime=%s\n' "$bh" "${bs:--}" "${bm:--}"
    printf '  after:  %s size=%s mtime=%s' "$ah" "${as:--}" "${am:--}"
    if [[ "$bs" =~ ^[0-9]+$ && "$as" =~ ^[0-9]+$ ]]; then
      printf ' size-delta=%+d' "$((as - bs))"
    fi
    printf '\n'
  done < <(cat <(cut -d'|' -f4- "$bfile") <(cut -d'|' -f4- "$afile") | sort -u)
}

echo "== ogent store-integrity audit (ogent-aq8.4) =="

GUARD_PATHS=()
while IFS= read -r line; do
  GUARD_PATHS+=("$line")
done < <(derive_store_paths)

if [ "${#GUARD_PATHS[@]}" -lt 12 ]; then
  echo "FATAL: store path derivation returned only ${#GUARD_PATHS[@]} paths" >&2
  echo "       (is \"$EMACS\" runnable?)" >&2
  exit 2
fi

echo "-- auditing ${#GUARD_PATHS[@]} real-store paths --"
for p in "${GUARD_PATHS[@]}"; do
  if [ -d "$p" ]; then
    printf '  [dir:%4d] %s\n' "$(find "$p" -mindepth 1 2>/dev/null | wc -l)" "$p"
  elif [ -e "$p" ]; then
    printf '  [file    ] %s\n' "$p"
  else
    printf '  [absent  ] %s\n' "$p"
  fi
done

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/ogent-store-integrity.XXXXXX")" || exit 2
before="$state_dir/before.snapshot"
after="$state_dir/after.snapshot"

snapshot "$before"
echo "-- pre-suite snapshot written: $before --"

echo "-- running full ert suite --"
run_suite
suite_status=$?
echo "-- suite exit status: $suite_status --"

snapshot "$after"
echo "-- post-suite snapshot written: $after --"

drift_count=0
report_drift "$before" "$after"

if [ "$drift_count" -gt 0 ]; then
  echo "STORE-INTEGRITY: FAIL - $drift_count real-store path(s) drifted"
  echo "  snapshots retained in $state_dir"
  exit 2
fi
echo "STORE-INTEGRITY: clean - no real-store drift across the suite run"
if [ "$suite_status" -ne 0 ]; then
  echo "STORE-INTEGRITY: NOTE - the suite itself failed (exit $suite_status)"
  exit 1
fi
exit 0

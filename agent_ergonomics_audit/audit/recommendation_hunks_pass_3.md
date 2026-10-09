# Pass 3 primary recommendation hunks

This file records exact primary-commit source hunks. The old side is each commit's parent; the new side is that primary commit, not the final source freeze. Later corrections are followups to these eleven recommendations and do not increase their count. File locations under each heading are commit-qualified. The baseline for the pass is `b3caf9300c7336ef812ed061158f851c5a47ccf7`.

`applied_changes_pass_3.jsonl` stores full selected before/after hunk excerpts and line coordinates. `git show COMMIT -- PATH` reproduces every displayed hunk.

## R013 — Named approval-aware calls with typed outcomes

Primary commit: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea`. Parent: `b3caf9300c7336ef812ed061158f851c5a47ccf7`.

The discoverable SDK described tools but did not provide a named, versioned execution entry point. Positional wrappers and exceptions forced callers to reconstruct call shapes and policy outcomes.

Add ogent-agent-call and the contract_version 1 result envelope. Validate named arguments before approval; return approval_required, denied, proposed, or typed errors through existing review and ledger owners.

Regression: `audit/regression_tests/R013__named_calls.test.sh` — Named read and JSON results, validation before policy, denial and approval-required refusal, failed execution ledger; broad selector also covers the following SDK recommendations.

### lisp/ogent-agent.el

Before: `b3caf9300c7336ef812ed061158f851c5a47ccf7:lisp/ogent-agent.el:17`; after: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ogent-agent.el:18`.

```diff
@@ -17,7 +18,16 @@
     ((or 'nil 'plist) data)
     ('json (concat (json-serialize data :null-object :json-null
                                    :false-object :json-false) "\n"))
-    (_ (user-error "Use nil, 'plist, or 'json for the agent report format"))))
+    (_ (user-error "Use nil, (quote plist), or (quote json) for the agent report format"))))
+
+(defun ogent-agent-call (name args &optional format)
+  "Execute tool NAME with named ARGS and return its structured result.
+Return a plist by default or JSON when FORMAT is `json'.  Validate FORMAT
+before execution.  Calls respect approval policy and never grant themselves
+permission.  For example:
+  (ogent-agent-call \"read_file\" \='(:file_path \"README.org\" :limit 20))"
+  (ogent-agent--output nil format)
+  (ogent-agent--output (ogent-tool-execution-call name args) format))
 
 (defun ogent-agent--boolean (value)
   "Return a JSON-compatible boolean for VALUE."
```

### lisp/ogent-tool-approval.el

Before: `b3caf9300c7336ef812ed061158f851c5a47ccf7:lisp/ogent-tool-approval.el:170`; after: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ogent-tool-approval.el:170`.

```diff
@@ -170,9 +170,10 @@ If ARGS is non-nil, create a pattern matching those specific args."
                (equal name (ogent-tool--name-string denied)))
              ogent-tool--denied-tools)))
 
-(defun ogent-tool-approval-check (tool-name tool-args)
+(defun ogent-tool-approval-check (tool-name tool-args &optional no-prompt)
   "Return approval decision for TOOL-NAME with TOOL-ARGS.
-The return value is `approved' or `denied'."
+Return `approved' or `denied', or `required' when NO-PROMPT prevents
+an interactive approval question.  Apply the same policy in either mode."
   (let ((tool-symbol (ogent-tool--name-symbol tool-name)))
     (cond
      ((not tool-symbol) 'denied)
```

### lisp/ogent-tool-execution.el

Before: `b3caf9300c7336ef812ed061158f851c5a47ccf7:lisp/ogent-tool-execution.el:14`; after: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ogent-tool-execution.el:14`.

```diff
@@ -14,6 +14,65 @@
 (declare-function ogent-ui--is-edit-tool-p "ogent-ui-toolcalls")
 (declare-function ogent-ui--show-diff-for-tool "ogent-ui-toolcalls")
 
+(defun ogent-tool-execution-result (name status &optional data code message)
+  "Return a versioned result for NAME with STATUS and DATA.
+Include a typed error with CODE and MESSAGE when supplied."
+  (list :contract_version "1" :tool (format "%s" name) :status status
+        :data (or data :json-null)
+        :error (if code (list :code code :message message
+                             :recovery "Inspect ogent-agent-describe for arguments and policy; correct the call before retrying")
+                 :json-null)
+        :next []))
+
+(defun ogent-tool-execution-call (name args)
+  "Execute registered NAME with named ARGS and return a typed result.
+Validate before approval.  Never prompt for approval: return approval_required
+when policy needs a decision.  Preserve the existing edit review and ledger
+owners.  Prefer registered structured result functions when available."
+  (let ((phase "unknown_tool") spec canonical schema)
+    (condition-case err
+        (progn
+          (setq spec (ogent-tool-spec-get name))
+          (unless spec
+            (user-error "%s" (ogent-tool-contract-name-hint
+                              name (mapcar (lambda (item) (plist-get item :name))
+                                           ogent-tool-registry))))
+          (setq name (plist-get spec :name)
+                phase "invalid_arguments"
+                schema (plist-put (copy-sequence spec) :args
+                                  (append (plist-get spec :args)
+                                          (plist-get spec :result-args))))
+          (let ((values (ogent-tool-contract-values schema args)))
+            (setq canonical
+                  (cl-loop for argument in (plist-get schema :args)
+                           for value in values
+                           unless (and (plist-get argument :optional) (null value))
+                           append (list (intern (concat ":" (plist-get argument :name))) value))))
+          (pcase (ogent-tool-approval-check name canonical t)
+            ('required
+             (ogent-tool-execution-result
+              name "approval_required" nil "approval_required"
+              "This call needs user approval under the current effects policy; use the normal tool review flow or an existing explicit allow rule"))
+            ('denied
+             (ogent-tool-execution-result
+              name "denied" nil "denied" "Current approval policy denies this tool; ask the user to review the decision"))
+            (_
+             (setq phase "unavailable")
+             (unless (equal spec (ogent-tool-spec-get name))
+               (user-error "Registry entry changed before execution; rediscover the tool and retry"))
+             (require 'ogent-ui-toolcalls)
+             (setq phase "execution_failed")
+             (if (ogent-ui--is-edit-tool-p (symbol-name name))
+                 (progn
+                   (ogent-ui--show-diff-for-tool (symbol-name name) canonical)
+                   (ogent-tool-execution-result name "proposed" (list :review_required t)))
+               (let ((data (ogent-ui--execute-tool name canonical t)))
+                 (ogent-tool-execution-result
+                  name "ok" (if (plist-get spec :result-function) data
+                                (list :value data))))))))
+      (error (ogent-tool-execution-result name "error" nil phase
+                                          (error-message-string err))))))
+
 (defun ogent-tool-execution-wrapper (spec)
   "Return a gptel function enforcing policy and ledger recording for SPEC.
 Adapt gptel's callback-first convention to ogent's callback-last async specs.
```

### lisp/ui/ogent-ui-toolcalls.el

Before: `b3caf9300c7336ef812ed061158f851c5a47ccf7:lisp/ui/ogent-ui-toolcalls.el:239`; after: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ui/ogent-ui-toolcalls.el:239`.

```diff
@@ -239,16 +239,19 @@ Results are displayed in the buffer."
   "Build a ledger tool-call plist for NAME with ARGS."
   (list :name (ogent-tool--name-string name) :args args))
 
-(defun ogent-ui--execute-tool (name args)
-  "Execute tool NAME with ARGS and return result string.
+(defun ogent-ui--execute-tool (name args &optional structured)
+  "Execute tool NAME with ARGS and return its result.
 Looks up tool in `ogent-tool-registry' and calls its function.
+When STRUCTURED is non-nil, use its declared result function and extra
+result arguments, and re-signal failures after recording them.
 Records start/finish to the proof ledger (a no-op unless
 `ogent-ledger-enabled') and, when `ogent-debug' is loaded, appends to
 the inspectable tool-call history that powers `ogent-debug-replay-tool'."
   (if-let* ((tool-symbol (ogent-tool--name-symbol name))
             (spec (and (fboundp 'ogent-tool-spec-get)
                        (ogent-tool-spec-get tool-symbol)))
-            (func (plist-get spec :function)))
+            (func (or (and structured (plist-get spec :result-function))
+                      (plist-get spec :function))))
       (let* ((tool-call (ogent-ui--tool-ledger-call name args))
              ;; History entries key on a symbol name and carry an id.
              (history-call (list :id (format "tool-%d" (abs (random)))
```


## R014 — Bounded file pages with exact long-line continuation

Primary commit: `0829b080a5e90402a2a2234667818e741222db69`. Parent: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea`.

Text reading could truncate inside the output budget without a machine-readable character position from which to resume.

Add structured lines, one-based offset/column positions, content snapshot, total count and next position; retain explicit text rendering for legacy callers.

Regression: `audit/regression_tests/R014__structured_reads.test.sh` — Structured pages, empty/invalid inputs and long-line continuation without omitted or duplicated characters.

### lisp/ogent-tool-results.el

Before: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ogent-tool-results.el:0`; after: `0829b080a5e90402a2a2234667818e741222db69:lisp/ogent-tool-results.el:1`.

```diff
@@ -0,0 +1,79 @@
+;;; ogent-tool-results.el --- Structured file tool results -*- lexical-binding: t; -*-
+
+;;; Commentary:
+;; Return bounded pages with explicit positions and snapshot identities.
+;; Keep source data separate from legacy human-readable tool rendering.
+
+;;; Code:
+
+(require 'json)
+(require 'ogent-tools)
+
+(defun ogent-tool-results-format (data format)
+  "Return DATA as a plist or serialize it according to FORMAT."
+  (pcase format
+    ('plist data)
+    ('json (concat (json-serialize data :null-object :json-null
+                                   :false-object :json-false) "\n"))
+    (_ (user-error "Use (quote plist) or (quote json) for structured tool results"))))
+
+(defun ogent-tool-results-read (file-path &optional offset limit column)
+  "Return a bounded structured page from FILE-PATH at OFFSET and COLUMN.
+Count lines from one and columns from one.  LIMIT defaults to 200 lines.
+Preserve a continuation position even when a single line exceeds the output
+budget.  Snapshot the decoded content so callers can detect changed pages."
+  (unless (and (stringp file-path) (not (string-empty-p file-path)))
+    (user-error "Provide a nonempty file_path; use glob to discover files"))
+  (let* ((path (ogent-tools--resolve-path file-path))
+         (offset (or offset 1)) (limit (or limit 200)) (column (or column 1))
+         (budget ogent-tools-max-output-chars))
+    (dolist (position (list offset column))
+      (unless (and (integerp position) (> position 0))
+        (user-error "Use positive integer offset and column positions starting at 1")))
+    (unless (and (integerp limit) (> limit 0) (<= limit ogent-tools-max-file-lines))
+      (user-error "Use a positive limit no larger than %d lines" ogent-tools-max-file-lines))
+    (unless (and (integerp budget) (> budget 0))
+      (user-error "Set ogent-tools-max-output-chars to a positive integer"))
+    (unless (and (file-regular-p path) (file-readable-p path))
+      (user-error "File not readable: %s; use glob to choose a readable regular file" path))
+    (with-temp-buffer
+      (insert-file-contents path)
+      (when (search-forward "\0" nil t)
+        (user-error "Binary file detected: %s; choose a text file" path))
+      (let* ((content (buffer-string))
+             (lines (unless (string-empty-p content) (split-string content "\n")))
+             (snapshot (secure-hash 'sha256 content))
+             page (used 0) (line-number offset) (next-column column))
+        (when (string-suffix-p "\n" content) (setq lines (butlast lines)))
+        (unless (or (and (null lines) (= offset 1) (= column 1))
+                    (and (<= offset (length lines))
+                         (<= column (1+ (length (nth (1- offset) lines))))))
+          (user-error "Position exceeds file contents; restart with offset=1 and column=1"))
+        (while (and (<= line-number (length lines))
+                    (< (length page) limit) (< used budget))
+          (let* ((line (nth (1- line-number) lines))
+                 (start (1- next-column))
+                 (available (- budget used))
+                 (text (substring line start (min (length line) (+ start available))))
+                 (partial (< (+ start (length text)) (length line))))
+            (push (list :number line-number :column next-column :text text
+                        :partial (if partial t :json-false)) page)
+            (cl-incf used (length text))
+            (if partial
+                (setq next-column (+ next-column (length text)) used budget)
+              (cl-incf line-number)
+              (setq next-column 1)
+              ;; Account for separators included in the content string.
+              (when (< used budget) (cl-incf used)))))
+        (setq page (nreverse page))
+        (let ((more (<= line-number (length lines))))
+          (list :path path :snapshot snapshot :total_lines (length lines)
+                :offset offset :column column :limit limit
+                :lines (vconcat page)
+                :content (mapconcat (lambda (line) (plist-get line :text)) page "\n")
+                :has_more (if more t :json-false)
+                :next_offset (if more line-number :json-null)
+                :next_column (if more next-column :json-null)))))))
+
+(provide 'ogent-tool-results)
+;;; ogent-tool-results.el ends here
```

### lisp/ogent-tools.el

Before: `2fbc1561435ab8d384a4df75cdec5959bb0e19ea:lisp/ogent-tools.el:240`; after: `0829b080a5e90402a2a2234667818e741222db69:lisp/ogent-tools.el:242`.

```diff
@@ -240,11 +242,16 @@ TYPE is `stdout' or `stderr'."
 
 ;;; Tool: Read File
 
-(defun ogent-tool--read-file (file-path &optional offset limit)
+(defun ogent-tool--read-file (file-path &optional offset limit format)
   "Return a numbered page of text from FILE-PATH.
 OFFSET is the starting line number (1-indexed, default 1).
 LIMIT is the max lines to read (default `ogent-tools-max-file-lines').
-Name the next offset when more lines remain; mark truncated long lines."
+Name the next offset when more lines remain; mark truncated long lines.
+When FORMAT is `plist' or `json', return structured lines and continuations."
+  (if format
+      (progn
+        (ogent-tool-results-format nil format)
+        (ogent-tool-results-format (ogent-tool-results-read file-path offset limit) format))
   (unless (and (stringp file-path) (not (string-empty-p file-path)))
     (user-error "Invalid read_file file_path; use a non-empty string or glob to find a file"))
   (let* ((path (ogent-tools--resolve-path file-path))
```


## R015 — Complete discovery through structured file pagination

Primary commit: `a1793a894d9a7dbf57b189d027822c208c38a3a5`. Parent: `0829b080a5e90402a2a2234667818e741222db69`.

The text glob surface capped displayed matches, so an agent could not safely enumerate an arbitrarily longer result set from the returned text.

Separate complete candidate enumeration from legacy rendering; expose sorted absolute path records, zero-based offset, total_files, metadata snapshot and next_offset.

Regression: `audit/regression_tests/R015__complete_glob_pages.test.sh` — Enumerate more than the legacy cap over several pages, empty/weird paths and component-safe wildcard behavior.

### lisp/ogent-tool-results.el

Before: `0829b080a5e90402a2a2234667818e741222db69:lisp/ogent-tool-results.el:75`; after: `a1793a894d9a7dbf57b189d027822c208c38a3a5:lisp/ogent-tool-results.el:75`.

```diff
@@ -75,5 +75,32 @@ budget.  Snapshot the decoded content so callers can detect changed pages."
                 :next_offset (if more line-number :json-null)
                 :next_column (if more next-column :json-null)))))))
 
+(defun ogent-tool-results-glob (pattern &optional path offset limit)
+  "Return a structured page of files matching PATTERN under PATH.
+Sort by absolute path.  OFFSET starts at zero; LIMIT defaults to 100 and
+must not exceed 200.  Report the total count and a snapshot of file metadata."
+  (let ((offset (or offset 0)) (limit (or limit 100)))
+    (unless (and (integerp offset) (>= offset 0))
+      (user-error "Use a non-negative integer offset, starting at 0"))
+    (unless (and (integerp limit) (> limit 0) (<= limit 200))
+      (user-error "Use an integer limit between 1 and 200"))
+    (let* ((root (ogent-tools--resolve-path (or path ".")))
+           (files (sort (ogent-tools--glob-files pattern root) #'string<))
+           (metadata (mapcar
+                      (lambda (file)
+                        (let ((attributes (file-attributes file)))
+                          (list :path file :size (file-attribute-size attributes)
+                                :modified (format "%S" (file-attribute-modification-time attributes)))))
+                      files))
+           (total (length files))
+           (end (min total (+ offset limit))))
+      (when (> offset total)
+        (user-error "Offset %d exceeds %d files; restart with offset=0" offset total))
+      (list :path root :pattern pattern :offset offset :limit limit
+            :files (vconcat (seq-subseq metadata offset end))
+            :total_files total :snapshot (secure-hash 'sha256 (prin1-to-string metadata))
+            :has_more (if (< end total) t :json-false)
+            :next_offset (if (< end total) end :json-null)))))
+
 (provide 'ogent-tool-results)
 ;;; ogent-tool-results.el ends here
```

### lisp/ogent-tools.el

Before: `0829b080a5e90402a2a2234667818e741222db69:lisp/ogent-tools.el:359`; after: `a1793a894d9a7dbf57b189d027822c208c38a3a5:lisp/ogent-tools.el:358`.

```diff
@@ -359,12 +358,24 @@ Returns files sorted by modification time (newest first)."
                     (if (time-equal-p a-time b-time)
                         (string< a b)
                       (time-less-p b-time a-time))))))
-    ;; Limit results
-    (when (> (length files) 100)
-      (setq files (seq-take files 100)))
-    (if files
-        (string-join files "\n")
-      "No files found matching pattern")))
+    files))
+
+(defun ogent-tool--glob (pattern &optional path format offset limit)
+  "Find files matching glob PATTERN under PATH, defaulting to project root.
+Return up to 100 paths, newest first, with an explicit truncation notice.
+When FORMAT is `plist' or `json', return a page sorted by path, starting at
+zero-based OFFSET and containing at most LIMIT files (default 100)."
+  (if format
+      (progn
+        (ogent-tool-results-format nil format)
+        (ogent-tool-results-format (ogent-tool-results-glob pattern path offset limit) format))
+    (let ((files (ogent-tools--glob-files pattern path)))
+      (if files
+          (concat (string-join (seq-take files 100) "\n")
+                  (when (> (length files) 100)
+                    (format "\n\n[Showing 100 of %d files. Use ogent-agent-call with offset=100 for more.]"
+                            (length files))))
+        "No files found matching pattern"))))
 
 ;;; Tool: Grep (Content Search)
```


## R016 — Follow guarded tool continuations in one call

Primary commit: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c`. Parent: `a1793a894d9a7dbf57b189d027822c208c38a3a5`.

Callers had to infer the correct next arguments and could accidentally combine pages from changed files or a different working directory.

Add explicit continuation descriptors and ogent-agent-next for native or JSON results; freeze absolute targets, preserve long-line columns, and reject changed snapshots.

Regression: `audit/regression_tests/R016__continuation_calls.test.sh` — Working-directory changes retain original targets; JSON/native continuations agree; changed snapshots refuse mixing; long-line characters remain exact.

### lisp/ogent-agent.el

Before: `a1793a894d9a7dbf57b189d027822c208c38a3a5:lisp/ogent-agent.el:29`; after: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-agent.el:29`.

```diff
@@ -29,6 +29,38 @@ permission.  For example:
   (ogent-agent--output nil format)
   (ogent-agent--output (ogent-tool-execution-call name args) format))
 
+(defun ogent-agent-next (result &optional format)
+  "Follow RESULT's first continuation and return the next page in FORMAT.
+Accept a native result plist or JSON string.  Refuse changed snapshots so
+pagination cannot silently combine different versions of file/search data.
+Return a terminal result with status done when no continuation remains."
+  (ogent-agent--output nil format)
+  (when (stringp result)
+    (setq result (json-parse-string result :object-type 'plist
+                                   :null-object :json-null :false-object :json-false)))
+  (unless (and (proper-list-p result) (equal (plist-get result :contract_version) "1")
+               (vectorp (plist-get result :next)))
+    (user-error "Provide a contract_version 1 result from ogent-agent-call"))
+  (let* ((next (and (> (length (plist-get result :next)) 0)
+                    (aref (plist-get result :next) 0)))
+         (name (plist-get result :tool))
+         (page
+          (if (null next)
+              (ogent-tool-execution-result name "done")
+            (let ((expected (plist-get next :snapshot)))
+              (unless (and (equal name (plist-get next :tool))
+                           (stringp expected)
+                           (equal expected (plist-get (plist-get result :data) :snapshot)))
+                (user-error "Invalid continuation; restart with ogent-agent-call"))
+              (let ((actual (ogent-tool-execution-call name (plist-get next :args))))
+                (if (and (equal (plist-get actual :status) "ok")
+                         (not (equal expected (plist-get (plist-get actual :data) :snapshot))))
+                    (ogent-tool-execution-result
+                     name "error" nil "snapshot_changed"
+                     "Files changed between pages; restart the original call rather than combining these results")
+                  actual))))))
+    (ogent-agent--output page format)))
+
 (defun ogent-agent--boolean (value)
   "Return a JSON-compatible boolean for VALUE."
   (if value t :json-false))
```

### lisp/ogent-tool-execution.el

Before: `a1793a894d9a7dbf57b189d027822c208c38a3a5:lisp/ogent-tool-execution.el:24`; after: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-tool-execution.el:25`.

```diff
@@ -24,6 +25,39 @@ Include a typed error with CODE and MESSAGE when supplied."
                  :json-null)
         :next []))
 
+(defun ogent-tool-execution--success (spec args data)
+  "Return a structured terminal result for SPEC, ARGS and DATA."
+  (let* ((name (plist-get spec :name))
+         (structured (plist-get spec :result-function))
+         (code (and structured
+                    (cond ((eq (plist-get data :timed_out) t) "timeout")
+                          ((eq (plist-get data :cancelled) t) "cancelled")
+                          ((and (integerp (plist-get data :exit_code))
+                                (/= (plist-get data :exit_code) 0)) "command_failed"))))
+         (result (ogent-tool-execution-result
+                  name (if code "error" "ok")
+                  (if structured data (list :value data)) code
+                  (when code "Inspect stdout, stderr and exit_code; correct the command or increase its timeout before retrying"))))
+    (when (and structured (eq (plist-get data :has_more) t))
+      (let ((next-args (copy-sequence args)))
+        (setq next-args (plist-put next-args :offset (plist-get data :next_offset)))
+        (when (memq name '(read-file glob grep))
+          (setq next-args
+                (plist-put next-args (if (eq name 'read-file) :file_path :path)
+                           (or (plist-get data :path)
+                               (ogent-tools--resolve-path (or (plist-get args :path) "."))))))
+        (when (eq name 'read-file)
+          (setq next-args (plist-put next-args :column (plist-get data :next_column))))
+        (let ((print-length nil) (print-level nil))
+          (setq result
+                (plist-put result :next
+                           (vector (list :tool (symbol-name name) :args next-args
+                                         :snapshot (plist-get data :snapshot)
+                                         :call (prin1-to-string
+                                                (list 'ogent-agent-call (symbol-name name)
+                                                      (list 'quote next-args))))))))))
+    result))
+
 (defun ogent-tool-execution-call (name args)
   "Execute registered NAME with named ARGS and return a typed result.
 Validate before approval.  Never prompt for approval: return approval_required
```


## R017 — Familiar exact verbs with collision-safe policy resolution

Primary commit: `a2b3922f661514cd8ee6102d2db93d421eac7c92`. Parent: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c`.

An agent reasonably trying read, search, shell, write, edit or list-files could fail name lookup despite an available equivalent built-in tool.

Declare exact aliases in live specs; give exact registered names precedence, resolve only unambiguous declared aliases, and canonicalize approval keys.

Regression: `audit/regression_tests/R017__common_verbs.test.sh` — Exact names beat aliases, ambiguous aliases fail with a hint, and aliases inherit canonical approval denial rather than bypassing policy.

### lisp/ogent-agent.el

Before: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-agent.el:73`; after: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-agent.el:73`.

```diff
@@ -73,12 +73,13 @@ Return a terminal result with status done when no continuation remains."
                            (memq name (mapcar #'ogent-tool--name-symbol
                                               ogent-tools-enabled))))))
     (list :name (symbol-name name)
-          :aliases (let ((alias (replace-regexp-in-string
-                                 "-" "_" (symbol-name name))))
-                     (if (and (not (equal alias (symbol-name name)))
-                              (eq name (ogent-tool--name-symbol alias)))
-                         (vector alias)
-                       []))
+          :aliases (vconcat
+                    (delete-dups
+                     (seq-filter
+                      (lambda (alias) (and (not (equal alias (symbol-name name)))
+                                           (eq name (ogent-tool--name-symbol alias))))
+                      (cons (replace-regexp-in-string "-" "_" (symbol-name name))
+                            (append (plist-get spec :aliases) nil)))))
           :description (or (plist-get spec :description) "")
           :category (or (plist-get spec :category) "")
           :enabled (ogent-agent--boolean enabled)
```

### lisp/ogent-tool-approval.el

Before: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-tool-approval.el:56`; after: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tool-approval.el:56`.

```diff
@@ -56,9 +56,14 @@ Never resolve a typo to a different tool automatically."
            (alias (intern (replace-regexp-in-string "_" "-" text)))
            (names (when (boundp 'ogent-tool-registry)
                     (mapcar (lambda (spec) (plist-get spec :name))
-                            ogent-tool-registry))))
+                            ogent-tool-registry)))
+           (declared (when (boundp 'ogent-tool-registry)
+                       (cl-remove-if-not
+                        (lambda (spec) (member text (append (plist-get spec :aliases) nil)))
+                        ogent-tool-registry))))
       (cond ((memq exact names) exact)
             ((memq alias names) alias)
+            ((= (length declared) 1) (plist-get (car declared) :name))
             (t exact)))))
 
 (defun ogent-tool--pattern-match-p (pattern tool-name args)
```

### lisp/ogent-tool-contract.el

Before: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-tool-contract.el:18`; after: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tool-contract.el:18`.

```diff
@@ -18,7 +18,13 @@
   "Return a corrective lookup hint for unknown NAME among NAMES."
   (let* ((input (format "%s" name))
          (choices (sort (mapcar (lambda (item) (format "%s" item)) names) #'string<))
-         (closest (car (sort (copy-sequence choices)
+         (aliases (when (boundp 'ogent-tool-registry)
+                    (cl-mapcan (lambda (spec)
+                                 (when (member (format "%s" (plist-get spec :name)) choices)
+                                   (seq-filter (lambda (alias) (stringp alias))
+                                               (append (plist-get spec :aliases) nil))))
+                               ogent-tool-registry)))
+         (closest (car (sort (sort (append aliases (copy-sequence choices)) #'string<)
                              (lambda (a b)
                                (< (string-distance input a)
                                   (string-distance input b)))))))
```

### lisp/ogent-tools.el

Before: `e9c9af499d4d2bd99bc3c2cdfaa99c327a3d7a0c:lisp/ogent-tools.el:982`; after: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tools.el:982`.

```diff
@@ -982,6 +982,7 @@ If REPLACE-ALL is non-nil, replace all occurrences."
 
 (defvar ogent-tools-default-registry
   '((:name read-file
+           :aliases ["read" "cat"]
            :function ogent-tool--read-file
            :result-function ogent-tool-results-read
            :result-args ((:name "column" :type "integer" :optional t
```


## R018 — Structured search and bounded real process outcomes

Primary commit: `1cde7abb5d36ad9f84605a8e21db6f455268836a`. Parent: `a2b3922f661514cd8ee6102d2db93d421eac7c92`.

Search and shell returned presentation text, making exact filenames, stdout/stderr, process exits, timeouts and retained partial output difficult to compose reliably.

Add real process-backed search and shell result functions. Search emits path/line/text records and bounded pages through ripgrep JSON or GNU NUL fallback; shell separates channels, typed exit/signal/timeout/cancel state and bounded retained output.

Regression: `audit/regression_tests/R018__structured_processes.test.sh` — Real shell exit/channel/budget/timeout/cancellation/descendant cases; real grep regex, empty results, unusual filenames, pages, filters, snapshots, GNU and ripgrep protocols; SDK integration preserves process data on errors.

### lisp/ogent-tool-execution.el

Before: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tool-execution.el:102`; after: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tool-execution.el:109`.

```diff
@@ -102,7 +109,15 @@ owners.  Prefer registered structured result functions when available."
                    (ogent-tool-execution-result name "proposed" (list :review_required t)))
                (let ((data (ogent-ui--execute-tool name canonical t)))
                  (ogent-tool-execution--success spec canonical data))))))
-      (error (ogent-tool-execution-result name "error" nil phase
+      (error (ogent-tool-execution-result name "error" nil
+                                          (pcase (car err)
+                                            ('ogent-tool-process-search-timeout "timeout")
+                                            ('ogent-tool-process-search-cancelled "cancelled")
+                                            ('ogent-tool-process-start-failed "process_start_failed")
+                                            ('ogent-tool-process-unavailable "dependency_missing")
+                                            ('ogent-tool-process-output-error "unsupported_output")
+                                            ('ogent-tool-process-search-failed "search_failed")
+                                            (_ phase))
                                           (error-message-string err))))))
 
 (defun ogent-tool-execution-wrapper (spec)
```

### lisp/ogent-tool-process.el

Before: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tool-process.el:0`; after: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tool-process.el:1`.

```diff
@@ -0,0 +1,493 @@
+;;; ogent-tool-process.el --- Structured local process tools -*- lexical-binding: t; -*-
+
+;;; Commentary:
+;; Return process results as data without decoding human-facing tool footers.
+;; These low-level helpers trust their caller; the agent dispatcher owns policy.
+;; Search uses ripgrep JSON or GNU grep's NUL-delimited filename protocol.
+
+;;; Code:
+
+(require 'cl-lib)
+(require 'json)
+(require 'seq)
+(require 'subr-x)
+(require 'ogent-tools)
+
+(define-error 'ogent-tool-process-start-failed "Local process could not start" 'user-error)
+(define-error 'ogent-tool-process-search-failed "Local search failed" 'user-error)
+(define-error 'ogent-tool-process-search-timeout "Local search timed out" 'user-error)
+(define-error 'ogent-tool-process-search-cancelled "Local search was cancelled" 'user-error)
+(define-error 'ogent-tool-process-output-error "Local process output is unsupported" 'user-error)
+(define-error 'ogent-tool-process-unavailable "Local search dependency is unavailable" 'user-error)
+
+(defconst ogent-tool-process--max-context 20
+  "Maximum context lines on each side of a structured search match.")
+
+(defconst ogent-tool-process--max-limit 200
+  "Maximum matches in a structured search page.")
+
+(defun ogent-tool-process--safe-text (text)
+  "Return TEXT with undecodable raw bytes replaced by Unicode replacement chars."
+  (replace-regexp-in-string "[\x3fff80-\x3fffff]" "\uFFFD" text t t))
+
+(defun ogent-tool-process--callback (callback data error-data &optional process)
+  "Invoke CALLBACK with DATA and ERROR-DATA, recording errors on PROCESS."
+  (when callback
+    (condition-case err
+        (funcall callback data error-data)
+      (error
+       (when process (process-put process 'ogent-callback-error err))
+       (message "ogent: process callback failed: %s" (error-message-string err))))))
+
+(defun ogent-tool-process--stop (process)
+  "Terminate PROCESS and its local process group when possible."
+  (when (processp process)
+    ;; Pipe children have a separate process group on POSIX Emacs.  Killing
+    ;; that group also closes inherited output pipes in shell grandchildren.
+    (condition-case nil
+        (when-let ((pid (process-id process)))
+          (signal-process (- pid) 9))
+      (error nil))
+    (when (process-live-p process) (delete-process process))))
+
+(defun ogent-tool-process-cancel (process)
+  "Cancel structured PROCESS and deliver its partial terminal result.
+Return non-nil when PROCESS had an active cancellation handler."
+  (when-let ((cancel (and (processp process)
+                          (process-get process 'ogent-cancel))))
+    (funcall cancel)
+    t))
+
+(defun ogent-tool-process--run (command directory timeout callback
+					&optional stdout-handler input cleanup)
+  "Run COMMAND in DIRECTORY with TIMEOUT and terminal CALLBACK.
+Call CALLBACK once with a process-data plist and an error condition or nil.
+STDOUT-HANDLER, when present, consumes stdout instead of retaining it.
+Feed INPUT to stdin when non-nil.  Invoke CLEANUP on every terminal path."
+  (let ((default-directory directory)
+        (budget (max 0 ogent-tools-max-output-chars))
+        (retained 0)
+        (stdout "") (stderr "")
+        process stderr-process timer completed finishing timed-out cancelled failure
+        encoding-loss)
+    (cl-labels
+        ((emit (channel chunk)
+           (unless completed
+             (if (and (eq channel 'stdout) stdout-handler)
+                 (condition-case err
+                     (funcall stdout-handler chunk)
+                   (error
+                    (setq failure err)
+                    (ogent-tool-process--stop process)))
+               (let* ((safe (ogent-tool-process--safe-text chunk))
+                      (remaining (max 0 (- budget retained)))
+                      (kept (substring safe 0 (min remaining (length safe)))))
+                 (unless (equal safe chunk) (setq encoding-loss t))
+                 (cl-incf retained (length kept))
+                 (when (> (length chunk) remaining)
+                   (when process (process-put process 'ogent-truncated t)))
+                 (if (eq channel 'stdout)
+                     (setq stdout (concat stdout kept))
+                   (setq stderr (concat stderr kept)))))))
+         (finish ()
+           (unless (or completed finishing)
+             (setq finishing t)
+             (when timer (cancel-timer timer))
+             (when (and process (eq (process-status process) 'signal))
+               (ogent-tool-process--stop process))
+             (when process
+               (while (accept-process-output process 0.01)))
+             ;; Drain the separate stderr pipe before marking the result final.
+             (while (and stderr-process
+                         (accept-process-output stderr-process 0.01)))
+             (setq completed t)
+             (when process
+               (process-put process 'ogent-cancel nil)
+               (ogent-tools--drop-active-process process))
+             (when stderr-process
+               (set-process-filter stderr-process #'ignore)
+               (set-process-sentinel stderr-process #'ignore)
+               (when (process-live-p stderr-process)
+                 (delete-process stderr-process)))
+             (when cleanup
+               (condition-case err
+                   (funcall cleanup)
+                 (error
+                  (when process (process-put process 'ogent-cleanup-error err))
+                  (message "ogent: process cleanup failed: %s"
+                           (error-message-string err)))))
+             (ogent-tool-process--callback
+              callback
+              (and process
+                   (list :stdout stdout :stderr stderr
+                         :exit_code (process-exit-status process)
+                         :signal (if (eq (process-status process) 'signal)
+                                     (process-exit-status process) :json-null)
+                         :timed_out (if timed-out t :json-false)
+                         :cancelled (if cancelled t :json-false)
+                         :encoding_loss (if encoding-loss t :json-false)
+                         :truncated (if (process-get process 'ogent-truncated)
+                                        t :json-false)))
+              failure process))))
+      (condition-case err
+          (progn
+            (setq stderr-process
+                  (make-pipe-process
+                   :name "ogent-structured-stderr" :noquery t
+                   :coding 'utf-8-unix :buffer nil
+                   :filter (lambda (_process chunk) (emit 'stderr chunk))
+                   :sentinel #'ignore))
+            (setq process
+                  (make-process
+                   :name "ogent-structured-process" :command command
+                   :connection-type 'pipe :coding 'utf-8-unix
+                   :noquery t :buffer nil :stderr stderr-process
+                   :filter (lambda (_process chunk) (emit 'stdout chunk))
+                   :sentinel (lambda (proc _event)
+                               (when (memq (process-status proc) '(exit signal failed))
+                                 (finish)))))
+            (process-put process 'ogent-cancel
+                         (lambda ()
+                           (unless completed
+                             (setq cancelled t)
+                             (ogent-tool-process--stop process)
+                             (finish))))
+            (push (cons process (list :callback callback))
+                  ogent-tools--active-processes)
+            (setq timer
+                  (run-at-time timeout nil
+                               (lambda ()
+                                 (unless completed
+                                   (setq timed-out t)
+                                   (ogent-tool-process--stop process)
+                                   (finish)))))
+            (when input (process-send-string process input))
+            (when (process-live-p process) (process-send-eof process))
+            process)
+        (error
+         (setq failure
+               (list 'ogent-tool-process-start-failed
+                     (format "Unable to start local process: %s; verify the configured shell and search executables"
+                             (error-message-string err))))
+         (when process
+           (set-process-sentinel process #'ignore)
+           (ogent-tool-process--stop process))
+         (finish)
+         nil)))))
+
+(defun ogent-tool-process--wait (starter)
+  "Run asynchronous STARTER and return its terminal data or signal its error."
+  (let (done data failure process)
+    (unwind-protect
+        (progn
+          (setq process
+                (funcall starter
+                         (lambda (result error-data)
+                           (setq done t data result failure error-data))))
+          (while (not done)
+            (accept-process-output nil 0.05))
+          (if failure (signal (car failure) (cdr failure)) data))
+      (when (and process (process-live-p process))
+        (ogent-tool-process-cancel process)))))
+
+(defun ogent-tool-process-bash-async (command &optional working-directory timeout callback)
+  "Execute shell COMMAND and return its asynchronous process.
+WORKING-DIRECTORY and TIMEOUT have the legacy shell defaults.
+Call CALLBACK once with (DATA ERROR), where ERROR is a condition or nil.
+DATA separates stdout, stderr, exit_code, timed_out, cancelled and truncated.
+Timeout and cancellation preserve partial output as terminal data."
+  (condition-case err
+      (let ((seconds (or timeout ogent-tools-shell-timeout)))
+        (ogent-tools--bash-validate command working-directory seconds)
+        (ogent-tool-process--run
+         (list shell-file-name shell-command-switch command)
+         (file-name-as-directory
+          (if working-directory (ogent-tools--resolve-path working-directory)
+            (ogent-tools--project-root)))
+         seconds callback))
+    (error (ogent-tool-process--callback callback nil err) nil)))
+
+(defun ogent-tool-process-bash (command &optional working-directory timeout)
+  "Execute shell COMMAND and return its structured process data.
+Use WORKING-DIRECTORY and TIMEOUT as in `ogent-tool-process-bash-async'.
+Retain partial output on a nonzero exit, timeout or cancellation."
+  (ogent-tool-process--wait
+   (lambda (callback)
+     (ogent-tool-process-bash-async command working-directory timeout callback))))
+
+(defun ogent-tool-process--search-options (pattern path glob-filter context offset limit)
+  "Validate search PATTERN, PATH, GLOB-FILTER, CONTEXT, OFFSET and LIMIT."
+  (ogent-tools--grep-pattern pattern)
+  (unless (or (null path) (and (stringp path) (not (string-empty-p path))))
+    (user-error "Invalid grep path; use an existing file or directory path"))
+  (unless (or (null glob-filter) (stringp glob-filter))
+    (user-error "Invalid grep glob_filter; use a string, such as *.el"))
+  (unless (and (integerp context) (<= 0 context ogent-tool-process--max-context))
+    (user-error "Invalid grep context_lines; use an integer from 0 to %d"
+                ogent-tool-process--max-context))
+  (unless (and (integerp offset) (>= offset 0))
+    (user-error "Invalid grep offset; use a non-negative integer, starting at 0"))
+  (unless (and (integerp limit) (<= 1 limit ogent-tool-process--max-limit))
+    (user-error "Invalid grep limit; use an integer from 1 to %d"
+                ogent-tool-process--max-limit))
+  (unless (and (numberp ogent-tools-grep-timeout) (> ogent-tools-grep-timeout 0))
+    (user-error "Invalid grep timeout; set ogent-tools-grep-timeout to positive seconds"))
+  (condition-case err
+      (ogent-tools--grep-target path)
+    (error (user-error "%s; use glob to find an existing search path"
+                       (error-message-string err)))))
+
+(defun ogent-tool-process--json-text (value)
+  "Decode ripgrep text or base64 bytes from VALUE without human text parsing."
+  (or (plist-get value :text)
+      (when-let ((bytes (plist-get value :bytes)))
+        (decode-coding-string (base64-decode-string bytes) 'utf-8-unix))
+      ""))
+
+(defun ogent-tool-process--grep-files (target glob-filter)
+  "Return sorted regular files in TARGET matching GLOB-FILTER."
+  (let ((case-fold-search nil)
+        (regexp (and glob-filter (wildcard-to-regexp glob-filter))))
+    (sort
+     (cl-remove-if-not
+      (lambda (file)
+        (and (file-regular-p file)
+             (not (string-match-p "/\\.git/" file))
+             (or (null regexp)
+                 (string-match-p regexp (file-name-nondirectory file))
+                 (string-match-p regexp (file-relative-name file target)))))
+      (if (file-directory-p target)
+          (directory-files-recursively target "." nil nil)
+        (list target)))
+     #'string<)))
+
+(defun ogent-tool-process-grep-async (pattern &optional path glob-filter context-lines
+                                              offset limit callback)
+  "Search PATTERN and return its asynchronous local process.
+Search PATH with optional GLOB-FILTER and CONTEXT-LINES (0 through 20).
+OFFSET is zero-based; LIMIT defaults to 200 and must be 1 through 200.
+Call CALLBACK once with (DATA ERROR), where ERROR is a condition or nil.
+DATA contains match objects, pagination, a snapshot hash and truncation flags.
+Count all matching lines, retaining only the requested page and bounded text."
+  (condition-case err
+      (let* ((context (or context-lines 0))
+             (start (or offset 0))
+             (page-size (or limit ogent-tool-process--max-limit))
+             (target-info (ogent-tool-process--search-options
+                           pattern path glob-filter context start page-size))
+             (directory (plist-get target-info :directory))
+             (target (plist-get target-info :target))
+             (rg (executable-find "rg"))
+             (grep (and (not rg) (executable-find "grep")))
+             (xargs (and grep (executable-find "xargs")))
+             (engine (if rg "ripgrep-json" "gnu-grep-null"))
+             (budget (max 0 ogent-tools-max-output-chars))
+             (wire-limit (max 1048576 (* 8 budget)))
+             (count 0) (retained 0) (pending "")
+             (hash (secure-hash 'sha256 (prin1-to-string
+                                         (list target pattern glob-filter context))))
+             matches before active current-path truncated oversized encoding-loss
+             input command temporary-file)
+        (unless (or rg (and grep xargs))
+          (signal 'ogent-tool-process-unavailable
+                  '("Structured grep needs ripgrep or GNU grep with xargs; install ripgrep and retry")))
+        (cl-labels
+            ((bounded (text)
+               (let* ((safe (ogent-tool-process--safe-text text))
+                      (remaining (max 0 (- budget retained)))
+                      (kept (substring safe 0 (min (length safe) remaining))))
+                 (unless (equal safe text) (setq encoding-loss t))
+                 (cl-incf retained (length kept))
+                 (when (> (length text) remaining) (setq truncated t))
+                 kept))
+             (line (file number text matched)
+               (unless (equal file (ogent-tool-process--safe-text file))
+                 (signal 'ogent-tool-process-output-error
+                         '("Search filename contains non-UTF-8 bytes; search a directory with UTF-8 filenames or rename the file before retrying")))
+               (unless (equal file current-path)
+                 (setq current-path file before nil active nil))
+               (setq hash (secure-hash 'sha256
+                                       (concat hash (prin1-to-string
+                                                     (list file number text matched)))))
+               (dolist (record active)
+                 (when (<= (- number (plist-get record :line)) context)
+                   (let* ((kept (bounded text))
+                          (entry (list :line number :text kept)))
+                     (unless (equal kept text)
+                       (setq entry (plist-put entry :truncated t))
+                       (plist-put record :truncated t))
+                     (plist-put record :context_after
+                                (vconcat (plist-get record :context_after)
+                                         (vector entry))))))
+               (setq active (cl-remove-if
+                             (lambda (record)
+                               (>= (- number (plist-get record :line)) context))
+                             active))
+               (when matched
+                 (when (and (>= count start) (< count (+ start page-size)))
+                   (let* ((kept (bounded text))
+                          (record (list :path (expand-file-name file directory)
+					:line number :text kept
+					:truncated (if (equal kept text) :json-false t)
+					:context_before
+					(vconcat
+                                         (mapcar
+                                          (lambda (entry)
+                                            (let* ((original (nth 1 entry))
+                                                   (kept-context (bounded original))
+                                                   (result (list :line (car entry)
+                                                                 :text kept-context)))
+                                              (when (or (nth 2 entry)
+							(not (equal kept-context original)))
+						(setq truncated t)
+						(setq result (plist-put result :truncated t)))
+                                              result))
+                                          (reverse before)))
+					:context_after [])))
+                     (when (seq-some (lambda (entry) (eq (plist-get entry :truncated) t))
+                                     (plist-get record :context_before))
+                       (plist-put record :truncated t))
+                     (push record matches)
+                     (when (> context 0) (push record active))))
+                 (cl-incf count))
+               (when (> context 0)
+                 ;; A bounded ring of source context, independent of page text.
+                 (push (list number (substring text 0 (min budget (length text)))
+                             (> (length text) budget)) before)
+                 (when (> (length before) context)
+                   (setcdr (nthcdr (1- context) before) nil))))
+             (rg-line (text)
+               (when (> (length text) wire-limit)
+                 (signal 'ogent-tool-process-output-error
+                         '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly")))
+               (let* ((event (json-parse-string text :object-type 'plist
+                                                :array-type 'array
+                                                :null-object :json-null
+                                                :false-object :json-false))
+                      (type (plist-get event :type))
+                      (data (plist-get event :data)))
+                 (when (member type '("match" "context"))
+                   (line (ogent-tool-process--json-text (plist-get data :path))
+                         (plist-get data :line_number)
+                         (string-remove-suffix
+                          "\n" (ogent-tool-process--json-text (plist-get data :lines)))
+                         (equal type "match")))))
+             (consume (chunk)
+               (setq pending (concat pending chunk))
+               (if rg
+                   (let (end)
+                     (while (setq end (string-match "\n" pending))
+                       (rg-line (substring pending 0 end))
+                       (setq pending (substring pending (1+ end)))))
+                 (let (nul end)
+                   (while (and (setq nul (string-match "\0" pending))
+                               (setq end (string-match "\n" pending (1+ nul))))
+                     (when (> end wire-limit)
+                       (signal 'ogent-tool-process-output-error
+                               '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly")))
+                     (let ((file (substring pending 0 nul))
+                           (entry (substring pending (1+ nul) end)))
+                       (unless (string-match "\\`\\([0-9]+\\)\\([:-]\\)" entry)
+                         (signal 'ogent-tool-process-output-error
+                                 '("GNU grep returned an unsupported record; install ripgrep and retry")))
+                       (let ((number (string-to-number (match-string 1 entry)))
+                             (matched (equal (match-string 2 entry) ":"))
+                             (text (substring entry (match-end 0))))
+                         (line file number text matched)))
+                     (setq pending (substring pending (1+ end))))))
+               ;; A pathological source line must not grow the retained wire
+               ;; buffer without bound.  Fail explicitly instead of inventing
+               ;; a complete count or dropping an unreported matching line.
+               (when (> (length pending) wire-limit)
+                 (setq oversized t)
+                 (signal 'ogent-tool-process-output-error
+                         '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly"))))
+             (finish (process-data error-data)
+               (cond
+                (error-data (ogent-tool-process--callback callback nil error-data))
+                ((or (eq (plist-get process-data :timed_out) t)
+                     (eq (plist-get process-data :cancelled) t))
+                 (ogent-tool-process--callback
+                  callback nil
+                  (list (if (eq (plist-get process-data :timed_out) t)
+                            'ogent-tool-process-search-timeout
+                          'ogent-tool-process-search-cancelled)
+                        (if (eq (plist-get process-data :timed_out) t)
+                            "Search timed out; narrow path or glob_filter and retry"
+                          "Search cancelled; retry the same search when ready"))))
+                ((not (memq (plist-get process-data :exit_code) '(0 1)))
+                 (ogent-tool-process--callback
+                  callback nil
+                  (list 'ogent-tool-process-search-failed
+                        (ogent-tools--grep-failure
+                         (plist-get process-data :exit_code)
+                         (plist-get process-data :stderr)))))
+                (t
+                 (ogent-tool-process--callback
+                  callback
+                  (list :path target :matches (vconcat (nreverse matches))
+                        :offset start :limit page-size :total_matches count
+                        :has_more (if (> count (+ start page-size)) t :json-false)
+                        :next_offset (if (> count (+ start page-size))
+                                         (+ start page-size) :json-null)
+                        :truncated (if (or truncated oversized) t :json-false)
+                        :encoding_loss (if encoding-loss t :json-false)
+                        :snapshot hash :engine engine)
+                  nil)))))
+          (if rg
+              (setq command
+                    (append (list rg "--json" "--sort" "path" "--color=never"
+                                  "--hidden" "--no-ignore" "-g" "!**/.git/**"
+                                  "-C" (number-to-string context))
+                            (when glob-filter (list "-g" glob-filter))
+                            (list "--" pattern target)))
+            ;; xargs preserves ordered filename input and invokes grep in
+            ;; argument-size-safe batches.  Normalize grep's no-match exit 1.
+            (setq input (mapconcat #'identity
+                                   (ogent-tool-process--grep-files target glob-filter)
+                                   "\0"))
+            (unless (string-empty-p input) (setq input (concat input "\0")))
+            (setq temporary-file (make-temp-file "ogent-grep-files-"))
+            (condition-case write-error
+                (let ((coding-system-for-write 'utf-8-unix))
+                  (with-temp-file temporary-file (insert input)))
+              (error
+               (when (file-exists-p temporary-file) (delete-file temporary-file))
+               (signal (car write-error) (cdr write-error))))
+            (setq command
+                  (list shell-file-name shell-command-switch
+                        (concat
+                         (mapconcat
+                          #'shell-quote-argument
+                          (list xargs "-0" "-r" "-n" "128"
+                                shell-file-name shell-command-switch
+                                (concat
+                                 (mapconcat
+                                  #'shell-quote-argument
+                                  (list grep "-HnZE" "--color=never"
+                                        "--binary-files=without-match"
+                                        "--no-group-separator" "-C"
+                                        (number-to-string context) "--" pattern)
+                                  " ")
+                                 " \"$@\"; code=$?; test \"$code\" -le 1")
+                                "ogent-grep")
+                          " ")
+                         " < " (shell-quote-argument temporary-file)))))
+          (ogent-tool-process--run
+           command directory ogent-tools-grep-timeout #'finish #'consume nil
+           (lambda ()
+             (when (and temporary-file (file-exists-p temporary-file))
+               (delete-file temporary-file))))))
+    (error (ogent-tool-process--callback callback nil err) nil)))
+
+(defun ogent-tool-process-grep (pattern &optional path glob-filter context-lines offset limit)
+  "Search PATTERN and return a structured match page.
+Use PATH, GLOB-FILTER, CONTEXT-LINES, OFFSET and LIMIT as in
+`ogent-tool-process-grep-async'.  Signal actionable errors on search failure."
+  (ogent-tool-process--wait
+   (lambda (callback)
+     (ogent-tool-process-grep-async
+      pattern path glob-filter context-lines offset limit callback))))
+
+(provide 'ogent-tool-process)
+;;; ogent-tool-process.el ends here
```

### lisp/ogent-tools.el

Before: `a2b3922f661514cd8ee6102d2db93d421eac7c92:lisp/ogent-tools.el:434`; after: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tools.el:439`.

```diff
@@ -434,12 +439,19 @@ Use GLOB-FILTER and CONTEXT to shape the command."
   (format "grep failed (exit %s): %s. Check pattern syntax and path; retry grep with a valid pattern, such as needle"
           status (string-trim diagnostic)))
 
-(defun ogent-tool--grep (pattern &optional path glob-filter context-lines)
+(defun ogent-tool--grep (pattern &optional path glob-filter context-lines format offset limit)
   "Search for PATTERN in files with streaming progress.
 PATH is file or directory to search (default project root).
 GLOB-FILTER limits to matching files (e.g., \"*.el\").
 CONTEXT-LINES shows N lines before/after matches.
-Output is streamed incrementally via `ogent-tools-stream-callback'."
+Output is streamed incrementally via `ogent-tools-stream-callback'.
+When FORMAT is `plist' or `json', return match objects with zero-based OFFSET
+and page LIMIT, including exact paths, positions, context and counts."
+  (if format
+      (progn
+        (ogent-tool-results-format nil format)
+        (ogent-tool-results-format
+         (ogent-tool-process-grep pattern path glob-filter context-lines offset limit) format))
   (let* ((pattern (ogent-tools--grep-pattern pattern))
          (target-info (ogent-tools--grep-target path))
          (dir (plist-get target-info :directory))
```


## R019 — Async agent calls with one precise terminal callback and ledger

Primary commit: `3ced858f197edfb31e5943ebd9787fa1244e3867`. Parent: `1cde7abb5d36ad9f84605a8e21db6f455268836a`.

The named SDK lacked a callback API; blindly invoking an async spec synchronously could fail its calling convention or record process failure as ledger success.

Add ogent-agent-call-async, callback-once guards, returned process cancellation handles, and one terminal error classification shared with ledger recording. Reject unsupported synchronous async calls with actionable guidance.

Regression: `audit/regression_tests/R019__async_sdk.test.sh` — Real async process completion and ledger, duplicate extension completions, synchronous rejection, denial, cancellation and failed sync/async ledger terminals.

### lisp/ogent-agent.el

Before: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-agent.el:61`; after: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-agent.el:61`.

```diff
@@ -61,6 +61,18 @@ Return a terminal result with status done when no continuation remains."
                   actual))))))
     (ogent-agent--output page format)))
 
+(defun ogent-agent-call-async (name args callback &optional format)
+  "Execute NAME with named ARGS and send its terminal result to CALLBACK.
+Serialize that result according to FORMAT.  Return a process for asynchronous
+tools; immediate results return nil.  CALLBACK accepts one result and runs
+exactly once, including validation, denial, timeout and cancellation failures.
+Cancel a returned process with `ogent-tool-process-cancel'."
+  (ogent-agent--output nil format)
+  (unless (functionp callback)
+    (user-error "Provide a callback function accepting one terminal result"))
+  (ogent-tool-execution-call
+   name args (lambda (result) (funcall callback (ogent-agent--output result format)))))
+
 (defun ogent-agent--boolean (value)
   "Return a JSON-compatible boolean for VALUE."
   (if value t :json-false))
```

### lisp/ogent-tool-execution.el

Before: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tool-execution.el:65`; after: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-tool-execution.el:68`.

```diff
@@ -65,13 +68,67 @@ Include a typed error with CODE and MESSAGE when supplied."
                                                       (list 'quote next-args))))))))))
     result))
 
-(defun ogent-tool-execution-call (name args)
+(defun ogent-tool-execution--schema (spec)
+  "Return SPEC's named structured argument schema."
+  (plist-put (copy-sequence spec) :args
+             (append (plist-get spec :args) (plist-get spec :result-args))))
+
+(defun ogent-tool-execution--failure (name code err)
+  "Return a typed failure for NAME from ERR, defaulting to CODE."
+  (ogent-tool-execution-result
+   name "error" nil
+   (pcase (car-safe err)
+     ('ogent-tool-process-search-timeout "timeout")
+     ('ogent-tool-process-search-cancelled "cancelled")
+     ('ogent-tool-process-start-failed "process_start_failed")
+     ('ogent-tool-process-unavailable "dependency_missing")
+     ('ogent-tool-process-output-error "unsupported_output")
+     ('ogent-tool-process-search-failed "search_failed")
+     (_ code))
+   (if (consp err) (error-message-string err) (format "%s" err))))
+
+(defun ogent-tool-execution--start (spec args values callback)
+  "Start asynchronous SPEC with ARGS, VALUES and terminal CALLBACK.
+Record exactly one ledger terminal even if the tool completes twice or fails
+after completion.  Adapt native callback-last tools to the result contract."
+  (let* ((name (plist-get spec :name))
+         (call (list :name (symbol-name name) :args args))
+         (effects (plist-get spec :effects))
+         (function (or (plist-get spec :result-async-function) (plist-get spec :function)))
+         (started (float-time)) finished
+         (complete (lambda (data &optional failure)
+                     (unless finished
+                       (setq finished t)
+                       (let ((result (if failure
+                                         (ogent-tool-execution--failure name "execution_failed" failure)
+                                       (ogent-tool-execution--success spec args data))))
+                         (ogent-ledger-record-tool-finish
+                          call data (unless (eq (plist-get result :error) :json-null)
+                                      (plist-get (plist-get result :error) :message))
+                          (- (float-time) started) effects)
+                         (funcall callback result))))))
+    (ogent-ledger-record-tool-start call effects)
+    (condition-case err
+        (apply function (append values (list complete)))
+      (error (funcall complete nil err) nil))))
+
+(defun ogent-tool-execution-call (name args &optional callback prompt)
   "Execute registered NAME with named ARGS and return a typed result.
 Validate before approval.  Never prompt for approval: return approval_required
 when policy needs a decision.  Preserve the existing edit review and ledger
-owners.  Prefer registered structured result functions when available."
-  (let ((phase "unknown_tool") spec canonical schema)
-    (condition-case err
+owners.  Prefer registered structured result functions when available.
+When CALLBACK is non-nil, call it once with the terminal result and return
+the process for asynchronous tools.  Other tools can complete immediately.
+PROMPT is reserved for the normal interactive gptel execution path."
+  (when (and callback (not (functionp callback)))
+    (user-error "Provide a function callback accepting one terminal result"))
+  (let ((phase "unknown_tool") spec canonical schema deferred delivered)
+    (cl-labels ((deliver (result)
+                  (unless delivered
+                    (setq delivered t)
+                    (funcall callback result))))
+      (let ((result
+             (condition-case err
         (progn
           (setq spec (ogent-tool-spec-get name))
           (unless spec
```

### lisp/ogent-tool-process.el

Before: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tool-process.el:103`; after: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-tool-process.el:103`.

```diff
@@ -103,6 +103,8 @@ Feed INPUT to stdin when non-nil.  Invoke CLEANUP on every terminal path."
              (setq completed t)
              (when process
                (process-put process 'ogent-cancel nil)
+               (set-process-filter process #'ignore)
+               (set-process-sentinel process #'ignore)
                (ogent-tools--drop-active-process process))
              (when stderr-process
                (set-process-filter stderr-process #'ignore)
```

### lisp/ogent-tool-results.el

Before: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ogent-tool-results.el:71`; after: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-tool-results.el:71`.

```diff
@@ -71,6 +71,7 @@ budget.  Snapshot the decoded content so callers can detect changed pages."
                 :offset offset :column column :limit limit
                 :lines (vconcat page)
                 :content (mapconcat (lambda (line) (plist-get line :text)) page "\n")
+                :ends_with_newline (if (string-suffix-p "\n" content) t :json-false)
                 :has_more (if more t :json-false)
                 :next_offset (if more line-number :json-null)
                 :next_column (if more next-column :json-null)))))))
```

### lisp/ui/ogent-ui-toolcalls.el

Before: `1cde7abb5d36ad9f84605a8e21db6f455268836a:lisp/ui/ogent-ui-toolcalls.el:267`; after: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ui/ogent-ui-toolcalls.el:268`.

```diff
@@ -267,8 +268,10 @@ the inspectable tool-call history that powers `ogent-debug-replay-tool'."
                              spec))
                    (arg-values (ogent-ui--extract-tool-args schema args))
                    (result (apply func arg-values))
-                   (duration (float-time (time-subtract (current-time) start))))
-              (ogent-ledger-record-tool-finish tool-call result nil duration effects)
+                   (duration (float-time (time-subtract (current-time) start)))
+                   (failure (and structured (plist-get spec :result-function)
+                                 (ogent-tool-execution-process-error result))))
+              (ogent-ledger-record-tool-finish tool-call result failure duration effects)
               (when (fboundp 'ogent-debug-log-tool-call)
                 (ogent-debug-log-tool-call history-call result duration))
               result)
```


## R020 — Preflighted batches of declared read-only calls

Primary commit: `974eb31e3052278a80039b0492c1a8dcc14c1fbe`. Parent: `3ced858f197edfb31e5943ebd9787fa1244e3867`.

A read investigation required separate SDK round trips even when all calls were independent; naive sequential batching could execute a safe prefix before discovering an unsafe write.

Add ogent-agent-batch for at most 20 declared read-only calls; validate all names/arguments/effects before any execution and expose result ordering, completion count, partial status and fail-fast behavior.

Regression: `audit/regression_tests/R020__read_only_batches.test.sh` — Compose glob/search/read, reject unsafe suffix before any read prefix executes, and either continue or stop after individual errors.

### lisp/ogent-agent.el

Before: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-agent.el:73`; after: `974eb31e3052278a80039b0492c1a8dcc14c1fbe:lisp/ogent-agent.el:74`.

```diff
@@ -73,6 +74,59 @@ Cancel a returned process with `ogent-tool-process-cancel'."
   (ogent-tool-execution-call
    name args (lambda (result) (funcall callback (ogent-agent--output result format)))))
 
+(defun ogent-agent-batch (calls &optional format fail-fast)
+  "Execute up to 20 explicitly read-only CALLS and return results in FORMAT.
+CALLS is a list or vector of plists containing :tool and :args.  Preflight the
+entire batch before running any call.  Reject writes, shell commands and tools
+without declared read effects.  Continue after errors unless FAIL-FAST is t.
+For example, batch a glob, search and file read in one local SDK round trip."
+  (ogent-agent--output nil format)
+  (let ((phase "invalid_arguments") prepared results stopped)
+    (ogent-agent--output
+     (condition-case err
+         (progn
+           (unless (and (or (proper-list-p calls) (vectorp calls))
+                        (<= (length calls) 20))
+             (user-error "Provide at most 20 calls as a list or vector"))
+           (unless (memq fail-fast '(nil t))
+             (user-error "Use nil or t for fail-fast"))
+           (dolist (call (append calls nil))
+             (unless (and (proper-list-p call) (= (length call) 4)
+                          (plist-member call :tool) (plist-member call :args)
+                          (cl-loop for key in call by #'cddr always (memq key '(:tool :args))))
+               (user-error "Each call needs only :tool and :args fields"))
+             (let ((spec (ogent-tool-spec-get (plist-get call :tool))))
+               (unless spec (user-error "%s" (ogent-tool-contract-name-hint
+                                              (plist-get call :tool)
+                                              (mapcar (lambda (item) (plist-get item :name)) ogent-tool-registry))))
+               (ogent-tool-contract-values (ogent-tool-execution--schema spec) (plist-get call :args))
+               (setq phase "unsafe_batch")
+               (let ((effects (ogent-tool-effects-normalize (plist-get spec :effects))))
+                 (unless (and effects (cl-every (lambda (effect) (eq (plist-get effect :kind) 'read)) effects))
+                   (user-error "Batch accepts only declared read-only tools; invoke %s individually through approval"
+                               (plist-get spec :name))))
+               (setq phase "invalid_arguments")
+               (push (cons spec call) prepared)))
+           (dolist (entry (nreverse prepared))
+             (unless stopped
+               (let* ((spec (car entry)) (call (cdr entry))
+                      (result (if (equal spec (ogent-tool-spec-get (plist-get spec :name)))
+                                  (ogent-tool-execution-call (plist-get call :tool) (plist-get call :args))
+                                (ogent-tool-execution-result
+                                 (plist-get spec :name) "error" nil "unavailable"
+                                 "Tool registry changed during batch; rediscover before retrying"))))
+                 (push result results)
+                 (when (and fail-fast (not (equal (plist-get result :status) "ok")))
+                   (setq stopped t)))))
+           (setq results (nreverse results))
+           (list :contract_version "1"
+                 :status (if (cl-every (lambda (result) (equal (plist-get result :status) "ok")) results)
+                             "ok" "partial")
+                 :results (vconcat results) :requested (length calls) :completed (length results)
+                 :stopped (if stopped t :json-false)))
+       (error (ogent-tool-execution--failure "batch" phase err)))
+     format)))
+
 (defun ogent-agent--boolean (value)
   "Return a JSON-compatible boolean for VALUE."
   (if value t :json-false))
```

### lisp/ogent-tool-process.el

Before: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-tool-process.el:448`; after: `974eb31e3052278a80039b0492c1a8dcc14c1fbe:lisp/ogent-tool-process.el:466`.

```diff
@@ -448,33 +466,38 @@ Count all matching lines, retaining only the requested page and bounded text."
             (setq input (mapconcat #'identity
                                    (ogent-tool-process--grep-files target glob-filter)
                                    "\0"))
-            (unless (string-empty-p input) (setq input (concat input "\0")))
-            (setq temporary-file (make-temp-file "ogent-grep-files-"))
-            (condition-case write-error
-                (let ((coding-system-for-write 'utf-8-unix))
-                  (with-temp-file temporary-file (insert input)))
-              (error
-               (when (file-exists-p temporary-file) (delete-file temporary-file))
-               (signal (car write-error) (cdr write-error))))
-            (setq command
-                  (list shell-file-name shell-command-switch
-                        (concat
-                         (mapconcat
-                          #'shell-quote-argument
-                          (list xargs "-0" "-r" "-n" "128"
-                                shell-file-name shell-command-switch
-                                (concat
-                                 (mapconcat
-                                  #'shell-quote-argument
-                                  (list grep "-HnZE" "--color=never"
-                                        "--binary-files=without-match"
-                                        "--no-group-separator" "-C"
-                                        (number-to-string context) "--" pattern)
-                                  " ")
-                                 " \"$@\"; code=$?; test \"$code\" -le 1")
-                                "ogent-grep")
-                          " ")
-                         " < " (shell-quote-argument temporary-file)))))
+            (if (string-empty-p input)
+                ;; Validate the regex even when the candidate set is empty.
+                ;; GNU grep compiles PATTERN before its successful no-match
+                ;; exit on the null device; xargs -r would skip compilation.
+                (setq command (list grep "-E" "--" pattern null-device))
+              (setq input (concat input "\0"))
+              (setq temporary-file (make-temp-file "ogent-grep-files-"))
+              (condition-case write-error
+                  (let ((coding-system-for-write 'utf-8-unix))
+                    (with-temp-file temporary-file (insert input)))
+                (error
+                 (when (file-exists-p temporary-file) (delete-file temporary-file))
+                 (signal (car write-error) (cdr write-error))))
+              (setq command
+                    (list shell-file-name shell-command-switch
+                          (concat
+                           (mapconcat
+                            #'shell-quote-argument
+                            (list xargs "-0" "-r" "-n" "128"
+                                  shell-file-name shell-command-switch
+                                  (concat
+                                   (mapconcat
+                                    #'shell-quote-argument
+                                    (list grep "-HnZE" "--color=never"
+                                          "--binary-files=without-match"
+                                          "--no-group-separator" "-C"
+                                          (number-to-string context) "--" pattern)
+                                    " ")
+                                   " \"$@\"; code=$?; test \"$code\" -le 1")
+                                  "ogent-grep")
+                            " ")
+                           " < " (shell-quote-argument temporary-file))))))
           (ogent-tool-process--run
            command directory ogent-tools-grep-timeout #'finish #'consume nil
            (lambda ()
```

### lisp/ogent-tools.el

Before: `3ced858f197edfb31e5943ebd9787fa1244e3867:lisp/ogent-tools.el:323`; after: `974eb31e3052278a80039b0492c1a8dcc14c1fbe:lisp/ogent-tools.el:323`.

```diff
@@ -323,11 +323,34 @@ When FORMAT is `plist' or `json', return structured lines and continuations."
         (let ((part (nth index parts)))
           (if (equal part "**")
               (if (= index last) ".*" "\\(?:[^/]+/\\)*")
-            (concat (substring (wildcard-to-regexp part) 2 -2)
+            (concat (replace-regexp-in-string
+                     (regexp-quote "[^") "[^/"
+                     (substring (wildcard-to-regexp part) 2 -2) t t)
                     (unless (= index last) "/")))))
       (number-sequence 0 last) "")
      "\\'")))
 
+(defun ogent-tools--glob-match-p (pattern path)
+  "Return non-nil when PATH matches PATTERN by complete path components."
+  (let ((parts (vconcat (split-string pattern "/")))
+        (names (vconcat (split-string path "/")))
+        (memo (make-hash-table :test #'equal)))
+    (cl-labels
+        ((match (p n)
+           (let* ((key (cons p n))
+                  (cached (gethash key memo 'missing)))
+             (if (not (eq cached 'missing)) cached
+               (let ((value
+                      (cond ((= p (length parts)) (= n (length names)))
+                            ((equal (aref parts p) "**")
+                             (or (match (1+ p) n)
+                                 (and (< n (length names)) (match p (1+ n)))))
+                            (t (and (< n (length names))
+                                    (string-match-p (wildcard-to-regexp (aref parts p)) (aref names n))
+                                    (match (1+ p) (1+ n)))))))
+                 (puthash key value memo))))))
+      (match 0 0))))
+
 (defun ogent-tools--glob-files (pattern path)
   "Return all regular files matching PATTERN under PATH, newest first."
   (let* ((case-fold-search nil)
```


## R021 — Live callable contracts, executable examples and result schema

Primary commit: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0`. Parent: `974eb31e3052278a80039b0492c1a8dcc14c1fbe`.

Discovery showed positional model arguments without the full structured SDK pagination shape; executable examples and result schema were missing or stale.

Generate call_arguments, model_arguments, aliases, structured support and examples from the live registry; add ogent-agent-describe and ogent-agent-schema, and teach call/next/async/batch in the guide.

Regression: `audit/regression_tests/R021__live_contracts.test.sh` — Discovery distinguishes real call shapes, schema has contract_version and stable collection types, metadata reads are pure, and published examples execute.

### lisp/ogent-agent.el

Before: `974eb31e3052278a80039b0492c1a8dcc14c1fbe:lisp/ogent-agent.el:190`; after: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-agent.el:204`.

```diff
@@ -190,15 +204,60 @@ per-call allow/deny rules still apply at execution time."
                                   (string< (symbol-name (plist-get a :name))
                                            (symbol-name (plist-get b :name)))))))
          :result_contract
-         (list :tool_results "text; errors are signaled or returned as Tool error: text by the execution wrapper"
+         (list :tool_results "ogent-agent-call returns versioned status/data/error/next envelopes; legacy functions default to text"
+               :schema "(ogent-agent-schema 'json)"
+               :continuation "(ogent-agent-next RESULT) follows the next page and guards snapshots"
+               :batch "ogent-agent-batch accepts up to 20 declared read-only calls"
+               :async_sdk "ogent-agent-call-async returns a process and invokes one terminal callback"
                :async_events ["stdout" "stderr" "done" "error"]
                :doctor_exit_codes (list :ok 0 :warning 1 :error 2))
          :discovery
          (list :guide "(ogent-agent-guide)"
+               :describe "(ogent-agent-describe TOOL 'json)"
                :triage "(ogent-agent-triage 'json)"
                :doctor "(ogent-doctor-batch nil 'json)"))
    format))
 
+(defun ogent-agent-describe (name &optional format)
+  "Return the exact live tool contract for NAME, optionally in FORMAT.
+Include legacy and named-call arguments, aliases, approval metadata, examples
+and actual asynchronous support.  Never construct or execute a tool."
+  (ogent-agent--output nil format)
+  (let ((spec (ogent-tool-spec-get name)))
+    (unless spec
+      (user-error "%s" (ogent-tool-contract-name-hint
+                        name (mapcar (lambda (item) (plist-get item :name)) ogent-tool-registry))))
+    (ogent-agent--output (list :contract_version "1" :tool (ogent-agent--tool spec)
+                              :result_schema "(ogent-agent-schema 'json)") format)))
+
+(defun ogent-agent-schema (&optional format)
+  "Return the JSON Schema for version 1 tool-call results in FORMAT.
+Permit additive fields and extension-specific objects under data.  Built-in
+file and process data shapes are described in `ogent-agent-guide'."
+  (ogent-agent--output
+   (list :$schema "https://json-schema.org/draft/2020-12/schema"
+         :title "ogent tool result" :type "object"
+         :required ["contract_version" "tool" "status" "data" "error" "next"]
+         :properties
+         (list :contract_version (list :const "1")
+               :tool (list :type "string")
+               :status (list :enum ["ok" "error" "denied" "approval_required" "proposed" "done"])
+               :data (list :type ["object" "null"])
+               :error (list :oneOf
+                            (vector (list :type "null")
+                                    (list :type "object" :required ["code" "message" "recovery"]
+                                          :properties (list :code (list :type "string")
+                                                            :message (list :type "string")
+                                                            :recovery (list :type "string")))))
+               :next (list :type "array"
+                           :items (list :type "object" :required ["tool" "args" "snapshot" "call"]
+                                        :properties (list :tool (list :type "string")
+                                                          :args (list :type "object")
+                                                          :snapshot (list :type "string")
+                                                          :call (list :type "string")))))
+         :additionalProperties t)
+   format))
+
 (defun ogent-agent-guide ()
   "Return a paste-ready handbook for agents using ogent's Emacs Lisp SDK."
   (concat
```

### lisp/ogent-tools.el

Before: `974eb31e3052278a80039b0492c1a8dcc14c1fbe:lisp/ogent-tools.el:1026`; after: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-tools.el:1026`.

```diff
@@ -1026,6 +1026,7 @@ If REPLACE-ALL is non-nil, replace all occurrences."
 (defvar ogent-tools-default-registry
   '((:name read-file
            :aliases ["read" "cat"]
+           :example-args (:file_path "README.org" :limit 40)
            :function ogent-tool--read-file
            :result-function ogent-tool-results-read
            :result-args ((:name "column" :type "integer" :optional t
```


## R022 — Structured JSON contracts for registered model tools

Primary commit: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3`. Parent: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0`.

The SDK structured API alone did not make model-facing registered gptel tools return versioned structured JSON, and cached tool objects could retain old argument shapes.

Add explicit ogent-tools-result-format JSON selection to registered model wrappers, include result-args in model schemas for structured tools, and refresh cached tools when schema/format changes.

Regression: `audit/regression_tests/R022__model_json_contract.test.sh` — Registered JSON read pages and cache refresh, async model callback completion, and stale registry rejection after approval. Real dependency offline fixture covers registration/FSM locally.

### lisp/ogent-models.el

Before: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-models.el:650`; after: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:lisp/ogent-models.el:657`.

```diff
@@ -650,13 +657,18 @@ Returns the list of registered tool objects."
       (let* ((name (plist-get spec :name))
              (existing (assq name ogent--tools-registered)))
         (unless (and existing
+                     (eq ogent-tools-result-format (cdr (assq name ogent--tool-formats-registered)))
                      (equal spec (cdr (assq name ogent--tool-specs-registered))))
           (ogent-unregister-tool name)
           (let ((tool (apply #'gptel-make-tool
                              :name (symbol-name name)
-                             :function (ogent-tool-execution-wrapper spec)
-                             :description (plist-get spec :description)
-                             :args (copy-tree (plist-get spec :args))
+                             :function (ogent-tool-execution-wrapper spec ogent-tools-result-format)
+                             :description (concat (plist-get spec :description)
+                                                  (when (eq ogent-tools-result-format 'json)
+                                                    " Returns JSON status/data/error/next. Follow next.tool and next.args to continue; snapshots identify consistent pages."))
+                             :args (copy-tree (append (plist-get spec :args)
+                                                      (when (eq ogent-tools-result-format 'json)
+                                                        (plist-get spec :result-args))))
                              ;; Always pass :confirm so gptel-native
                              ;; execution prompts for risky tools; a
                              ;; missing flag would let gptel auto-run
```

### lisp/ogent-tool-contract.el

Before: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-tool-contract.el:9`; after: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:lisp/ogent-tool-contract.el:9`.

```diff
@@ -9,6 +9,7 @@
 (require 'cl-lib)
 (require 'seq)
 (require 'subr-x)
+(defvar ogent-tool-registry)
 
 (defgroup ogent-tool-contract nil
   "Argument contracts for ogent tools."
```

### lisp/ogent-tool-execution.el

Before: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-tool-execution.el:179`; after: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:lisp/ogent-tool-execution.el:181`.

```diff
@@ -179,14 +181,49 @@ PROMPT is reserved for the normal interactive gptel execution path."
                 (ogent-tool-execution--failure name phase err)))))
         (if (and callback (not deferred)) (progn (deliver result) nil) result)))))
 
-(defun ogent-tool-execution-wrapper (spec)
+(defun ogent-tool-execution--json-call (spec values)
+  "Execute snapshot SPEC with gptel VALUES and return versioned JSON."
+  (let* ((name (plist-get spec :name))
+         (async (plist-get spec :async))
+         (callback (and async (pop values))) delivered)
+    (when (and async (not (functionp callback)))
+      (user-error "Async tool %s requires a callback first" name))
+    (cl-labels ((serialize (result)
+                  (concat (json-serialize result :null-object :json-null :false-object :json-false) "\n"))
+                (deliver (result)
+                  (unless delivered
+                    (setq delivered t)
+                    (funcall callback (serialize result)))))
+      (condition-case err
+          (let* ((schema (ogent-tool-execution--schema spec))
+                 (values (ogent-tool-contract-validate-values schema values))
+                 (args (cl-loop for arg in (plist-get schema :args)
+                                for value in values
+                                unless (and (plist-get arg :optional) (null value))
+                                append (list (intern (concat ":" (plist-get arg :name))) value))))
+            (if (not (equal spec (ogent-tool-spec-get name)))
+                (let ((result (ogent-tool-execution-result
+                               name "error" nil "unavailable" "Tool registry entry changed; rediscover before retrying")))
+                  (if async (deliver result) (serialize result)))
+              (if async
+                  (ogent-tool-execution-call name args #'deliver t)
+                (serialize (ogent-tool-execution-call name args nil t)))))
+        (error
+         (let ((result (ogent-tool-execution--failure name "invalid_arguments" err)))
+           (if async (deliver result) (serialize result))))))))
+
+(defun ogent-tool-execution-wrapper (spec &optional result-format)
   "Return a gptel function enforcing policy and ledger recording for SPEC.
 Adapt gptel's callback-first convention to ogent's callback-last async specs.
-Reject stale tool objects after registry removal or schema replacement."
+Reject stale tool objects after registry removal or schema replacement.
+Capture RESULT-FORMAT, defaulting to `ogent-tools-result-format'."
   ;; Preserve the function's closure environment when copying metadata.
   (let ((name (plist-get spec :name))
+        (format (or result-format ogent-tools-result-format))
         (snapshot (plist-put (copy-tree spec) :function (plist-get spec :function))))
     (lambda (&rest values)
+      (if (eq format 'json)
+          (ogent-tool-execution--json-call snapshot values)
       (let* ((async (plist-get snapshot :async))
              (callback (and async (pop values)))
              args
```

### lisp/ogent-tools.el

Before: `d6263d1b54938f895ebd8677e1e4e3488dcec9e0:lisp/ogent-tools.el:43`; after: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:lisp/ogent-tools.el:43`.

```diff
@@ -43,6 +43,14 @@
   :type 'integer
   :group 'ogent-tools)
 
+(defcustom ogent-tools-result-format 'text
+  "Result format for registered model-facing tool calls.
+Keep legacy text by default.  Select `json' for versioned status/data/error/next
+envelopes and structured pagination arguments.  Re-register tools after changing
+this option; `ogent-agent-call' always uses structured results independently."
+  :type '(choice (const text) (const json))
+  :group 'ogent-tools)
+
 
 (defcustom ogent-tools-grep-timeout 30
   "Default timeout in seconds for grep searches."
```


## R023 — Actual build/test JSON with typed failures and recovery

Primary commit: `b974cd7532599d3d5b1b87e5af41cb8b363a9c7c`. Parent: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3`.

Machine consumers had local doctor JSON but no structured report for actual makem compilation, lint and ERT execution; human logs and undifferentiated failures impeded automation.

Add makem --json/--capabilities and Make format=json integration around actual runner execution. Emit one versioned stdout report, diagnostics on stderr, real check/process status and typed exit categories with recovery.

Regression: `audit/regression_tests/R023__actual_build_reports.test.sh` — Real minimal compiler/ERT success and failure, lint warning, Make integration, prerequisites, argument errors, Unicode diagnostics, quiet human failure and cancellation.

### Makefile

Before: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:Makefile:2`; after: `b974cd7532599d3d5b1b87e5af41cb8b363a9c7c:Makefile:2`.

```diff
@@ -2,7 +2,14 @@
 # See: https://github.com/alphapapa/makem.sh
 
 EMACS ?= emacs
-MAKEM = ./makem.sh --emacs="$(EMACS)"
+MAKEM = ./makem.sh --emacs="$(EMACS)" $(REPORT)
+
+# Machine reports apply to the makem-backed targets listed in help.
+ifeq ($(format),json)
+REPORT = --json
+else ifneq ($(format),)
+$(error Unsupported format '$(format)'; use format=json or omit format)
+endif
 
 # macOS compatibility: makem.sh requires GNU coreutils and getopt.
 # If on macOS with Homebrew, prepend GNU tools to PATH.
```

### makem.sh

Before: `66bc5e8f1db5c04c2dc7a2d19568914aad01acf3:makem.sh:118`; after: `b974cd7532599d3d5b1b87e5af41cb8b363a9c7c:makem.sh:120`.

```diff
@@ -118,9 +120,174 @@ Checkdoc's spell checker may not recognize some words, causing the
 or directory-local variables using the variable
 \`ispell-buffer-session-localwords', which should be set to a list of
 strings.
+
+JSON exit codes: 0 success, 1 task failure, 2 invalid invocation,
+3 missing prerequisite, 130 interrupted, 143 terminated.
+JSON requires Python 3 and supports noninteractive rules only.  NO_COLOR and
+non-terminal stderr disable color in ordinary output too.
 EOF
 }
 
+# ** Structured reporting
+
+# Reporting observes the real runner: Emacs commands still execute in
+# run_emacs, with their output captured before the same task checks run.
+# No environment values are included in reports.
+function report-event {
+    [[ $report_dir ]] || return 0
+    python3 - "$report_dir/events.jsonl" "$@" <<'PY'
+import json
+import pathlib
+import sys
+
+kind, *values = sys.argv[2:]
+event = {"kind": kind, "values": values}
+if kind == "process":
+    event["output"] = pathlib.Path(values[2]).read_text(errors="replace")
+with open(sys.argv[1], "a", encoding="utf-8") as stream:
+    stream.write(json.dumps(event, ensure_ascii=False) + "\n")
+PY
+}
+
+function report-bootstrap-failure {
+    # The prerequisite itself cannot serialize JSON yet.  These messages are
+    # fixed literals so this minimal contract needs no ad-hoc JSON escaping.
+    local message
+    case "$1" in
+        python3) message='JSON reporting requires python3; install Python 3 or omit --json.' ;;
+        *) message='JSON reporting requires GNU mktemp and a writable temporary directory.' ;;
+    esac
+    printf 'ERROR: %s\n' "$message" >&2
+    printf '%s\n' '{"contract_version":"1","tool":"makem.sh","status":"error","exit_code":3,"exit_kind":"missing_prerequisite","exit_codes":{"0":"success","1":"task_failure","2":"invalid_invocation","3":"missing_prerequisite","130":"interrupted","143":"terminated"},"project_root":null,"requested_tasks":[],"tasks":[],"commands":[],"diagnostics":[{"source":"makem","command_index":null,"task":null,"severity":"error","file":null,"line":null,"column":null,"message":"'"$message"'"}],"next_actions":["Install the missing prerequisite or omit --json."]}'
+    exit 3
+}
+
+function report-finish {
+    local status=$1
+    # EXIT runs once; signal traps only set the status and leave through EXIT.
+    trap - EXIT INT TERM
+    if [[ $report_dir ]]
+    then
+        python3 - "$report_dir/events.jsonl" "$status" "$PWD" <<'PY' >&3
+import json
+import pathlib
+import re
+import sys
+
+events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
+exit_code = int(sys.argv[2])
+rules = ["all", "compile", "lint", "lint-checkdoc", "lint-compile",
+         "lint-declare", "lint-elsa", "lint-elint", "lint-indent", "lint-package",
+         "lint-regexps", "test", "tests", "test-buttercup", "test-ert", "batch",
+         "interactive", "test-ert-interactive"]
+exit_codes = {"0": "success", "1": "task_failure", "2": "invalid_invocation",
+              "3": "missing_prerequisite", "130": "interrupted", "143": "terminated"}
+report = {"contract_version": "1", "tool": "makem.sh", "status":
+          "success" if exit_code == 0 else "error", "exit_code": exit_code,
+          "exit_kind": exit_codes.get(str(exit_code), "task_failure"),
+          "exit_codes": exit_codes, "project_root": sys.argv[3], "requested_tasks": [],
+          "tasks": [], "commands": [], "diagnostics": [], "next_actions": []}
+ansi = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
+for event in events:
+    kind, values = event["kind"], event["values"]
+    if kind == "requested":
+        report["requested_tasks"] = values
+    elif kind == "task":
+        task, status, code, reason = values
+        report["tasks"].append({"name": task, "status": status, "exit_code": int(code),
+                                "reason": reason or None})
+    elif kind == "process":
+        task, code, _, purpose, pid, *argv = values
+        output = ansi.sub("", event["output"])
+        index = len(report["commands"])
+        command = {"task": task, "purpose": purpose, "pid": int(pid) if pid else None, "argv": argv,
+                   "exit_code": int(code), "output": output}
+        summary = re.search(r"Ran (\d+) tests?, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?", output)
+        if summary:
+            count, expected, unexpected, skipped = summary.groups()
+            command["tests"] = {"total": int(count), "expected": int(expected),
+                                "unexpected": int(unexpected), "skipped": int(skipped or 0)}
+        report["commands"].append(command)
+        # Keep raw output above so diagnostics are lossless even when an Emacs
+        # version changes its presentation.  Normalize familiar compiler/ERT
+        # lines as an additional convenience, not as the source of truth.
+        for line in output.splitlines():
+            if purpose == "availability_probe":
+                continue
+            location = re.match(r"^(.*\.el):(\d+)(?::(\d+))?:\s*(.*)$", line)
+            if location:
+                path, number, column, message = location.groups()
+                report["diagnostics"].append({"source": "emacs", "command_index": index,
+                    "task": task, "severity": "warning" if "Warning:" in message else "error",
+                    "file": path, "line": int(number), "column": int(column) if column else None,
+                    "message": message})
+            elif re.search(r"\bFAILED\b|\b[1-9]\d* unexpected\b|^Error:|^error:", line):
+                report["diagnostics"].append({"source": "emacs", "command_index": index,
+                    "task": task, "severity": "error", "file": None, "line": None,
+                    "column": None, "message": line})
+    elif kind in ("error", "warning"):
+        report["diagnostics"].append({"source": "makem", "command_index": None,
+            "task": values[0] or None, "severity": kind, "file": None,
+            "line": None, "column": None, "message": values[1]})
+    elif kind == "next":
+        report["next_actions"].extend(values)
+    elif kind == "help":
+        report["help"] = values[0]
+    elif kind == "capabilities":
+        report["capabilities"] = {"rules": rules,
+            "report_option": "--json", "discovery_command": "./makem.sh --capabilities --json",
+            "requirements": {"execution": ["bash", "git", "GNU getopt", "GNU coreutils", "gzip", "Emacs"],
+                             "json": ["python3"]},
+            "environment": {"NO_COLOR": "Disable ANSI color, including when empty"},
+            "noninteractive_json_only": True,
+            "examples": ["make test format=json", "make lint format=json",
+                         "./makem.sh --json --emacs=/path/to/emacs compile"]}
+print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
+PY
+        local report_status=$?
+        [[ $report_status == 0 ]] || status=3
+    fi
+    cleanup
+    exit "$status"
+}
+
+function report-interrupt {
+    local status=$1
+    if [[ $report_child_pid ]]
+    then
+        kill -TERM "$report_child_pid" 2>/dev/null
+        wait "$report_child_pid" 2>/dev/null
+        report-event process "${report_task:-setup}" "$status" "$report_child_output" "${report_command_purpose:-task}" "$report_child_pid" "${report_child_argv[@]}"
+        report-event task "${report_task:-setup}" error "$status" "Execution interrupted."
+    fi
+    report-event error "$report_task" "Execution interrupted."
+    exit "$status"
+}
+
+function run-rule {
+    local task=$1
+    shift
+    local report_task=$task report_skipped= before_errors=$errors
+    "$task" "$@"
+    local status=$?
+    if [[ $status != 0 && $errors == "$before_errors" ]]
+    then
+        error "Task '$task' failed with exit $status. Inspect its diagnostics and rerun make $task."
+    fi
+    [[ $errors -gt $before_errors ]] && status=1
+    if [[ $report_skipped && $status == 0 ]]
+    then
+        report-event task "$task" skipped 0 "$report_skipped"
+    elif [[ $status == 0 ]]
+    then
+        report-event task "$task" success 0 ""
+    else
+        report-event task "$task" error "$status" "Task diagnostics are included in this report."
+        report-event next "${report_rerun% }"
+    fi
+    return "$status"
+}
+
 # ** Elisp
 
 # These functions return a path to an elisp file which can be loaded
```

## Final source and evidence — 5d07d80

Current candidate: `5d07d807bc85a093725db24e33996b4af690ec0f`. Primary hunks above retain
exact primary revisions. Followups below preserve the entire correctness trail;
all local source checks are complete.

Paired aggregation at `5d07d80` is **complete through incremental validation of
retained independent A/B/third readings**, rather than new blind full readings.
Across 19 original surfaces, mean **605.26 → 656.21**, all-surface median **+11**,
ten positively changed originals have median **+77.5**, and nine originals gain
at least 100 points on a dimension. No paired composite regressed. Six new APIs
remain unpaired; eleven overlapping upgrades do not establish eleven unique
causal numeric gains.

`evidence/pass_3/triangulation/aggregation.json` pins source/input hashes.
`evidence/pass_3/scorerA/incremental_query_guard/validation.json` distinguishes
`a2fa8ce` judgments from the verified `5d07d80` target. All 59 scorer numerical
vectors are retained. Two successful fresh probes produce 20 records (16 behavior,
four identity guards); 34 prior `ff4e96c` and 18 `b7b966c` execution records are
explicitly reused. Actual-gptel nested Unicode serialization was tested offline
on both runtimes in the reused `ff4e96c` evidence. Two initial query-probe harness
failures used empty fixture files; their transcripts/prefix records are preserved
and excluded from passing conclusions. Only the evidence fixture was corrected.
219 source citations are checked/refreshed; 353 prior runtime citations and 27
old build reports are reused with unchanged Makefile/makem bytes.

This is same-model rubric evidence with floored medians/equal-weight composites;
provider throughput/latency was not measured. Historical passes 1/2 retain all
38 original row values and historical scorecard/heatmap bytes. Build JSON credit
covers historical help/compile/recompile and lint/test/runner extensions. The
unchanged `make offline-test` target receives no build-JSON output credit.

`verification/pass_3/regression_proof.json` is **complete at `5d07d80`**: all
11 wrappers genuinely exit 1 on `b3caf93` and exit 0 on the final source, with no
timeouts or skipped current ERT tests. It preserves source/fixture identities,
expected selections, actual counts and full transcript hashes.

| ID | Baseline executed / exit | Current executed / exit | Unit |
|---|---:|---:|---|
| R013 | 58 / 1 | 58 / 0 | ERT tests |
| R014 | 4 / 1 | 4 / 0 | ERT tests |
| R015 | 5 / 1 | 5 / 0 | ERT tests |
| R016 | 3 / 1 | 3 / 0 | ERT tests |
| R017 | 2 / 1 | 2 / 0 | ERT tests |
| R018 | 51 / 1 | 55 / 0 | ERT tests |
| R019 | 10 / 1 | 10 / 0 | ERT tests |
| R020 | 7 / 1 | 7 / 0 | ERT tests |
| R021 | 3 / 1 | 3 / 0 | ERT tests |
| R022 | 10 / 1 | 10 / 0 | ERT tests |
| R023 | 1 / 1 | 23 / 0 | Shell runner cases |

R018 baseline stops after the 51 process tests; current runs those plus four SDK
integrations. R023 fails on its first baseline report case and completes 23 real
current shell-runner cases. ERT/shell counts are separate units, and overlapping
selectors do not establish unique totals or causal score attribution.

Proof integrity and recorder controls are **complete at `5d07d80`**.
`verification/pass_3/regressions/integrity_check.json` validates 22 transcripts,
47 input hashes, Git source/fixture identity, exact executed selections and zero
skips/timeouts. `recorder_validation.json` records all six negative controls
rejected. Historical proof bytes remain unchanged. Earlier snapshot proofs stay
separate under `interim-b7b966c/`, `interim-ff4e96c/` and `interim-021cca4/`.

Rounds 14 and 15 are **two consecutive CLEAN independent reviews on `5d07d80`**,
with no intervening source edits and unchanged hashes of all 241 guarded tracked
files. Round 14 records 54 passing ERT invocations across Emacs 29.1/30.2,
including explicitly loaded warning-strict bytecode and actual current/minimum
gptel probes. Round 15 records 68 passing ERT invocations and two actual build
discovery/invalid-task contracts. Both have zero unexpected/skipped final ERT
results. Actual gptel serialization probes send no provider/loopback requests.

See `phase7_pass_3_review_round14.md`, `phase7_pass_3_review_round15.md` and
`evidence/pass_3/review_round15/verification-summary.json`. Round 15 preserves two
initial harness parse failures that selected no ERT tests; these are excluded
from passing/product conclusions and required only evidence-fixture correction.
Earlier raw filename/root/query findings remain recorded in unclean rounds
11/12/13; earlier CLEAN rounds 9/10 remain historical at `a2fa8ce`.
Round 10 preserves its two initial evidence-fixture allow-rule failures and all
218 final passing executions; these were not product defects or source repairs.

The final native matrix is **8/8 PASS on `5d07d80`**, completed
2026-10-08 23:59:45.035719 UTC after the two clean reviews. Start/end source SHA
and fingerprints match. [Native check records](verification/pass_3/native_checks.json)
preserve exact argv and sixteen lossless gzip transcripts with raw/gzip hashes.

| Actual native check | Total ERT | Expected | Unexpected | Skipped |
|---|---:|---:|---:|---:|
| Emacs 30.2 `make test` | 3236 | 3218 | 0 | 18 |
| Emacs 30.2 store isolation | 3236 | 3218 | 0 | 18 |
| Emacs 29.1 store isolation | 3236 | 3217 | 0 | 19 |
| Emacs 30.2 offline, current gptel | 206 | 204 | 0 | 2 |
| Emacs 30.2 offline, minimum gptel | 206 | 204 | 0 | 2 |
| Emacs 29.1 offline, current gptel | 206 | 203 | 0 | 3 |
| Emacs 29.1 offline, minimum gptel | 206 | 203 | 0 | 3 |

The eighth check, Emacs 30.2 warning-strict lint, passes. Actual `make test` uses
`--no-compile` after successful strict lint compiled the same frozen source;
the complete ERT selection remains intact. Both isolation runs show no real-store
drift. Offline runs use actual gptel 0.9.9.6/current and 0.9.9.5/minimum, Org
9.8.10 and transient 0.13.8. These native skips are disclosed separately from
the zero-skipped focused proofs/reviews. Provider requests, authentication and
inference remain zero.

The earlier `a2fa8ce` **7/8** result and lint failure remain intermediate evidence
in `verification/pass_3/native_checks_interim_a2fa8ce.json` and
`native_interim_a2fa8ce/`. Local source verification is complete. Direct push and
remote CI remain pending; their actual outcomes must be verified after push.

The original fresh source-blind exercise completed **9/9** tasks, **7/9** with
the first strategy, in **94** defined public round trips, mostly at `07f775a` with
batch `895bed7`. The seven-line README exercise accounts for 63 calls. Its
preserved summary supports no comparative efficiency claim.

The familiar `5d07d80` replay is complete **9/9** in **89** known-workflow round
trips, with ten actual command records, identical source SHA and clean start/end
path guards. It reuses tasks/fixtures, so has no fresh first-strategy or comparative
efficiency metric. `agent_simulations/post_pass_3/final_freeze/summary.json`
records actual SDK/build calls, including expected compiler/ERT failure exits
with typed source positions. The prior `b7b966c` replay is preserved with all
40 files, and 343 historical artifacts remain byte-identical. GNU fallback and
protected gptel doubles were observed; minimal independent fixtures execute real
makem compilation/ERT. This does not certify native gates or live providers.

Prior `10f86bb` and `a2fa8ce` scoring/audit snapshots remain archived with hash
indexes in `evidence/pass_3/interim_*_archive.json`. The `021cca4` proof archive
records its complete files and hashes. `evidence/pass_3/source_fixture_archives.json`
records 12 archives/408 source and fixture members. Raw `.el` copies stay ignored
because makem discovers tracked files with `git ls-files`. Ledger-context old
modules remain losslessly archived with `baseline-source-archive.json` hashes.

## Correctness followup — 967eb05 (R018 search parity)

Commit `967eb054e13104d05e818656a2b78f037cc0effd`; parent `9ac13b23032f40eccb9a627a824be45656292056`. This remains a followup to the original eleven recommendations.

### lisp/ogent-tool-process.el

Before: `9ac13b23032f40eccb9a627a824be45656292056:lisp/ogent-tool-process.el:326`; after: `967eb054e13104d05e818656a2b78f037cc0effd:lisp/ogent-tool-process.el:300`.

```diff
@@ -326,45 +300,69 @@ Retain partial output on a nonzero exit, timeout or cancellation."
 
 (defun ogent-tool-process--rg-selected-script (rg pattern context files)
   "Return a script using RG to search PATTERN with CONTEXT in ordered FILES.
-Group consecutive files by their parent and bound each group to 128 names.
-Use escaped exact filename globs to retain directory binary detection."
-  (let (directory group commands)
+Bound each consecutive group to 128 filenames and check each for NUL bytes
+before matching; a late NUL must not leave earlier lines counted as text.
+Use explicit file argv after classification, preserving file symlink paths
+without traversing any directory symlinks."
+  (let (group commands)
     (cl-labels
         ((flush ()
            (when group
              (push
               (concat
+               "set --\n"
+               (mapconcat
+                (lambda (file)
+                  (concat
+                   (mapconcat #'shell-quote-argument
+                              (list rg "--no-config" "--encoding" "none"
+                                    "-aq" "--" "\\x00" file) " ")
+                   "\nogent_binary_status=$?\ncase \"$ogent_binary_status\" in\n"
+                   "0) ;;\n1) set -- \"$@\" " (shell-quote-argument file)
+                   ";;\n*) exit \"$ogent_binary_status\" ;;\nesac\n"))
+                (nreverse group) "")
+               "if test \"$#\" -eq 0; then set -- "
+               (shell-quote-argument null-device) "; fi\n"
                (mapconcat
                 #'shell-quote-argument
-                (append
-                 (list rg "--json" "--no-config" "--sort" "path" "--color=never"
-                       "--hidden" "--no-ignore" "--max-depth" "1" "--follow"
-                       "-C" (number-to-string context))
-                 (cl-mapcan (lambda (file)
-                              (list "-g" (substring
-                                          (ogent-tool-process--literal-glob
-                                           (file-name-nondirectory file)) 1)))
-                            (nreverse group))
-                 (list "--" pattern directory))
-                " ")
-               "\nogent_rg_status=$?\n"
+                (list rg "--json" "--no-config" "--sort" "path" "--color=never"
+                      "--no-follow" "-C" (number-to-string context) "--" pattern) " ")
+               " \"$@\"\n"
+               "ogent_rg_status=$?\n"
                "case \"$ogent_rg_status\" in 0|1) ;; *) exit \"$ogent_rg_status\" ;; esac\n")
               commands)
              (setq group nil))))
       (dolist (file files)
-        (let ((parent (file-name-directory file)))
-          (when (or (not (equal parent directory)) (= (length group) 128))
-            (flush)
-            (setq directory parent))
-          (push file group)))
+        (when (= (length group) 128) (flush))
+        (push file group))
       (flush))
     (concat (apply #'concat (nreverse commands)) "exit 0\n")))
 
+(defun ogent-tool-process--gnu-text-search-command (grep pattern context)
+  "Return a GREP script to match PATTERN with CONTEXT in text-only argv files.
+Check each selected file for NUL bytes before counting any matching lines."
+  (concat
+   "ogent_first=1\nfor ogent_file do\n"
+   "if test \"$ogent_first\" -eq 1; then set --; ogent_first=0; fi\n"
+   "printf '\\000\\n' | "
+   (mapconcat #'shell-quote-argument (list grep "-aFq" "-f" "-" "--") " ")
+   " \"$ogent_file\"\nogent_binary_status=$?\n"
+   "case \"$ogent_binary_status\" in\n"
+   "0) ;;\n1) set -- \"$@\" \"$ogent_file\" ;;\n"
+   "*) exit \"$ogent_binary_status\" ;;\nesac\ndone\n"
+   "if test \"$#\" -eq 0; then set -- " (shell-quote-argument null-device) "; fi\n"
+   (mapconcat #'shell-quote-argument
+              (list grep "-HnZE" "--color=never" "--binary-files=without-match"
+                    "--no-group-separator" "-C" (number-to-string context)
+                    "--" pattern) " ")
+   " \"$@\"; code=$?; test \"$code\" -le 1"))
+
 (defun ogent-tool-process-grep-async (pattern &optional path glob-filter context-lines
                                               offset limit callback)
   "Search PATTERN and return its asynchronous local process.
 Search PATH with optional GLOB-FILTER and CONTEXT-LINES (0 through 20).
 Apply GLOB-FILTER to explicit files as well as directories; skip binary files.
+Include file symlinks; do not traverse directory symlinks beneath PATH.
 Match basename or relative path with positive component wildcards; ** matches
 zero or more components.  Treat a leading ! and brace expressions literally.
 OFFSET is zero-based; LIMIT defaults to 200 and must be 1 through 200.
```

## Correctness followup — 10f86bb (terminal ledger recovery)

Commit `10f86bb12a03f3122a60ba085be7289eb5277f5e`; parent `967eb054e13104d05e818656a2b78f037cc0effd`. This remains a followup to the original eleven recommendations.

### lisp/ogent-tool-execution.el

Before: `967eb054e13104d05e818656a2b78f037cc0effd:lisp/ogent-tool-execution.el:150`; after: `10f86bb12a03f3122a60ba085be7289eb5277f5e:lisp/ogent-tool-execution.el:168`.

```diff
@@ -150,10 +168,41 @@ or raw filename bytes that cannot be represented as Unicode."
      (_ code))
    (if (consp err) (error-message-string err) (format "%s" err))))
 
+(defun ogent-tool-execution--terminal-result (spec args data failure)
+  "Return SPEC's terminal result from ARGS, DATA and FAILURE.
+Retain completed DATA if constructing an extension result fails."
+  (condition-case err
+      (if failure
+          (let ((result (ogent-tool-execution--failure
+                         (plist-get spec :name) "execution_failed" failure)))
+            (if data
+                (plist-put result :data
+                           (if (plist-get spec :result-function) data (list :value data)))
+              result))
+        (ogent-tool-execution--success spec args data))
+    (error
+     (ogent-tool-execution-result
+      (plist-get spec :name) "error"
+      (if (plist-get spec :result-function) data (list :value data))
+      "unsupported_result"
+      (format "Tool has already completed, but its result could not be interpreted: %s"
+              (error-message-string err))))))
+
+(defun ogent-tool-execution--ledger-failure (result err)
+  "Return retained RESULT with a typed ledger failure from ERR."
+  (let* ((failure (ogent-tool-execution-result
+                   (plist-get result :tool) "error" (plist-get result :data)
+                   "ledger_write_failed" (ogent-tool-execution-ledger-warning err)))
+         (tool-error (plist-get result :error)))
+    (unless (eq tool-error :json-null)
+      (plist-put (plist-get failure :error) :tool_error tool-error))
+    (plist-put failure :next (plist-get result :next))))
+
 (defun ogent-tool-execution--start (spec args values callback)
   "Start asynchronous SPEC with ARGS, VALUES and terminal CALLBACK.
-Record exactly one ledger terminal even if the tool completes twice or fails
-after completion.  Adapt native callback-last tools to the result contract."
+Attempt one ledger terminal even if the tool completes twice or fails after
+completion.  Deliver retained results even when completion recording fails.
+Adapt native callback-last tools to the result contract."
   (let* ((name (plist-get spec :name))
          (call (list :name (symbol-name name) :args args))
          (effects (plist-get spec :effects))
```

### lisp/ui/ogent-ui-toolcalls.el

Before: `967eb054e13104d05e818656a2b78f037cc0effd:lisp/ui/ogent-ui-toolcalls.el:268`; after: `10f86bb12a03f3122a60ba085be7289eb5277f5e:lisp/ui/ogent-ui-toolcalls.el:275`.

```diff
@@ -268,24 +275,31 @@ the inspectable tool-call history that powers `ogent-debug-replay-tool'."
                                                   (plist-get spec :result-args)))
                              spec))
                    (arg-values (ogent-ui--extract-tool-args schema args))
-                   (result (apply func arg-values))
-                   (duration (float-time (time-subtract (current-time) start)))
-                   (failure (and structured (plist-get spec :result-function)
-                                 (ogent-tool-execution-process-error result))))
-              (ogent-ledger-record-tool-finish tool-call result failure duration effects)
-              (when (fboundp 'ogent-debug-log-tool-call)
-                (ogent-debug-log-tool-call
-                 (plist-put history-call :error failure) result duration))
-              result)
-          (error
-           (let ((msg (error-message-string err))
-                 (duration (float-time (time-subtract (current-time) start))))
-             (ogent-ledger-record-tool-finish tool-call nil msg duration effects)
-             (when (fboundp 'ogent-debug-log-tool-call)
-               (ogent-debug-log-tool-call
-                (plist-put history-call :error msg) nil duration))
-             (if structured (signal (car err) (cdr err))
-               (format "Tool error: %s" msg))))))
+                   (value (apply func arg-values)))
+              (setq result value))
+          (error (setq execution-error err)))
+        (let* ((duration (float-time (time-subtract (current-time) start)))
+               (failure (if execution-error
+                            (error-message-string execution-error)
+                          (and structured (plist-get spec :result-function)
+                               (ogent-tool-execution-process-error result))))
+               (ledger-error (ogent-tool-execution-record-finish
+                              tool-call result failure duration effects)))
+          (when (fboundp 'ogent-debug-log-tool-call)
+            (ogent-debug-log-tool-call
+             (plist-put history-call :error failure) result duration))
+          (cond
+           (ledger-error
+            (if structured
+                (signal 'ogent-tool-ledger-write-failed
+                        (list result execution-error ledger-error))
+              (format "%s\n[Ledger warning: %s]"
+                      (if execution-error (concat "Tool error: " failure) result)
+                      (ogent-tool-execution-ledger-warning ledger-error))))
+           (execution-error
+            (if structured (signal (car execution-error) (cdr execution-error))
+              (concat "Tool error: " failure)))
+           (t result))))
     (ogent-tool-contract-name-hint
      name (mapcar (lambda (spec) (plist-get spec :name)) ogent-tool-registry))))
 
```

## Correctness followup — a2fa8ce (per-call ledger origin)

Commit `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`; parent `10f86bb12a03f3122a60ba085be7289eb5277f5e`. This remains a followup to the original eleven recommendations.

### lisp/ogent-tool-execution.el

Before: `10f86bb12a03f3122a60ba085be7289eb5277f5e:lisp/ogent-tool-execution.el:20`; after: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60:lisp/ogent-tool-execution.el:20`.

```diff
@@ -20,14 +20,30 @@
 
 (define-error 'ogent-tool-ledger-write-failed "Tool completion ledger write failed")
 
-(defun ogent-tool-execution-record-finish (call data failure duration effects)
+(defun ogent-tool-execution-ledger-context ()
+  "Capture the enabled state and absolute destination for one tool call.
+Ledger configuration changes apply to future calls.  Preserve the caller's
+ambient context by binding captured settings only while recording events."
+  (list :enabled ogent-ledger-enabled
+        :file (and ogent-ledger-enabled (copy-sequence (ogent-ledger--file)))))
+
+(defun ogent-tool-execution-record-start (call effects context)
+  "Record CALL with EFFECTS using the captured ledger CONTEXT."
+  (let ((ogent-ledger-enabled (plist-get context :enabled))
+        (ogent-ledger-file (plist-get context :file)))
+    (ogent-ledger-record-tool-start call effects)))
+
+(defun ogent-tool-execution-record-finish (call data failure duration effects &optional context)
   "Record terminal CALL with DATA, FAILURE, DURATION and EFFECTS.
-Return the storage error on failure, preserving terminal result delivery."
-  (condition-case err
-      (progn
-        (ogent-ledger-record-tool-finish call data failure duration effects)
-        nil)
-    (error err)))
+Use captured ledger CONTEXT when supplied.  Return the storage error on
+failure, preserving terminal result delivery."
+  (let ((ogent-ledger-enabled (if context (plist-get context :enabled) ogent-ledger-enabled))
+        (ogent-ledger-file (if context (plist-get context :file) ogent-ledger-file)))
+    (condition-case err
+        (progn
+          (ogent-ledger-record-tool-finish call data failure duration effects)
+          nil)
+      (error err))))
 
 (defun ogent-tool-execution-ledger-warning (err)
   "Return a visible ledger completion warning for ERR."
```

### lisp/ui/ogent-ui-toolcalls.el

Before: `10f86bb12a03f3122a60ba085be7289eb5277f5e:lisp/ui/ogent-ui-toolcalls.el:154`; after: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60:lisp/ui/ogent-ui-toolcalls.el:155`.

```diff
@@ -154,12 +155,12 @@ Uses the :async-function and :async-callback-style from the tool spec."
                                        tool-call (and (eq type 'done) data)
                                        (and (eq type 'error) (format "%s" data))
                                        (float-time (time-subtract (current-time) start))
-                                       effects)))
+                                       effects ledger-context)))
                         (ogent-ui--streaming-drawer-append
                          drawer (format "\n[Ledger warning: %s]"
                                         (ogent-tool-execution-ledger-warning err)))))
                     (funcall base-callback type data)))))
-          (ogent-ledger-record-tool-start tool-call effects)
+          (ogent-tool-execution-record-start tool-call effects ledger-context)
           (apply async-func (append arg-values (list callback))))
       ;; Fallback: no async function found. ogent-ui--execute-tool records
       ;; its own ledger events.
```

## Correctness followup — 021cca4 (warning hygiene)

Commit `021cca4d28e7b20fba3617c57522cc5014f640f9`; parent `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`. This remains a followup to the original eleven recommendations.

### lisp/ogent-tool-results.el

Before: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60:lisp/ogent-tool-results.el:13`; after: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-results.el:13`.

```diff
@@ -13,7 +13,7 @@
 
 (defun ogent-tool-results--unicode (text)
   "Return TEXT when JSON can represent it as Unicode, otherwise signal."
-  (condition-case nil (progn (json-serialize text) text)
+  (condition-case nil (when (json-serialize text) text)
     (error (signal 'ogent-tool-results-output-error
                    '("Use a Unicode filename and a supported text encoding; raw bytes cannot be represented in structured results")))))
 
```

### lisp/ogent-agent.el

Before: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60:lisp/ogent-agent.el:74`; after: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-agent.el:74`.

```diff
@@ -74,10 +74,11 @@ Cancel a returned process with `ogent-tool-process-cancel'."
    name args (lambda (result) (funcall callback (ogent-agent--output result format)))))
 
 (defun ogent-agent-batch (calls &optional format fail-fast)
-  "Execute up to 20 explicitly read-only CALLS and return results in FORMAT.
-Accept a list or vector of call plists containing :tool and :args.  Preflight
-the entire batch before running any call.  Reject writes, shell commands and tools
-without declared read effects.  Continue after errors unless FAIL-FAST is t.
+  "Execute a bounded, read-only batch and return its output in FORMAT.
+Accept up to 20 tool call plists in CALLS as a list or vector.
+Require :tool and :args in each plist.  Preflight the entire batch.
+Reject writes, shell commands and tools without declared read effects.
+Continue after errors unless FAIL-FAST is t.
 For example, batch a glob, search and file read in one local SDK round trip."
   (ogent-agent--output nil format)
   (let ((phase "invalid_arguments") prepared results stopped)
```

## Correctness followup — ff4e96c (raw-filename glob and Unicode JSON transport)

Commit `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4`; parent `021cca4d28e7b20fba3617c57522cc5014f640f9`. This remains a followup to the original eleven recommendations.

### lisp/ogent-tool-results.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-results.el:8`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-results.el:8`.

```diff
@@ -8,6 +8,7 @@
 
 (require 'json)
 (require 'ogent-tools)
+(require 'ogent-tool-contract)
 
 (define-error 'ogent-tool-results-output-error "Unsupported file output" 'user-error)
 
```

### lisp/ogent-tool-results.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-results.el:21`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-results.el:22`.

```diff
@@ -21,8 +22,9 @@
   "Return DATA as a plist or serialize it according to FORMAT."
   (pcase format
     ('plist data)
-    ('json (concat (json-serialize data :null-object :json-null
-                                   :false-object :json-false) "\n"))
+    ('json (ogent-tool-contract--json-text
+            (concat (json-serialize data :null-object :json-null
+                                    :false-object :json-false) "\n")))
     (_ (user-error "Use (quote plist) or (quote json) for structured tool results"))))
 
 (defun ogent-tool-results-read (file-path &optional offset limit column)
```

### lisp/ogent-tool-results.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-results.el:97`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-results.el:99`.

```diff
@@ -97,7 +99,7 @@ must not exceed 200.  Report the total count and a snapshot of file metadata."
     (unless (and (integerp limit) (> limit 0) (<= limit 200))
       (user-error "Use an integer limit between 1 and 200"))
     (let* ((root (ogent-tools--resolve-path (or path ".")))
-           (files (sort (ogent-tools--glob-files pattern root) #'string<))
+           (files (sort (ogent-tools--glob-files pattern root #'ogent-tool-results--unicode) #'string<))
            (metadata (mapcar
                       (lambda (file)
                         (ogent-tool-results--unicode file)
```

### lisp/ogent-tool-contract.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-contract.el:15`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-contract.el:15`.

```diff
@@ -15,6 +15,12 @@
   "Argument contracts for ogent tools."
   :group 'ogent)
 
+(defun ogent-tool-contract--json-text (text)
+  "Return serialized JSON TEXT as Unicode characters for nested transport.
+Decode UTF-8 serializer bytes when Emacs returns an unibyte string."
+  (if (multibyte-string-p text) text
+    (decode-coding-string text 'utf-8 t)))
+
 (defun ogent-tool-contract-name-hint (name names)
   "Return a corrective lookup hint for unknown NAME among NAMES."
   (let* ((input (format "%s" name))
```

### lisp/ogent-tools.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tools.el:359`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tools.el:359`.

```diff
@@ -359,8 +359,9 @@ When FORMAT is `plist' or `json', return structured lines and continuations."
                  (puthash key value memo))))))
       (match 0 0))))
 
-(defun ogent-tools--glob-files (pattern path)
-  "Return all regular files matching PATTERN under PATH, newest first."
+(defun ogent-tools--glob-files (pattern path &optional validate-path)
+  "Return all regular files matching PATTERN under PATH, newest first.
+Call VALIDATE-PATH on each matching path before filtering regular files."
   (let* ((case-fold-search nil)
          (dir (if path
                   (ogent-tools--resolve-path path)
```

### lisp/ogent-tools.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tools.el:383`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tools.el:384`.

```diff
@@ -383,6 +384,8 @@ When FORMAT is `plist' or `json', return structured lines and continuations."
                  (lambda (file) (ogent-tools--glob-match-p relative-pattern (file-relative-name file base)))
                  (directory-files-recursively base ".")))
             (file-expand-wildcards pattern t)))
+    (when validate-path
+      (dolist (file files) (funcall validate-path file)))
     (setq files (seq-filter #'file-regular-p files))
     ;; Sort by mtime, newest first
     (setq files
```

### lisp/ogent-doctor.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-doctor.el:19`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-doctor.el:19`.

```diff
@@ -19,6 +19,7 @@
 (require 'org)
 (require 'ogent-gptel)
 (require 'ogent-models)
+(require 'ogent-tool-contract)
 
 (declare-function gptel-request "ext:gptel-request")
 (declare-function ogent-codex-oauth--auth-file "ogent-codex-oauth")
```

### lisp/ogent-doctor.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-doctor.el:724`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-doctor.el:725`.

```diff
@@ -724,8 +725,9 @@ Return 0 for ok/info, 1 for warnings, and 2 for errors."
 (defun ogent-doctor-format-json (results)
   "Return a JSON report string for doctor RESULTS.
 Keep check order stable and encode missing remediation as JSON null."
-  (concat (json-serialize (ogent-doctor-data results) :null-object :json-null)
-          "\n"))
+  (ogent-tool-contract--json-text
+   (concat (json-serialize (ogent-doctor-data results) :null-object :json-null)
+           "\n")))
 
 ;;; Commands
 
```

### lisp/ogent-tool-execution.el

Before: `021cca4d28e7b20fba3617c57522cc5014f640f9:lisp/ogent-tool-execution.el:73`; after: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-execution.el:73`.

```diff
@@ -73,14 +73,15 @@ Include a typed error with CODE and MESSAGE when supplied."
   "Serialize result DATA, returning a typed error for unsupported values.
 Preserve callback delivery even when an extension returns non-JSON objects
 or raw filename bytes that cannot be represented as Unicode."
-  (condition-case nil
-      (concat (json-serialize data :null-object :json-null :false-object :json-false) "\n")
-    (error
-     (concat (json-serialize
-              (ogent-tool-execution-result
-               "serialization" "error" nil "unsupported_output"
-               "Result cannot be represented as JSON; use Unicode filenames and JSON-compatible tool values")
-              :null-object :json-null :false-object :json-false) "\n"))))
+  (ogent-tool-contract--json-text
+   (condition-case nil
+       (concat (json-serialize data :null-object :json-null :false-object :json-false) "\n")
+     (error
+      (concat (json-serialize
+               (ogent-tool-execution-result
+                "serialization" "error" nil "unsupported_output"
+                "Result cannot be represented as JSON; use Unicode filenames and JSON-compatible tool values")
+               :null-object :json-null :false-object :json-false) "\n")))))
 
 (defun ogent-tool-execution-process-error (data)
   "Return the stable failure code for process DATA, or nil on success."
```


## Correctness followup — b7b966c (structured root and pattern guards)

Commit `b7b966c6ac5acc15d15c8ea0c70d81653072cae9`; parent `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4`. Shared R015/R018 correction, not another recommendation.

`b7b966c` validates resolved structured glob/search roots before enumeration or
target classification, including explicit/default empty or excluded raw-byte
directories. Glob also validates its reflected pattern. Unsupported values now
produce the same typed refusal in native plist, JSON and async callback-once
paths, while valid Unicode roots retain actual nonempty counts. Two new SDK
regressions fail on real `ff4e96c` on both runtimes. Scoped strict compilation,
checkdoc, canonical indentation and **9/9 compiled boundary tests pass on both
Emacs versions**; `evidence/pass_3/raw_root_contract/` preserves before/after
source evidence and logs. These remain scoped checks, not full native gates.

### lisp/ogent-tool-results.el

Before: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-results.el:98`; after: `b7b966c6ac5acc15d15c8ea0c70d81653072cae9:lisp/ogent-tool-results.el:98`.

```diff
@@ -98,7 +98,8 @@ must not exceed 200.  Report the total count and a snapshot of file metadata."
       (user-error "Use a non-negative integer offset, starting at 0"))
     (unless (and (integerp limit) (> limit 0) (<= limit 200))
       (user-error "Use an integer limit between 1 and 200"))
-    (let* ((root (ogent-tools--resolve-path (or path ".")))
+    (let* ((root (ogent-tool-results--unicode (ogent-tools--resolve-path (or path "."))))
+           (pattern (ogent-tool-results--unicode pattern))
            (files (sort (ogent-tools--glob-files pattern root #'ogent-tool-results--unicode) #'string<))
            (metadata (mapcar
                       (lambda (file)
```

### lisp/ogent-tool-process.el

Before: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-process.el:12`; after: `b7b966c6ac5acc15d15c8ea0c70d81653072cae9:lisp/ogent-tool-process.el:12`.

```diff
@@ -12,6 +12,7 @@
 (require 'seq)
 (require 'subr-x)
 (require 'ogent-tools)
+(require 'ogent-tool-results)
 
 (define-error 'ogent-tool-process-start-failed "Local process could not start" 'user-error)
 (define-error 'ogent-tool-process-search-failed "Local search failed" 'user-error)
```

### lisp/ogent-tool-process.el

Before: `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4:lisp/ogent-tool-process.el:247`; after: `b7b966c6ac5acc15d15c8ea0c70d81653072cae9:lisp/ogent-tool-process.el:248`.

```diff
@@ -247,6 +248,8 @@ Retain partial output on a nonzero exit, timeout or cancellation."
                 ogent-tool-process--max-limit))
   (unless (and (numberp ogent-tools-grep-timeout) (> ogent-tools-grep-timeout 0))
     (user-error "Invalid grep timeout; set ogent-tools-grep-timeout to positive seconds"))
+  (setq path (ogent-tool-results--unicode
+              (ogent-tools--resolve-path (or path (ogent-tools--project-root)))))
   (condition-case err
       (ogent-tools--grep-target path)
     (error (user-error "%s; use glob to find an existing search path"
```


## Correctness followup — 5d07d80 (search query and continuation guards)

Commit `5d07d807bc85a093725db24e33996b4af690ec0f`; parent `b7b966c6ac5acc15d15c8ea0c70d81653072cae9`. Shared R016/R018 correction, not another recommendation.

`5d07d80` validates structured search patterns and non-null filters as Unicode
before target/query execution, keeping reflected continuation arguments usable
in native and JSON formats. A new SDK regression covers matching/nonmatching raw
queries in sync plist/JSON and async callback-once paths with no process started;
a valid Unicode pagination control still works. The actual before-query test
fails on `b7b966c` on both runtimes. Scoped strict compilation, checkdoc, canonical
indentation and **10/10 compiled boundary tests pass per runtime**. The initial
new-test syntax harness failure is preserved separately and excluded from product
proof. See `evidence/pass_3/raw_query_contract/`.

### lisp/ogent-tool-process.el

Before: `b7b966c6ac5acc15d15c8ea0c70d81653072cae9:lisp/ogent-tool-process.el:248`; after: `5d07d807bc85a093725db24e33996b4af690ec0f:lisp/ogent-tool-process.el:248`.

```diff
@@ -248,6 +248,8 @@ Retain partial output on a nonzero exit, timeout or cancellation."
                 ogent-tool-process--max-limit))
   (unless (and (numberp ogent-tools-grep-timeout) (> ogent-tools-grep-timeout 0))
     (user-error "Invalid grep timeout; set ogent-tools-grep-timeout to positive seconds"))
+  (ogent-tool-results--unicode pattern)
+  (when glob-filter (ogent-tool-results--unicode glob-filter))
   (setq path (ogent-tool-results--unicode
               (ogent-tools--resolve-path (or path (ogent-tools--project-root)))))
   (condition-case err
```

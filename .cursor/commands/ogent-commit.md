# ogent-commit

Write a commit message for the changes in the current branch that differ from what is on the remote branch (not origin/master, but origin/<branch name>, unless i specify otherwise). Use conventional commit format:

<type>: <short description>

<optional body>

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`

The subject line should be no more than 50 characters. Use imperative mood ("add" not "added").

A body is optional. Include it only when useful context, motivation, or a summary of changes would genuinely help future readers.

Examples from this repo:

feat: harden gptel transport

feat: integrate gptel transport and streaming

docs: add installation guide and architecture specs

feat: bootstrap ogent core and tests

chore: bootstrap repo

Keep it concise. Omit fluff.

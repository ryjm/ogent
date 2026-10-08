# Canonical tasks for the primary Emacs tool and batch surfaces

The fresh-context simulator receives these goals without the audit findings.
Use in-tool Emacs documentation/introspection only. Mutations use temporary
fixtures, never user files. No provider login or inference is needed.

1. Discover available tool names, argument types, approval expectations, and
   the correction path for an unknown tool, preferably with one query.
2. Find all `.el` files recursively in a fixture with a root file and two
   nested directory depths.
3. Read a fixture in pages of two lines and determine the exact next-page
   arguments from the output.
4. Search for a pattern beginning with `-`; distinguish no matches from an
   invalid `[` regular expression.
5. Replace `same` in a fixture with two occurrences without choosing the wrong
   occurrence; explicitly request replacement of all occurrences afterward.
6. Obtain a parseable JSON local health report without contacting providers.
7. Compile with a deliberately failing Emacs fixture and detect failure from
   the exit status; use an isolated Makefile copy.

SDK adaptation: commands are batch Emacs expressions; help is `documentation`,
`apropos`, registry metadata, and any discoverable introspection endpoint.
The simulator records full argv, stdout, stderr, status, and round trips.

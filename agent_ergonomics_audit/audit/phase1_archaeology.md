# Primary surface architecture

`lisp/ogent-tools.el` implements the six default filesystem/search/shell tools
and their streaming variants. Registry descriptors carry names, argument types,
effects, confirmation flags, and model-visible descriptions. Relative paths
resolve against the configured workspace. Human string results are the current
tool contract; progress callbacks carry separate events.

`lisp/ogent-models.el` owns the live tool registry and gptel registration. Its
wrapper in `lisp/ogent-tool-execution.el` applies policy and routes edit proposals
to review. `lisp/ui/ogent-ui-toolcalls.el` owns ordered argument extraction,
execution, ledger/debug outcomes, streaming presentation, and edit proposals.
Validation must precede approval and mutation, and must serve each route.

`lisp/ogent-doctor.el` already returns structured check plists internally and
has an Org batch report with a documented 0/1/2 severity contract. Network checks
are opt-in. This gives structured automation a compatible existing foundation.

The Makefile delegates development commands to vendored `makem.sh`. The primary
project-owned surfaces are help, compile, recompile, clean, and offline-test.
There is no standalone ogent executable. The discovery script identifies Bash
from makem.sh; the scope explicitly adds the Emacs SDK surfaces.

The focused inventory contains 19 primary callable surfaces. Arguments,
diagnostics, output, and safety are assessed as parts of their owning SDK/tool
surface. This pass does not claim an exhaustive audit of the Armory or UI APIs.

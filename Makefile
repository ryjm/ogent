# ogent Makefile - delegates to makem.sh for build automation
# See: https://github.com/alphapapa/makem.sh

EMACS ?= emacs

# macOS compatibility: makem.sh requires GNU coreutils and getopt.
# If on macOS with Homebrew, prepend GNU tools to PATH.
UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
  # GNU coreutils (for mktemp, readlink, etc.)
  ifneq ($(wildcard /opt/homebrew/opt/coreutils/libexec/gnubin),)
    export PATH := /opt/homebrew/opt/coreutils/libexec/gnubin:$(PATH)
  else ifneq ($(wildcard /usr/local/opt/coreutils/libexec/gnubin),)
    export PATH := /usr/local/opt/coreutils/libexec/gnubin:$(PATH)
  endif
  # GNU getopt (for long options)
  ifneq ($(wildcard /opt/homebrew/opt/gnu-getopt/bin),)
    export PATH := /opt/homebrew/opt/gnu-getopt/bin:$(PATH)
  else ifneq ($(wildcard /usr/local/opt/gnu-getopt/bin),)
    export PATH := /usr/local/opt/gnu-getopt/bin:$(PATH)
  endif
endif

# Verbosity: v=1 for -v, v=2 for -vv, v=3 for -vvv
ifdef v
ifeq ($(v),1)
VERBOSE = -v
else ifeq ($(v),2)
VERBOSE = -vv
else ifeq ($(v),3)
VERBOSE = -vvv
endif
endif

# Sandbox mode: sandbox=1 for temp sandbox, sandbox=DIR for specific dir
ifdef sandbox
ifeq ($(sandbox),1)
SANDBOX = --sandbox
else
SANDBOX = --sandbox=$(sandbox)
endif
endif

# Install dependencies and linters
ifdef install-deps
INSTALL_DEPS = --install-deps
endif

ifdef install-linters
INSTALL_LINTERS = --install-linters
endif

# Debug mode
ifdef debug
DEBUG = --debug
endif

.PHONY: all lint test compile batch interactive sandbox-test demo help

# Default: run all lints and tests
all:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) $(INSTALL_LINTERS) all

# Lint all source files
lint:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) $(INSTALL_LINTERS) lint

# Run all tests
test:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) test

# Byte-compile source files
compile:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) compile

# Run Emacs in batch mode with project loaded
batch:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) batch

# Run Emacs interactively with project loaded
interactive:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) interactive

# Run tests in a clean sandbox
sandbox-test:
	@./makem.sh -v --sandbox --install-deps test

# Launch demo sandbox for manual validation (legacy target)
demo:
	$(EMACS) -Q sandbox/demo.org

# Catch-all rule for other makem.sh targets
%:
	@./makem.sh $(DEBUG) $(VERBOSE) $(SANDBOX) $(INSTALL_DEPS) $(INSTALL_LINTERS) $(@)

help:
	@echo "ogent Makefile targets:"
	@echo ""
	@echo "  make all          - Run all lints and tests"
	@echo "  make lint         - Run all linters (checkdoc, compile, package-lint)"
	@echo "  make test         - Run all tests"
	@echo "  make compile      - Byte-compile source files"
	@echo "  make batch        - Run Emacs in batch mode with project loaded"
	@echo "  make interactive  - Run Emacs interactively with project loaded"
	@echo "  make sandbox-test - Run tests in clean sandbox environment"
	@echo "  make demo         - Launch demo.org in minimal Emacs"
	@echo ""
	@echo "Options (pass as var=val):"
	@echo "  v=1|2|3           - Verbosity level (-v, -vv, -vvv)"
	@echo "  sandbox=1|DIR     - Run in sandbox mode"
	@echo "  install-deps=1    - Auto-install package dependencies"
	@echo "  install-linters=1 - Auto-install linting tools"
	@echo "  debug=1           - Enable debug mode"
	@echo ""
	@echo "Examples:"
	@echo "  make test v=2                    - Run tests with verbose output"
	@echo "  make lint sandbox=1              - Lint in clean sandbox"
	@echo "  make all sandbox=1 install-deps=1 - Full CI-like run"
	@echo ""
	@echo "Additional makem.sh rules (use make <rule>):"
	@echo "  lint-checkdoc, lint-compile, lint-declare, lint-indent,"
	@echo "  lint-package, lint-regexps, test-ert, test-buttercup"

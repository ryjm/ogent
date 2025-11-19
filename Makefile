EMACS ?= emacs
LISP_DIR := $(CURDIR)/lisp
TEST_DIR := $(CURDIR)/test
LISP_SOURCES := $(shell find $(LISP_DIR) -name '*.el')
TEST_FILES := $(shell find $(TEST_DIR) -name '*-tests.el')

.PHONY: lint test demo

lint:
	$(EMACS) --batch -l ert -l lint.el -f ogent-lint

# Run every ert suite in test/
test:
	$(EMACS) --batch -l ert -l test/ogent-test-helper.el -f ogent-run-tests

# Launch demo sandbox for manual validation
demo:
	$(EMACS) -Q sandbox/demo.org

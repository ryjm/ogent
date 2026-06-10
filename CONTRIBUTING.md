# Contributing to Ogent

Thank you for your interest in contributing to ogent!

## Getting Started

### Prerequisites

- Emacs 29.1 or later
- [gptel](https://github.com/karthink/gptel) 0.9+
- transient 0.6+

### Setup

```bash
# Clone the repository
git clone https://github.com/ryjm/ogent.git
cd ogent

# Verify setup - run tests
make test

# Check code style
make lint
```

### macOS Users

makem.sh requires GNU coreutils and getopt:

```bash
brew install coreutils gnu-getopt
```

The Makefile automatically detects and uses these.

## Development Workflow

### Running Tests

```bash
# Run all tests
make test

# Run with verbose output
make test v=2

# Run in clean sandbox (no user config)
make sandbox-test
```

### Linting

```bash
# Run all linters
make lint

# Individual linters
make lint-checkdoc    # Documentation conventions
make lint-compile     # Byte-compilation warnings
make lint-package     # MELPA compliance

# Lint in clean sandbox with all linters
make sandbox-lint
```

### Interactive Development

```bash
# Run Emacs with ogent loaded (uses your config)
make interactive

# Run in clean sandbox (isolated, no user config)
make sandbox
```

The sandbox mode is useful for:
- Testing without user config interference
- Reproducing bug reports
- Matching CI environment locally

## Code Style

### General Guidelines

- Use `lexical-binding: t` in all files
- Prefix all public symbols with `ogent-`
- Private symbols use `ogent--` (double dash)
- Follow [Emacs Lisp conventions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tips.html)

### Keybindings

Per Emacs conventions:
- `C-c .` prefix is used for ogent minor mode (punctuation = minor modes)
- Never bind `C-c <letter>` (reserved for users)

### File Organization

```
lisp/           # Source files
  ogent.el      # Main entry point, package headers
  ogent-core.el # Minor mode, keymap
  ogent-*.el    # Feature modules
  ui/           # UI-specific code
test/           # Test files (*-tests.el)
specs/          # Design specifications
```

## Testing

### Writing Tests

- Test files go in `test/` as `*-tests.el`
- Use ERT for unit tests
- Require `ogent-test-helper` for common utilities

```elisp
(require 'ogent-test-helper)
(require 'ogent-your-module)

(ert-deftest ogent-your-feature-does-something ()
  "Description of what the test verifies."
  (should (equal expected actual)))
```

### Test Coverage

Add tests for:
- All new public functions
- Bug fixes (regression tests)
- Edge cases and error conditions

## Debugging

### Edebug (Interactive Debugger)

```elisp
;; Instrument a function for debugging
C-u C-M-x   ; on defun to instrument

;; In Edebug:
SPC         ; step forward
n           ; next expression
c           ; continue to end
i           ; step into function
e           ; eval expression
q           ; quit
```

### Debugging Tips

- Use `message` for quick debug output
- Check `*Messages*` buffer for errors
- Use `M-x toggle-debug-on-error` for backtraces

## Pull Request Process

1. **Fork and branch**: Create a feature branch from `master`
2. **Make changes**: Follow the code style guidelines
3. **Add tests**: Include tests for new functionality
4. **Run checks**: `make all` must pass (lint + test)
5. **Commit**: Write clear commit messages
6. **Submit PR**: Describe what and why

### Commit Message Format

```
type(scope): short description

Longer explanation if needed.

Closes #issue-number (if applicable)
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

## Questions?

Open an issue for questions, bug reports, or feature requests.

# Braintrust Skill

A skill for working with Braintrust, an LLM evaluation and observability platform.

## Project Structure

```
braintrust-skill/
├── evals/              # Evaluation suite (separate package)
│   └── pyproject.toml  # Eval-specific dependencies
├── pyproject.toml      # Root tooling config (ruff, ty, pre-commit)
└── .pre-commit-config.yaml
```

## Development

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

### Setup

```bash
# Install dev tools (from repo root)
uv sync --group dev

# Install pre-commit hooks
uv run pre-commit install
```

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) hooks to ensure code quality:

- **ruff** - Fast Python linter with auto-fix (includes import sorting)
- **ruff-format** - Code formatter
- **ty** - Astral's extremely fast type checker
- **General hygiene** - Trailing whitespace, EOF fixer, YAML validation, etc.

Hooks run automatically on `git commit`. You can also run them manually:

```bash
# Run all hooks on all files
uv run pre-commit run --all-files

# Format code only
uv run ruff format .

# Lint and auto-fix
uv run ruff check . --fix
```

## Packages

### evals/

Evaluation suite for testing the Braintrust skill. See [evals/README.md](evals/README.md).

```bash
cd evals
uv sync
uv run python eval_docs_search.py
```

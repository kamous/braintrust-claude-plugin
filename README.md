# Braintrust Skill

A skill that enables AI agents to use Braintrust for LLM evaluation, logging, and observability.

## Installing the Skill

### For Claude Desktop / Claude Code

Add the skill to your Claude configuration by pointing to the `SKILL.md` file:

**Option 1: Clone the repo**
```bash
git clone https://github.com/braintrustdata/braintrust-skill.git
```

Then add to your Claude settings:
```
Skills: /path/to/braintrust-skill/skill/SKILL.md
```

**Option 2: Direct URL (if supported)**
```
Skills: https://raw.githubusercontent.com/braintrustdata/braintrust-skill/main/skill/SKILL.md
```

### For other AI agents

Copy the contents of `skill/SKILL.md` into your agent's system prompt or context.

### Requirements

The skill requires:
- `BRAINTRUST_API_KEY` environment variable set
- Python packages: `braintrust`, `autoevals`

## What the Skill Provides

The skill teaches AI agents how to:

1. **Run evaluations** with `braintrust.Eval()`
2. **Log data** with `braintrust.init_logger()`
3. **Use scorers** from `autoevals` (Factuality, etc.)
4. **Query logs** with BTQL

### Key API patterns

```python
# Correct Eval() usage - project name is FIRST POSITIONAL arg
braintrust.Eval(
    "My Project",  # NOT project_name="My Project"
    data=lambda: [...],
    task=lambda input: ...,
    scores=[Factuality],
)

# Logging with flush
logger = braintrust.init_logger(project="My Project")
logger.log(input="hello", output="world")
logger.flush()  # Important!
```

## Project Structure

```
braintrust-skill/
├── skill/                  # The skill itself
│   ├── SKILL.md           # Main skill documentation
│   └── scripts/           # Helper scripts
│       ├── run_eval.py
│       ├── log_data.py
│       └── query_logs.py
├── evals/                  # Evaluation suite
│   ├── eval_e2e_*.py      # End-to-end tests
│   └── eval_*.py          # Other evals
├── EVAL_RESULTS.md        # Skill impact analysis
└── README.md
```

## Eval Results

The skill was developed using evaluation-driven development. Results:

| Eval | Before Skill | After Skill |
|------|--------------|-------------|
| Log Fetch - Task Completed | 67% | **100%** |
| Experiment - Task Completed | 0% | **100%** |

See [EVAL_RESULTS.md](EVAL_RESULTS.md) for details.

## Development

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

### Setup

```bash
# Install dev tools
uv sync --group dev

# Install pre-commit hooks
uv run pre-commit install
```

### Running Evals

```bash
# Set your API key
export BRAINTRUST_API_KEY="your-key"

# Run all evals
uv run braintrust eval evals/

# Run specific eval
uv run braintrust eval evals/eval_e2e_log_fetch.py
```

### Pre-commit Hooks

- **ruff** - Linter with auto-fix
- **ruff-format** - Code formatter
- **ty** - Type checker

```bash
# Run all hooks
uv run pre-commit run --all-files
```

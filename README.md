# Braintrust Skill

A skill that enables AI agents to use Braintrust for LLM evaluation, logging, and observability.

## Installing the Skill

### Claude Code / Claude Agent SDK

**One-liner:**
```bash
mkdir -p ~/.claude/skills && curl -sL https://github.com/braintrustdata/braintrust-skill/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 braintrust-skill-main/skill && mv ~/.claude/skills/skill ~/.claude/skills/braintrust
```

**Or clone and copy:**
```bash
git clone https://github.com/braintrustdata/braintrust-skill.git /tmp/braintrust-skill
cp -r /tmp/braintrust-skill/skill ~/.claude/skills/braintrust
```

Claude automatically discovers skills in `~/.claude/skills/` by looking for directories containing `SKILL.md`.

### Claude.ai (web)

1. Download this repo as a ZIP file
2. Go to **Settings > Features** in Claude.ai
3. Upload the ZIP file under "Custom Skills"

### Other AI agents

Copy the contents of [`skill/SKILL.md`](skill/SKILL.md) into your agent's system prompt.

### Requirements

- `BRAINTRUST_API_KEY` environment variable
- Python packages: `braintrust`, `autoevals` (Claude will install these automatically)

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

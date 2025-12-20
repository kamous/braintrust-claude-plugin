"""
Braintrust Skill Eval: Experiment Workflows

Tests the agent's ability to create, run, analyze, and compare experiments.
This covers the full evaluation lifecycle in Braintrust.

Run with: braintrust eval evals/eval_experiments.py
"""

import os
from pathlib import Path

# Load .env file FIRST
for env_path in [Path(__file__).parent / ".env", Path(__file__).parent.parent / ".env"]:
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip('"\''))

from braintrust import Eval
from autoevals import Score


def experiment_code_scorer(output, expected, **kwargs):
    """
    Scorer that checks if the output contains correct experiment code patterns.
    """
    if not output:
        return Score(name="ExperimentCode", score=0, metadata={"reason": "empty output"})
    
    output_lower = output.lower()
    required = expected if isinstance(expected, list) else []
    
    if not required:
        return Score(name="ExperimentCode", score=1)
    
    matches = sum(1 for item in required if item.lower() in output_lower)
    score = matches / len(required)
    missing = [item for item in required if item.lower() not in output_lower]
    
    return Score(
        name="ExperimentCode",
        score=score,
        metadata={"matched": matches, "total": len(required), "missing": missing}
    )


def analysis_quality_scorer(output, expected, **kwargs):
    """
    Scorer for experiment analysis quality - checks for actionable insights.
    """
    if not output:
        return Score(name="AnalysisQuality", score=0)
    
    output_lower = output.lower()
    
    # Indicators of good analysis
    analysis_indicators = [
        "score", "improvement", "regression", "compare", "difference",
        "better", "worse", "suggest", "recommend", "because", "pattern"
    ]
    
    matches = sum(1 for ind in analysis_indicators if ind in output_lower)
    score = min(1.0, matches / 5)  # Cap at 1.0, need at least 5 indicators for full score
    
    return Score(
        name="AnalysisQuality",
        score=score,
        metadata={"analysis_indicators_found": matches}
    )


# OpenAI client via Braintrust proxy
from openai import OpenAI

client = OpenAI(
    base_url="https://api.braintrust.dev/v1/proxy",
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
)


def baseline_task(input_str):
    """Baseline task without skill - test what Claude knows about experiments."""
    response = client.chat.completions.create(
        model="claude-sonnet-4-20250514",
        messages=[
            {
                "role": "system",
                "content": """You are a helpful assistant for Braintrust, an LLM evaluation platform.

When asked about experiments:
- Use Braintrust's Eval() function with data, task, and scores parameters
- Import from 'braintrust' and 'autoevals' for scorers
- Use proper Python/TypeScript syntax
- Be specific about scorer names (Factuality, Levenshtein, etc.)

When analyzing experiments:
- Look at score distributions and identify patterns
- Compare experiments using summarize_experiment with comparison_experiment_id
- Identify improvements and regressions
- Provide actionable recommendations"""
            },
            {"role": "user", "content": input_str}
        ],
        max_tokens=1500,
    )
    return response.choices[0].message.content or ""


# Experiment workflow test cases
EXPERIMENT_DATA = [
    # Creating experiments
    {
        "input": "Write Python code to create a simple Braintrust eval that tests if an LLM can answer 'What is 2+2?' correctly. Use the Factuality scorer.",
        "expected": ["Eval", "data", "task", "scores", "Factuality", "braintrust", "autoevals"],
        "metadata": {"category": "create_experiment", "difficulty": "easy"}
    },
    {
        "input": "Write a Braintrust eval that tests a summarization task with 3 test cases. Include both Factuality and a custom length-based scorer.",
        "expected": ["Eval", "data", "task", "scores", "Factuality", "def", "score"],
        "metadata": {"category": "create_experiment", "difficulty": "medium"}
    },
    {
        "input": "How do I pass metadata to an experiment in Braintrust, like the model name and temperature I used?",
        "expected": ["metadata", "model", "Eval"],
        "metadata": {"category": "create_experiment", "difficulty": "easy"}
    },
    
    # Running experiments
    {
        "input": "How do I run a Braintrust eval from the command line?",
        "expected": ["braintrust eval", "npx", ".py", ".ts"],
        "metadata": {"category": "run_experiment", "difficulty": "easy"}
    },
    {
        "input": "How can I run an eval locally without sending results to Braintrust?",
        "expected": ["--no-send-logs", "braintrust eval"],
        "metadata": {"category": "run_experiment", "difficulty": "easy"}
    },
    
    # Analyzing experiments
    {
        "input": "I have an experiment with 60% Factuality score. How can I see which specific test cases failed?",
        "expected": ["filter", "scores", "Factuality", "< 0.5"],
        "metadata": {"category": "analyze_experiment", "difficulty": "medium"}
    },
    {
        "input": "How do I compare two experiments in Braintrust to see what improved or regressed?",
        "expected": ["compare", "summarize", "improvement", "regression"],
        "metadata": {"category": "analyze_experiment", "difficulty": "medium"}
    },
    {
        "input": "My experiment shows some test cases with low scores. How should I analyze the patterns to improve my prompt?",
        "expected": ["pattern", "input", "output", "score", "prompt"],
        "metadata": {"category": "analyze_experiment", "difficulty": "hard"}
    },
    
    # Advanced patterns
    {
        "input": "How do I create a scorer that returns multiple scores from a single function?",
        "expected": ["Score", "list", "name", "score"],
        "metadata": {"category": "advanced", "difficulty": "hard"}
    },
    {
        "input": "How do I use a dataset from Braintrust as the data source for my eval?",
        "expected": ["init_dataset", "data", "Eval"],
        "metadata": {"category": "advanced", "difficulty": "medium"}
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Experiments",
    data=lambda: EXPERIMENT_DATA,
    task=baseline_task,
    scores=[experiment_code_scorer, analysis_quality_scorer],
    metadata={
        "description": "Tests agent's ability to create, run, and analyze Braintrust experiments",
        "skill": "using-braintrust",
        "category": "experiments"
    }
)


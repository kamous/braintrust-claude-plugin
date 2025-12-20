"""
Braintrust Skill Eval: Documentation Search

Tests the agent's ability to accurately answer questions about Braintrust
concepts, APIs, and workflows. These evals measure knowledge accuracy
without requiring actual API execution.

Run with: braintrust eval evals/eval_docs_search.py
"""

import os
from pathlib import Path

# Load .env file from evals directory FIRST before any other imports
env_path = Path(__file__).parent / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"\''))

from braintrust import Eval
from autoevals import Factuality, ClosedQA


def check_contains_keywords(output, expected, **kwargs):
    """
    Scorer that checks if the output contains expected keywords/phrases.
    Returns a score between 0 and 1 based on how many expected items are present.
    
    Args:
        output: The model/agent output string
        expected: List of keywords/phrases that should be present
        **kwargs: Additional arguments (input, metadata, etc.)
    """
    from autoevals import Score
    
    if not output or not expected:
        return Score(name="ContainsKeywords", score=0, metadata={"reason": "empty output or expected"})
    
    output_lower = output.lower()
    matches = sum(1 for item in expected if item.lower() in output_lower)
    score = matches / len(expected) if expected else 0
    missing = [item for item in expected if item.lower() not in output_lower]
    
    return Score(
        name="ContainsKeywords",
        score=score,
        metadata={
            "matched": matches,
            "total": len(expected),
            "missing": missing
        }
    )


# Use OpenAI client via Braintrust proxy for baseline measurement
from openai import OpenAI

client = OpenAI(
    base_url="https://api.braintrust.dev/v1/proxy",
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
)

def baseline_task_no_skill(input: str) -> str:
    """
    Baseline task - asks Claude to answer Braintrust questions WITHOUT any skill.
    This establishes what Claude knows from training data alone.
    """
    response = client.chat.completions.create(
        model="claude-sonnet-4-20250514",
        messages=[
            {
                "role": "system",
                "content": "You are a helpful assistant. Answer questions about Braintrust, an LLM evaluation and observability platform. Be concise and specific."
            },
            {
                "role": "user", 
                "content": input
            }
        ],
        max_tokens=1024,
    )
    return response.choices[0].message.content or ""


def task_with_skill(input: str) -> str:
    """
    Task with skill - asks Claude to answer with the using-braintrust skill loaded.
    TODO: Implement once skill is built. For now, falls back to baseline.
    """
    # TODO: Load skill and invoke agent with skill context
    # For now, use baseline
    return baseline_task_no_skill(input)


# Use baseline for now - switch to task_with_skill once skill is implemented
current_task = baseline_task_no_skill


# Documentation search test cases
DOCS_SEARCH_DATA = [
    # Category: Scorers
    {
        "input": "How do I create a custom scorer that uses an LLM to judge response quality in Braintrust?",
        "expected": ["llm-as-a-judge", "typescript", "python", "scorer"],
        "metadata": {"category": "scorers", "difficulty": "medium"}
    },
    {
        "input": "What built-in scorers does Braintrust provide through autoevals?",
        "expected": ["factuality", "autoevals"],
        "metadata": {"category": "scorers", "difficulty": "easy"}
    },
    
    # Category: Experiments vs Logs
    {
        "input": "What's the difference between experiments and project logs in Braintrust?",
        "expected": ["experiment", "eval", "log", "production"],
        "metadata": {"category": "concepts", "difficulty": "medium"}
    },
    {
        "input": "How do I run an evaluation using the Eval() function?",
        "expected": ["eval", "data", "task", "scores"],
        "metadata": {"category": "experiments", "difficulty": "easy"}
    },
    
    # Category: BTQL
    {
        "input": "How do I use BTQL to find logs where the Factuality score is below 0.5?",
        "expected": ["filter", "scores.factuality", "<", "btql"],
        "metadata": {"category": "btql", "difficulty": "medium"}
    },
    {
        "input": "What is BTQL and what can I use it for?",
        "expected": ["query", "filter", "logs", "sql"],
        "metadata": {"category": "btql", "difficulty": "easy"}
    },
    {
        "input": "How do I aggregate token usage by day using BTQL?",
        "expected": ["dimensions", "measures", "sum", "metrics"],
        "metadata": {"category": "btql", "difficulty": "hard"}
    },
    
    # Category: Datasets
    {
        "input": "How do I create a dataset in Braintrust using the Python SDK?",
        "expected": ["init_dataset", "insert", "input", "expected"],
        "metadata": {"category": "datasets", "difficulty": "easy"}
    },
    {
        "input": "What fields does a dataset record have in Braintrust?",
        "expected": ["input", "expected", "metadata"],
        "metadata": {"category": "datasets", "difficulty": "easy"}
    },
    
    # Category: Tracing/Logging
    {
        "input": "How do I automatically trace OpenAI API calls in Braintrust?",
        "expected": ["wrap_openai", "init_logger", "trace"],
        "metadata": {"category": "tracing", "difficulty": "medium"}
    },
    {
        "input": "How do I add custom metadata to my Braintrust logs?",
        "expected": ["metadata", "log", "span"],
        "metadata": {"category": "tracing", "difficulty": "medium"}
    },
    
    # Category: Prompts
    {
        "input": "How does prompt versioning work in Braintrust?",
        "expected": ["version", "prompt", "slug"],
        "metadata": {"category": "prompts", "difficulty": "medium"}
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Docs Search",
    data=lambda: DOCS_SEARCH_DATA,
    task=current_task,
    scores=[check_contains_keywords],
    metadata={
        "description": "Tests agent's ability to answer Braintrust documentation questions",
        "skill": "using-braintrust",
        "category": "docs_search"
    }
)


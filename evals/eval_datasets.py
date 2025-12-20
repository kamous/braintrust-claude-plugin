"""
Braintrust Skill Eval: Dataset Management

Tests the agent's ability to create, read, update, and manage datasets.
Includes operations like adding records, querying datasets, and
creating datasets from logs.

Run with: braintrust eval evals/eval_datasets.py
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


def dataset_code_scorer(output, expected, **kwargs):
    """
    Scorer that checks if the output contains correct dataset operation patterns.
    """
    if not output:
        return Score(name="DatasetCode", score=0, metadata={"reason": "empty output"})
    
    output_lower = output.lower()
    required = expected if isinstance(expected, list) else []
    
    if not required:
        return Score(name="DatasetCode", score=1)
    
    matches = sum(1 for item in required if item.lower() in output_lower)
    score = matches / len(required)
    missing = [item for item in required if item.lower() not in output_lower]
    
    return Score(
        name="DatasetCode",
        score=score,
        metadata={"matched": matches, "total": len(required), "missing": missing}
    )


# OpenAI client via Braintrust proxy
from openai import OpenAI

client = OpenAI(
    base_url="https://api.braintrust.dev/v1/proxy",
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
)


def baseline_task(input_str):
    """Baseline task without skill - test what Claude knows about datasets."""
    response = client.chat.completions.create(
        model="claude-sonnet-4-20250514",
        messages=[
            {
                "role": "system",
                "content": """You are a helpful assistant for Braintrust, an LLM evaluation platform.

When asked about datasets:
- Use init_dataset() to create/open datasets
- Dataset records have 'input', 'expected' (optional), and 'metadata' (optional) fields
- Use insert() to add records
- Datasets can be iterated or queried with BTQL
- Use proper Python syntax with braintrust import

Provide complete, executable code examples."""
            },
            {"role": "user", "content": input_str}
        ],
        max_tokens=1500,
    )
    return response.choices[0].message.content or ""


# Dataset management test cases
DATASET_DATA = [
    # Creating datasets
    {
        "input": "Write Python code to create a new dataset called 'qa-golden' in project 'my-app' with 3 question-answer pairs.",
        "expected": ["init_dataset", "insert", "input", "expected", "my-app", "qa-golden"],
        "metadata": {"category": "create_dataset", "difficulty": "easy"}
    },
    {
        "input": "How do I add metadata like 'difficulty' and 'category' to dataset records?",
        "expected": ["metadata", "insert", "input"],
        "metadata": {"category": "create_dataset", "difficulty": "easy"}
    },
    {
        "input": "Write code to create a dataset for testing a code review assistant, with code snippets as input and review comments as expected output.",
        "expected": ["init_dataset", "insert", "input", "expected"],
        "metadata": {"category": "create_dataset", "difficulty": "medium"}
    },
    
    # Reading datasets
    {
        "input": "How do I iterate through all records in a Braintrust dataset?",
        "expected": ["init_dataset", "for", "in"],
        "metadata": {"category": "read_dataset", "difficulty": "easy"}
    },
    {
        "input": "How can I filter dataset records to only get those where metadata.difficulty equals 'hard'?",
        "expected": ["metadata", "difficulty", "filter"],
        "metadata": {"category": "read_dataset", "difficulty": "medium"}
    },
    {
        "input": "How do I use BTQL to query records from a dataset?",
        "expected": ["dataset", "from", "select"],
        "metadata": {"category": "read_dataset", "difficulty": "medium"}
    },
    
    # Creating datasets from logs
    {
        "input": "How do I copy the 10 best-scoring logs from my project into a new 'golden-examples' dataset?",
        "expected": ["init_dataset", "insert", "scores", "sort", "limit"],
        "metadata": {"category": "logs_to_dataset", "difficulty": "hard"}
    },
    {
        "input": "Write code to take logs with thumbs-up feedback and add them to a training dataset.",
        "expected": ["init_dataset", "insert", "metadata", "feedback"],
        "metadata": {"category": "logs_to_dataset", "difficulty": "medium"}
    },
    
    # Advanced operations
    {
        "input": "How do I update an existing record in a dataset?",
        "expected": ["update", "insert", "id"],
        "metadata": {"category": "update_dataset", "difficulty": "medium"}
    },
    {
        "input": "What's the best way to version my datasets in Braintrust?",
        "expected": ["version", "dataset"],
        "metadata": {"category": "versioning", "difficulty": "easy"}
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Datasets",
    data=lambda: DATASET_DATA,
    task=baseline_task,
    scores=[dataset_code_scorer],
    metadata={
        "description": "Tests agent's ability to create and manage Braintrust datasets",
        "skill": "using-braintrust",
        "category": "datasets"
    }
)


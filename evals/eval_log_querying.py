"""
Braintrust Skill Eval: Log Writing and Querying

Tests the agent's ability to write logs to Braintrust and query them using BTQL.
This eval requires actual API access to create and query logs.

Run with: braintrust eval evals/eval_log_querying.py
"""

import os
import json
from pathlib import Path

# Load .env file FIRST
env_path = Path(__file__).parent / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"\''))

# Also check parent directory
env_path_parent = Path(__file__).parent.parent / ".env"
if env_path_parent.exists():
    for line in env_path_parent.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"\''))

from braintrust import Eval
from autoevals import Score


def btql_syntax_scorer(output, expected, **kwargs):
    """
    Scorer that checks if the output contains valid BTQL syntax elements.
    
    Expected should contain required BTQL keywords/patterns for the query.
    """
    if not output:
        return Score(name="BTQLSyntax", score=0, metadata={"reason": "empty output"})
    
    output_lower = output.lower()
    
    # Check for required BTQL elements
    required = expected.get("btql_elements", []) if isinstance(expected, dict) else expected
    if not required:
        return Score(name="BTQLSyntax", score=1)
    
    matches = sum(1 for item in required if item.lower() in output_lower)
    score = matches / len(required)
    missing = [item for item in required if item.lower() not in output_lower]
    
    return Score(
        name="BTQLSyntax",
        score=score,
        metadata={
            "matched": matches,
            "total": len(required),
            "missing": missing
        }
    )


def code_execution_scorer(output, expected, **kwargs):
    """
    Scorer that checks if the output indicates successful code execution.
    Looks for signs that the agent actually ran code vs just described it.
    """
    if not output:
        return Score(name="CodeExecution", score=0)
    
    output_lower = output.lower()
    
    # Indicators of actual execution
    execution_indicators = [
        "logged", "inserted", "created", "returned", "result",
        "successfully", "completed", "records", "rows"
    ]
    
    # Indicators of just description (not execution)
    description_only = [
        "you can", "you should", "would be", "could use",
        "here's how", "example:", "to do this"
    ]
    
    exec_score = sum(1 for ind in execution_indicators if ind in output_lower) / len(execution_indicators)
    desc_penalty = sum(1 for ind in description_only if ind in output_lower) / len(description_only)
    
    # If mostly describing without executing, penalize
    final_score = max(0, exec_score - (desc_penalty * 0.5))
    
    return Score(
        name="CodeExecution",
        score=final_score,
        metadata={
            "execution_indicators": exec_score,
            "description_penalty": desc_penalty
        }
    )


# Use OpenAI client via Braintrust proxy
from openai import OpenAI

client = OpenAI(
    base_url="https://api.braintrust.dev/v1/proxy",
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
)


def baseline_task(input_data):
    """
    Baseline task - asks Claude to perform log operations WITHOUT skill.
    Claude can describe what to do but cannot actually execute without tools.
    """
    query = input_data if isinstance(input_data, str) else str(input_data)
    
    response = client.chat.completions.create(
        model="claude-sonnet-4-20250514",
        messages=[
            {
                "role": "system",
                "content": """You are a helpful assistant that helps users work with Braintrust, 
an LLM evaluation and observability platform. 

When asked to perform operations, provide the exact code or BTQL queries needed.
Use Braintrust-specific syntax (BTQL uses dimensions/measures for aggregations,
metrics.total_tokens for token counts, etc.)

Be specific and executable in your responses."""
            },
            {
                "role": "user", 
                "content": query
            }
        ],
        max_tokens=1500,
    )
    return response.choices[0].message.content or ""


# Log querying test cases
# Note: 'input' must be a top-level field for Braintrust Eval
LOG_QUERYING_DATA = [
    # BTQL Query Construction
    {
        "input": "Write a BTQL query to find all logs from the last 24 hours where the Factuality score is below 0.5",
        "expected": ["filter", "scores.Factuality", "< 0.5", "now()", "interval", "1 day"],
        "metadata": {"category": "btql_query", "difficulty": "medium"}
    },
    {
        "input": "Write a BTQL query to calculate average token usage per day for the last week",
        "expected": ["dimensions", "day(created)", "measures", "avg", "metrics.total_tokens"],
        "metadata": {"category": "btql_query", "difficulty": "hard"}
    },
    {
        "input": "Write a BTQL query to find the top 10 most expensive API calls by token count",
        "expected": ["select", "metrics.total_tokens", "sort", "desc", "limit"],
        "metadata": {"category": "btql_query", "difficulty": "medium"}
    },
    {
        "input": "Write a BTQL query to group logs by model and calculate average Factuality score for each",
        "expected": ["dimensions", "metadata.model", "measures", "avg", "scores.Factuality"],
        "metadata": {"category": "btql_query", "difficulty": "hard"}
    },
    {
        "input": "Write a BTQL query to find logs where the output contains the word 'error'",
        "expected": ["filter", "output", "ILIKE", "error"],
        "metadata": {"category": "btql_query", "difficulty": "medium"}
    },
    
    # Log Writing (code generation)
    {
        "input": "Show me Python code to log 5 sample LLM calls to a Braintrust project called 'test-project' with different user_ids in metadata",
        "expected": ["init_logger", "log", "input", "output", "metadata", "user_id"],
        "metadata": {"category": "log_writing", "difficulty": "medium"}
    },
    {
        "input": "Show me how to use wrap_openai to automatically trace all OpenAI calls",
        "expected": ["wrap_openai", "init_logger", "OpenAI"],
        "metadata": {"category": "log_writing", "difficulty": "easy"}
    },
    
    # Complex queries
    {
        "input": "Write a BTQL query to find logs where latency (metrics.duration) is greater than 5 seconds and group them by hour",
        "expected": ["dimensions", "hour(created)", "filter", "metrics.duration", "> 5"],
        "metadata": {"category": "btql_query", "difficulty": "hard"}
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Log Querying",
    data=lambda: LOG_QUERYING_DATA,
    task=baseline_task,
    scores=[btql_syntax_scorer],
    metadata={
        "description": "Tests agent's ability to write correct BTQL queries and log operations",
        "skill": "using-braintrust",
        "category": "log_querying"
    }
)


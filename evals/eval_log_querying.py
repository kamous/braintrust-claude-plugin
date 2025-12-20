"""
Braintrust skill eval: log writing and querying

Tests the agent's ability to write logs to Braintrust and query them using BTQL.

Run with: braintrust eval evals/eval_log_querying.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from braintrust import Eval
from scorers import criteria_scorer, get_anthropic_client

client = get_anthropic_client()


def baseline_task(input_data):
    """
    Baseline task - asks Claude to perform log operations WITHOUT skill.
    Claude can describe what to do but cannot actually execute without tools.
    """
    query = input_data if isinstance(input_data, str) else str(input_data)

    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=1500,
        system="""You are a helpful assistant that helps users work with Braintrust,
an LLM evaluation and observability platform.

When asked to perform operations, provide the exact code or BTQL queries needed.
Be specific and executable in your responses.""",
        messages=[{"role": "user", "content": query}],
    )
    return response.content[0].text


# Log querying test cases with natural language criteria
LOG_QUERYING_DATA = [
    # BTQL query construction
    {
        "input": "Write a BTQL query to find all logs from the last 24 hours where the Factuality score is below 0.5",
        "expected": [
            "Uses filter clause with scores.Factuality < 0.5",
            "Filters by time using created field with interval or time function",
            "Uses BTQL syntax (not generic SQL like WHERE/FROM)",
        ],
        "metadata": {"category": "btql_query", "difficulty": "medium"},
    },
    {
        "input": "Write a BTQL query to calculate average token usage per day for the last week",
        "expected": [
            "Uses dimensions clause with day(created) for time grouping",
            "Uses measures clause with avg() for aggregation",
            "References metrics.total_tokens or similar token field",
        ],
        "metadata": {"category": "btql_query", "difficulty": "hard"},
    },
    {
        "input": "Write a BTQL query to find the top 10 most expensive API calls by token count",
        "expected": [
            "References metrics.total_tokens or similar token field",
            "Uses sort with desc for descending order",
            "Uses limit to restrict to 10 results",
        ],
        "metadata": {"category": "btql_query", "difficulty": "medium"},
    },
    {
        "input": "Write a BTQL query to group logs by model and calculate average Factuality score for each",
        "expected": [
            "Uses dimensions clause with metadata.model for grouping",
            "Uses measures clause with avg(scores.Factuality)",
            "Produces one row per distinct model",
        ],
        "metadata": {"category": "btql_query", "difficulty": "hard"},
    },
    {
        "input": "Write a BTQL query to find logs where the output contains the word 'error'",
        "expected": [
            "Uses filter clause on output field",
            "Uses ILIKE, LIKE, or MATCH for text matching",
            "Includes the search term 'error'",
        ],
        "metadata": {"category": "btql_query", "difficulty": "medium"},
    },
    # Log writing (code generation)
    {
        "input": "Show me Python code to log 5 sample LLM calls to a Braintrust project called 'test-project' with different user_ids in metadata",
        "expected": [
            "Uses init_logger() to initialize logging",
            "Calls log() or similar to record entries",
            "Includes input and output fields",
            "Shows metadata with user_id field",
        ],
        "metadata": {"category": "log_writing", "difficulty": "medium"},
    },
    {
        "input": "Show me how to use wrap_openai to automatically trace all OpenAI calls",
        "expected": [
            "Imports and uses wrap_openai() function",
            "Shows init_logger() to set up the logging destination",
            "Wraps an OpenAI client instance",
        ],
        "metadata": {"category": "log_writing", "difficulty": "easy"},
    },
    # Complex queries
    {
        "input": "Write a BTQL query to find logs where latency (metrics.duration) is greater than 5 seconds and group them by hour",
        "expected": [
            "Uses filter with metrics.duration > 5 (or 5000 for ms)",
            "Uses dimensions clause with hour(created) for grouping",
            "Combines filtering and aggregation correctly",
        ],
        "metadata": {"category": "btql_query", "difficulty": "hard"},
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Log Querying",
    data=lambda: LOG_QUERYING_DATA,
    task=baseline_task,
    scores=[criteria_scorer],
    metadata={
        "description": "Tests agent's ability to write correct BTQL queries and log operations",
        "skill": "using-braintrust",
        "category": "log_querying",
    },
)

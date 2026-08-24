#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["requests"]
# ///
"""
Lightweight HumanEval-style coding benchmark for an OpenAI-compatible API.

Sends coding problems to the model, extracts the generated function, executes
it in a subprocess with a timeout, and checks against test cases. Reports
pass@1 accuracy.

Usage:
    uv run bench/eval_coding.py                        # defaults
    uv run bench/eval_coding.py --base-url http://host:8000 --temperature 0.0
"""

import argparse
import json
import os
import subprocess
import sys
import textwrap
import time

import requests

# ---------------------------------------------------------------------------
# Problems: curated subset of classic HumanEval-style tasks
# Each has: id, prompt (docstring-style), entry_point, test code
# ---------------------------------------------------------------------------

PROBLEMS = [
    {
        "id": "has_close_elements",
        "prompt": textwrap.dedent("""\
            from typing import List

            def has_close_elements(numbers: List[float], threshold: float) -> bool:
                \"\"\"Check if in given list of numbers, are any two numbers
                closer to each other than given threshold.
                >>> has_close_elements([1.0, 2.0, 3.0], 0.5)
                False
                >>> has_close_elements([1.0, 2.8, 3.0, 4.0, 5.0, 2.0], 0.3)
                True
                \"\"\"
            """),
        "entry_point": "has_close_elements",
        "tests": textwrap.dedent("""\
            assert has_close_elements([1.0, 2.0, 3.9, 4.0, 5.0, 2.2], 0.3) == True
            assert has_close_elements([1.0, 2.0, 3.9, 4.0, 5.0, 2.2], 0.05) == False
            assert has_close_elements([1.0, 2.0, 5.9, 4.0, 5.0], 0.95) == True
            assert has_close_elements([1.0, 2.0, 5.9, 4.0, 5.0], 0.8) == False
            assert has_close_elements([1.0, 2.0, 3.0, 4.0, 5.0], 2.0) == True
            assert has_close_elements([], 1.0) == False
            """),
    },
    {
        "id": "separate_paren_groups",
        "prompt": textwrap.dedent("""\
            from typing import List

            def separate_paren_groups(paren_string: str) -> List[str]:
                \"\"\"Input to this function is a string containing multiple
                groups of nested parentheses. Your goal is to separate those
                groups into separate strings and return the list of those.
                Separate groups are balanced (each open brace is properly
                closed) and not nested within each other. Ignore any spaces
                in the input string.
                >>> separate_paren_groups('( ) (( )) (( )( ))')
                ['()', '(())', '(()())']
                \"\"\"
            """),
        "entry_point": "separate_paren_groups",
        "tests": textwrap.dedent("""\
            assert separate_paren_groups('(()()) ((())) () ((())()())') == [
                '(()())', '((()))', '()', '((())()())']
            assert separate_paren_groups('() (()) ((())) (((())))') == [
                '()', '(())', '((()))', '(((())))']
            assert separate_paren_groups('(()(()))') == ['(()(()))']
            assert separate_paren_groups('( ) (( )) (( )( ))') == [
                '()', '(())', '(()())']
            """),
    },
    {
        "id": "truncate_number",
        "prompt": textwrap.dedent("""\
            def truncate_number(number: float) -> float:
                \"\"\"Given a positive floating point number, it can be
                decomposed into an integer part (largest integer smaller than
                given number) and decimals (leftover part always smaller
                than 1). Return the decimal part of the number.
                >>> truncate_number(3.5)
                0.5
                \"\"\"
            """),
        "entry_point": "truncate_number",
        "tests": textwrap.dedent("""\
            assert truncate_number(3.5) == 0.5
            assert abs(truncate_number(1.33) - 0.33) < 1e-6
            assert abs(truncate_number(123.456) - 0.456) < 1e-6
            """),
    },
    {
        "id": "below_zero",
        "prompt": textwrap.dedent("""\
            from typing import List

            def below_zero(operations: List[int]) -> bool:
                \"\"\"You're given a list of deposit and withdrawal operations
                on a bank account that starts with zero balance. Your task is
                to detect if at any point the balance of account falls below
                zero, and at that point function should return True.
                Otherwise it should return False.
                >>> below_zero([1, 2, 3])
                False
                >>> below_zero([1, 2, -4, 5])
                True
                \"\"\"
            """),
        "entry_point": "below_zero",
        "tests": textwrap.dedent("""\
            assert below_zero([]) == False
            assert below_zero([1, 2, -3, 1, 2, -3]) == False
            assert below_zero([1, 2, -4, 5, 6]) == True
            assert below_zero([1, -1, 2, -2, 5, -5, 4, -4]) == False
            assert below_zero([1, -1, 2, -2, 5, -5, 4, -5]) == True
            assert below_zero([1, -2]) == True
            """),
    },
    {
        "id": "mean_absolute_deviation",
        "prompt": textwrap.dedent("""\
            from typing import List

            def mean_absolute_deviation(numbers: List[float]) -> float:
                \"\"\"For a given list of input numbers, calculate Mean
                Absolute Deviation around the mean of this dataset.
                Mean Absolute Deviation is the average absolute difference
                between each element and a centerpoint (mean in this case):
                MAD = average | x - x_mean |
                >>> mean_absolute_deviation([1.0, 2.0, 3.0, 4.0])
                1.0
                \"\"\"
            """),
        "entry_point": "mean_absolute_deviation",
        "tests": textwrap.dedent("""\
            assert abs(mean_absolute_deviation([1.0, 2.0, 3.0]) - 2/3) < 1e-6
            assert abs(mean_absolute_deviation([1.0, 2.0, 3.0, 4.0]) - 1.0) < 1e-6
            assert abs(mean_absolute_deviation([1.0, 2.0, 3.0, 4.0, 5.0]) - 1.2) < 1e-6
            """),
    },
    {
        "id": "intersperse",
        "prompt": textwrap.dedent("""\
            from typing import List

            def intersperse(numbers: List[int], delimiter: int) -> List[int]:
                \"\"\"Insert a number 'delimiter' between every two consecutive
                elements of input list `numbers`.
                >>> intersperse([], 4)
                []
                >>> intersperse([1, 2, 3], 4)
                [1, 4, 2, 4, 3]
                \"\"\"
            """),
        "entry_point": "intersperse",
        "tests": textwrap.dedent("""\
            assert intersperse([], 7) == []
            assert intersperse([5, 6, 3, 2], 8) == [5, 8, 6, 8, 3, 8, 2]
            assert intersperse([2, 2, 2], 2) == [2, 2, 2, 2, 2]
            """),
    },
    {
        "id": "parse_nested_parens",
        "prompt": textwrap.dedent("""\
            from typing import List

            def parse_nested_parens(paren_string: str) -> List[int]:
                \"\"\"Input to this function is a string represented multiple
                groups of nested parentheses separated by spaces. For each of
                the group, output the deepest level of nesting of parentheses.

                E.g. (()()) has maximum two levels of nesting while ((())) has
                three.

                >>> parse_nested_parens('(()()) ((())) () ((())()())')
                [2, 3, 1, 3]
                \"\"\"
            """),
        "entry_point": "parse_nested_parens",
        "tests": textwrap.dedent("""\
            assert parse_nested_parens('(()()) ((())) () ((())()())') == [2, 3, 1, 3]
            assert parse_nested_parens('() (()) ((())) (((())))') == [1, 2, 3, 4]
            assert parse_nested_parens('(()(())((())))') == [4]
            """),
    },
    {
        "id": "filter_by_substring",
        "prompt": textwrap.dedent("""\
            from typing import List

            def filter_by_substring(strings: List[str], substring: str) -> List[str]:
                \"\"\"Filter an input list of strings only for ones that
                contain given substring.
                >>> filter_by_substring([], 'a')
                []
                >>> filter_by_substring(['abc', 'bacd', 'cde', 'array'], 'a')
                ['abc', 'bacd', 'array']
                \"\"\"
            """),
        "entry_point": "filter_by_substring",
        "tests": textwrap.dedent("""\
            assert filter_by_substring([], 'john') == []
            assert filter_by_substring(['xxx', 'asd', 'xxy', 'john doe', 'xxxuj', 'xxx heed'], 'xxx') == ['xxx', 'xxy', 'xxxuj', 'xxx heed']
            assert filter_by_substring(['xxx', 'asd', 'aaber', 'john doe', 'xxxuj', 'xxx heed'], 'xx') == ['xxx', 'xxxuj', 'xxx heed']
            assert filter_by_substring(['grunt', 'hierarchical', 'hierarchies'], 'hierarchi') == ['hierarchical', 'hierarchies']
            """),
    },
    {
        "id": "sum_product",
        "prompt": textwrap.dedent("""\
            from typing import List, Tuple

            def sum_product(numbers: List[int]) -> Tuple[int, int]:
                \"\"\"For a given list of integers, return a tuple consisting
                of a sum and a product of all the integers in a list.
                Empty sum should be equal to 0 and empty product should be
                equal to 1.
                >>> sum_product([])
                (0, 1)
                >>> sum_product([1, 2, 3, 4])
                (10, 24)
                \"\"\"
            """),
        "entry_point": "sum_product",
        "tests": textwrap.dedent("""\
            assert sum_product([]) == (0, 1)
            assert sum_product([1, 1, 1]) == (3, 1)
            assert sum_product([100, 0]) == (100, 0)
            assert sum_product([3, 5, 7]) == (15, 105)
            assert sum_product([10]) == (10, 10)
            """),
    },
    {
        "id": "rolling_max",
        "prompt": textwrap.dedent("""\
            from typing import List

            def rolling_max(numbers: List[int]) -> List[int]:
                \"\"\"From a given list of integers, generate a list of rolling
                maximum element found until given moment in the sequence.
                >>> rolling_max([1, 2, 3, 2, 3, 4, 2])
                [1, 2, 3, 3, 3, 4, 4]
                \"\"\"
            """),
        "entry_point": "rolling_max",
        "tests": textwrap.dedent("""\
            assert rolling_max([]) == []
            assert rolling_max([1, 2, 3, 4]) == [1, 2, 3, 4]
            assert rolling_max([4, 3, 2, 1]) == [4, 4, 4, 4]
            assert rolling_max([3, 2, 3, 100, 3]) == [3, 3, 3, 100, 100]
            """),
    },
    {
        "id": "make_palindrome",
        "prompt": textwrap.dedent("""\
            def make_palindrome(string: str) -> str:
                \"\"\"Find the shortest palindrome that begins with a supplied
                string. Algorithm idea is simple:
                - Find the longest postfix of supplied string that is a
                  palindrome.
                - Append to the end of the string reverse of a string prefix
                  that comes before the palindromic suffix.
                >>> make_palindrome('')
                ''
                >>> make_palindrome('cat')
                'catac'
                >>> make_palindrome('cata')
                'catac'
                \"\"\"
            """),
        "entry_point": "make_palindrome",
        "tests": textwrap.dedent("""\
            assert make_palindrome('') == ''
            assert make_palindrome('x') == 'x'
            assert make_palindrome('xyz') == 'xyzyx'
            assert make_palindrome('xyx') == 'xyx'
            assert make_palindrome('jerry') == 'jerryrrej'
            """),
    },
    {
        "id": "remove_vowels",
        "prompt": textwrap.dedent("""\
            def remove_vowels(text: str) -> str:
                \"\"\"Remove all vowels from the string.
                >>> remove_vowels('')
                ''
                >>> remove_vowels("abcdef\\nghijklm")
                'bcdf\\nghjklm'
                >>> remove_vowels('abcdef')
                'bcdf'
                \"\"\"
            """),
        "entry_point": "remove_vowels",
        "tests": textwrap.dedent("""\
            assert remove_vowels('') == ''
            assert remove_vowels("abcdef\\nghijklm") == 'bcdf\\nghjklm'
            assert remove_vowels('abcdef') == 'bcdf'
            assert remove_vowels('aaBAA') == 'B'
            assert remove_vowels('zbcd') == 'zbcd'
            """),
    },
    {
        "id": "below_threshold",
        "prompt": textwrap.dedent("""\
            from typing import List

            def below_threshold(l: List[int], t: int) -> bool:
                \"\"\"Return True if all numbers in the list l are below
                threshold t.
                >>> below_threshold([1, 2, 4, 10], 100)
                True
                >>> below_threshold([1, 20, 4, 10], 5)
                False
                \"\"\"
            """),
        "entry_point": "below_threshold",
        "tests": textwrap.dedent("""\
            assert below_threshold([1, 2, 4, 10], 100) == True
            assert below_threshold([1, 20, 4, 10], 5) == False
            assert below_threshold([1, 20, 4, 10], 21) == True
            assert below_threshold([1, 20, 4, 10], 22) == True
            assert below_threshold([1, 8, 4, 10], 11) == True
            assert below_threshold([1, 8, 4, 10], 10) == False
            """),
    },
    {
        "id": "unique",
        "prompt": textwrap.dedent("""\
            from typing import List

            def unique(l: List[int]) -> List[int]:
                \"\"\"Return sorted unique elements in a list.
                >>> unique([5, 3, 5, 2, 3, 3, 9, 0, 123])
                [0, 2, 3, 5, 9, 123]
                \"\"\"
            """),
        "entry_point": "unique",
        "tests": textwrap.dedent("""\
            assert unique([5, 3, 5, 2, 3, 3, 9, 0, 123]) == [0, 2, 3, 5, 9, 123]
            """),
    },
    {
        "id": "flip_case",
        "prompt": textwrap.dedent("""\
            def flip_case(string: str) -> str:
                \"\"\"For a given string, flip lowercase characters to
                uppercase and uppercase to lowercase.
                >>> flip_case('Hello')
                'hELLO'
                \"\"\"
            """),
        "entry_point": "flip_case",
        "tests": textwrap.dedent("""\
            assert flip_case('') == ''
            assert flip_case('Hello!') == 'hELLO!'
            assert flip_case('These violent delights have violent ends') == 'tHESE VIOLENT DELIGHTS HAVE VIOLENT ENDS'
            """),
    },
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def query_model(
    base_url: str,
    model: str,
    prompt: str,
    temperature: float,
    max_tokens: int,
    reasoning_effort: str | None,
    timeout: int,
) -> tuple[str, str, int]:
    """Send a chat completion request.

    Returns (content, finish_reason, completion_tokens). The caller needs the
    finish reason because a run truncated at the token cap scores identically to
    a wrong answer, and reporting the two together would misattribute a budget
    problem as a quality result.
    """
    body: dict = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a Python coding assistant. Complete the "
                    "function. Return ONLY the Python code, no markdown "
                    "fences, no explanation."
                ),
            },
            {
                "role": "user",
                "content": (
                    "Complete this function:\n\n" + prompt
                ),
            },
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    # llama.cpp b10423 accepts the OpenAI-standard top-level `reasoning_effort`
    # and silently ignores it for the low/medium/xhigh ladder. Only
    # chat_template_kwargs reaches the template, so the sweep must use that form
    # or every arm would measure the same shipped default.
    if reasoning_effort is not None:
        body["chat_template_kwargs"] = {"reasoning_effort": reasoning_effort}

    resp = requests.post(
        f"{base_url}/v1/chat/completions",
        json=body,
        timeout=timeout,
    )
    resp.raise_for_status()
    payload = resp.json()
    choice = payload["choices"][0]
    return (
        choice["message"]["content"] or "",
        choice.get("finish_reason") or "unknown",
        (payload.get("usage") or {}).get("completion_tokens", 0),
    )


def extract_code(prompt: str, completion: str) -> str:
    """Combine prompt with completion, stripping markdown fences."""
    code = completion.strip()
    # Strip markdown code fences if present
    if code.startswith("```"):
        lines = code.split("\n")
        lines = lines[1:]  # drop opening fence
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        code = "\n".join(lines)

    # If the completion includes the full function (re-states the prompt),
    # use it as-is; otherwise prepend the prompt
    if "def " in code:
        return code
    return prompt + code


def run_tests(code: str, tests: str, timeout: int = 10) -> tuple[bool, str]:
    """Execute code + tests in a subprocess. Returns (passed, details)."""
    full = code + "\n\n" + tests
    try:
        result = subprocess.run(
            [sys.executable, "-c", full],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode == 0:
            return True, "ok"
        return False, result.stderr.strip().split("\n")[-1]
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as exc:
        return False, str(exc)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Coding eval against an OpenAI-compatible API",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("BENCH_BASE_URL", "http://127.0.0.1:8000"),
    )
    parser.add_argument("--model", default=None, help="Model name (auto-detect if omitted)")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=32000,
        help=(
            "Completion cap. Must exceed the expected reasoning trace or the "
            "run measures the cap instead of the model."
        ),
    )
    parser.add_argument(
        "--reasoning-effort",
        choices=["low", "medium", "xhigh"],
        default=None,
        help=(
            "Sent as chat_template_kwargs.reasoning_effort. Omit for models "
            "without a reasoning ladder."
        ),
    )
    parser.add_argument(
        "--request-timeout",
        type=int,
        default=1800,
        help="HTTP timeout per problem (s)",
    )
    parser.add_argument("--timeout", type=int, default=10, help="Per-test execution timeout (s)")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    # Auto-detect model name from server
    if args.model is None:
        resp = requests.get(f"{args.base_url}/v1/models", timeout=10)
        resp.raise_for_status()
        models = resp.json()["data"]
        if not models:
            print("ERROR: no models found at server", file=sys.stderr)
            sys.exit(1)
        args.model = models[0]["id"]
        print(f"Detected model: {args.model}")

    passed = 0
    failed = 0
    errors = 0
    truncated = 0
    total_time = 0.0
    total_completion_tokens = 0

    effort_label = args.reasoning_effort or "(none sent)"
    print(f"\nRunning {len(PROBLEMS)} coding problems against {args.base_url}")
    print(f"Model: {args.model}  Temperature: {args.temperature}")
    print(f"Reasoning effort: {effort_label}  Max tokens: {args.max_tokens}\n")
    print(f"{'#':<4} {'Problem':<30} {'Result':<10} {'Time':>8} {'Tokens':>8}")
    print("-" * 65)

    for i, problem in enumerate(PROBLEMS, 1):
        t0 = time.time()
        try:
            completion, finish_reason, completion_tokens = query_model(
                args.base_url,
                args.model,
                problem["prompt"],
                args.temperature,
                args.max_tokens,
                args.reasoning_effort,
                args.request_timeout,
            )
            elapsed = time.time() - t0
            total_time += elapsed
            total_completion_tokens += completion_tokens

            code = extract_code(problem["prompt"], completion)
            ok, detail = run_tests(code, problem["tests"], timeout=args.timeout)

            # A completion cut off at the cap is a budget failure, not a wrong
            # answer. Counting them together is what makes a capped run look
            # like a quality result.
            was_truncated = finish_reason == "length"
            if was_truncated:
                truncated += 1

            if ok:
                passed += 1
                status = "PASS"
            else:
                failed += 1
                status = "TRUNC" if was_truncated else "FAIL"

            print(
                f"{i:<4} {problem['id']:<30} {status:<10} "
                f"{elapsed:>7.1f}s {completion_tokens:>8}"
            )
            if args.verbose and not ok:
                print(f"     finish_reason: {finish_reason}")
                print(f"     Detail: {detail}")
                print(f"     Code:\n{textwrap.indent(code, '       ')}")
        except Exception as exc:
            elapsed = time.time() - t0
            total_time += elapsed
            errors += 1
            print(f"{i:<4} {problem['id']:<30} {'ERROR':<10} {elapsed:>7.1f}s {'-':>8}")
            if args.verbose:
                print(f"     {exc}")

    total = len(PROBLEMS)
    print("-" * 65)
    print(f"\nResults: {passed}/{total} passed ({passed/total*100:.0f}%)")
    print(f"  Passed:     {passed}")
    print(f"  Failed:     {failed}")
    print(f"  Errors:     {errors}")
    print(f"  Truncated:  {truncated}")
    print(f"  Total time: {total_time:.1f}s")
    print(f"  Avg latency: {total_time/total:.1f}s/problem")
    print(f"  Completion tokens: {total_completion_tokens} "
          f"({total_completion_tokens/total:.0f}/problem)")

    if truncated:
        print(
            f"\nWARNING: {truncated} problem(s) hit the {args.max_tokens}-token "
            "cap. This run measures the cap, not the model. Raise --max-tokens "
            "and re-run before recording it as a quality result."
        )

    # Exit with failure if less than 50% pass rate
    sys.exit(0 if passed / total >= 0.5 else 1)


if __name__ == "__main__":
    main()

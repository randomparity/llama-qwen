#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Derive this repo's chat template from the model's own.

The vendored template under `templates/` is a one-substitution patch of the
template embedded in the GGUF. Keeping the patch as code rather than as a
hand-edited copy means a model update that moves the patched region fails loudly
here instead of silently shipping a stale fork of the prompt format.

Usage:
    patch_template.py --in stock.jinja --out templates/qwen3.8-27b.jinja
    patch_template.py --in stock.jinja --check templates/qwen3.8-27b.jinja
"""

import argparse
import pathlib
import sys

# The stock template refuses to render a system message that is not first. The
# guard is authored, not accidental, but it returns HTTP 500 and no completion,
# which wedges any agent loop that injects a system message mid-conversation.
# Render it as its own system turn instead. Nothing else is changed: the
# reasoning-effort ladder, preserve_thinking, and the native <function=...> tool
# format are all left exactly as the model ships them.
GUARD = """    {%- if message.role == "system" or message.role == "developer" %}
        {{- raise_exception('System message must be at the beginning.') }}"""

REPLACEMENT = """    {%- if message.role == "system" or message.role == "developer" %}
        {{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}"""


def derive(stock: str) -> str:
    """Apply the patch, insisting the target region appears exactly once."""
    found = stock.count(GUARD)
    if found != 1:
        raise SystemExit(
            f"expected exactly 1 system-message guard in the stock template, "
            f"found {found}. The model's template changed shape — re-derive the "
            f"patch by hand before shipping it."
        )
    return stock.replace(GUARD, REPLACEMENT)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--in", dest="stock", required=True, type=pathlib.Path)
    parser.add_argument("--out", dest="out", type=pathlib.Path)
    parser.add_argument(
        "--check",
        dest="check",
        type=pathlib.Path,
        help="Compare against an existing vendored template instead of writing.",
    )
    args = parser.parse_args()

    if (args.out is None) == (args.check is None):
        raise SystemExit("pass exactly one of --out or --check")

    derived = derive(args.stock.read_text())

    if args.out is not None:
        args.out.write_text(derived)
        print(f"wrote {args.out} ({len(derived)} chars)")
        return

    current = args.check.read_text()
    if current != derived:
        print(
            f"{args.check} is stale: it does not match the patch derived from "
            f"the model's current template. Regenerate it with --out.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"{args.check} matches the model's template plus the documented patch.")


if __name__ == "__main__":
    main()

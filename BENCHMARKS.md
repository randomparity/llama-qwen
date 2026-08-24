# Verification results

Measured on 2026-08-14 on the target RTX A6000 host.

## Qwen3.8-27B Q6_K

- Context allocation: 262,144 tokens, one slot
- Idle VRAM: 31,002 MiB
- VRAM during 250K prefill: 32,061 MiB
- Basic OpenAI-compatible chat: passed
- Separated reasoning content: passed
- Structured tool call with JSON arguments: passed
- Long-context retrieval: passed at 250,035 prompt tokens
- Long-context prefill: 508.5 tokens/s average
- Decode after 250K prefill: 12.8 tokens/s

Coding benchmark (`bench/eval_coding.py`, temperature 0):

- Result: 11/15 (73%)
- Total time: 269.2 seconds
- Average latency: 17.9 seconds/problem
- Default thinking was enabled.

## Reasoning-effort plumbing (llama.cpp b10423)

Measured 2026-08-24 by comparing rendered prompts from `/apply-template`.

| Request path | Prompt digest | Steers? |
| --- | --- | --- |
| no effort field | `dff9882a` | n/a — shipped default (xhigh) |
| `reasoning_effort: "low"` | `dff9882a` | no — silently ignored |
| `reasoning_effort: "medium"` | `dff9882a` | no — silently ignored |
| `reasoning_effort: "xhigh"` | `dff9882a` | indistinguishable from default |
| `reasoning_effort: "none"` | `3ba0073f` | yes — maps to thinking-off |
| `chat_template_kwargs.reasoning_effort: "low"` | `d7cc8711` | yes |
| `chat_template_kwargs.reasoning_effort: "medium"` | `badbf419` | yes |
| `chat_template_kwargs.enable_thinking: false` | `3ba0073f` | yes |

This build has no `--reasoning-effort` flag. The OpenAI-standard top-level
`reasoning_effort` field steers only `"none"`; the low/medium/xhigh ladder is
accepted and dropped. Generation confirms it: the same prompt at `"low"`,
`"medium"`, and `"xhigh"` returned byte-identical output (70 completion tokens,
220 reasoning characters) at `temperature: 0`.

Consequences for earlier results on this page:

- The coding benchmark below sent no effort field at all, so it ran at `xhigh`.
- The long-context probe uses `"none"`, which does work — but that means the
  250,035-token retrieval pass was measured with thinking disabled and is not a
  quality result.
- `scripts/smoke.sh` previously sent `reasoning_effort: "low"` for its reasoning
  and tool-call cases, so those ran at `xhigh` despite the request. Both now use
  `chat_template_kwargs`.

The server default is now set explicitly via
`--chat-template-kwargs '{"reasoning_effort":"medium"}'`, and `just smoke`
asserts the default reaches the template. **`medium` is provisional** — it is not
yet backed by a quality measurement on this host. The three-arm sweep will
either confirm it or replace it.

## Reasoning preservation and the stock chat template

Template extracted authoritatively from the running server's `/props` endpoint
(9,993 characters), not by scanning the GGUF.

- `supports_preserve_reasoning` does **not** appear in the template. llama.cpp's
  `--reasoning-preserve` keys on that capability, so the flag was inert and has
  been removed from `just start`.
- The template preserves reasoning through its own variable instead:
  `preserve_thinking is undefined or preserve_thinking is true` guards the branch
  that re-emits `<think>` blocks for prior turns. Undefined means **on**, so
  preservation was already the default.
- Verified behaviourally: a four-message history with sentinel traces renders both
  sentinels by default, and neither under
  `chat_template_kwargs: {"preserve_thinking": false}`. Removing
  `--reasoning-preserve` and restarting changed nothing, confirming it was a no-op.
- `just smoke` now asserts multi-turn preservation directly.

The template also confirms two behaviours reported elsewhere:
`reasoning_effort|default('xhigh')` sets the shipped default, and an effort
outside `low`/`medium`/`xhigh` raises rather than falling back (`high` is aliased
to `xhigh`).

### Decision: do not adopt a third-party chat template

The reasons to switch do not survive measurement on this setup. Preserve-reasoning
already works, and thoughts are already emitted chronologically, so the KV
prefix-caching benefit is already present. That leaves no benefit worth taking on
an unpinned external artifact that replaces the model's own prompt format and
would invalidate any benchmark measured against the stock template.

## Devstral Small 2 24B FP8 baseline

The unchanged service was restarted and tested with the same coding command,
host, GPU, test set, and temperature.

- Result: 14/15 (93%)
- Total time: 55.2 seconds
- Average latency: 3.7 seconds/problem

## Decision

Keep Devstral as the active default for now. Qwen provides the required 256K
context and passes the agent API checks, but this initial benchmark does not
support a quality or latency improvement claim. Before cutting over, evaluate
Qwen with a representative agentic workload and compare thinking-disabled and
thinking-enabled policies separately.

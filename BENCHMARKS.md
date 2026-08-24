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
- Default thinking was enabled — which means `xhigh` (see the sweep below).

### Reasoning-effort sweep (2026-08-24)

Run with the vendored harness at `--max-tokens 32000`, effort sent through
`chat_template_kwargs` because the top-level field is inert on this build.

| Effort | Score | Total time | Avg latency | Tokens/problem |
| --- | --- | --- | --- | --- |
| low | 8/15 (53%) | 70.7 s | 4.7 s | 283 |
| medium | 8/15 (53%) | 92.6 s | 6.2 s | 364 |
| xhigh | 11/15 (73%) | 269.6 s | 18.0 s | 895 |

**No arm truncated a single problem.** An earlier hypothesis on this page's
`xhigh` figure — that the original 1024-token cap had cut completions off and the
run was measuring the cap — is refuted. Only `make_palindrome` runs long (7,336
tokens); the other fourteen fit inside the old cap. The `xhigh` arm also
reproduces the original result closely, 11/15 at 18.0 s against 11/15 at 17.9 s,
so the figures recorded above stand.

Two results run against the community reporting that prompted this sweep:

- **`xhigh` earns its cost on this eval.** It is +20 points over both lower
  efforts for 3.2x the tokens of `low`, not the reported 7-11x multiplier, and
  the lower efforts do not converge to within a few points. The claim that `low`
  is the rational preset does not hold here.
- **`medium` is strictly dominated.** Identical score to `low`, 31% more wall
  time, 29% more tokens. No workload on this eval prefers it.

Limits worth keeping in view: 15 problems is a small sample and 8 vs 11 is a
three-problem gap, so treat the ordering as indicative rather than established.
The problems are short HumanEval-style completions, which is the shape reported to
flatter lower efforts least; a long-horizon agentic task could order differently.

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

That decision was tested against a concrete candidate and held. The templates at
`HarryMayne/qwen_3_chat_templates` were run against this model:

| Behaviour | Stock | `all_assistant.jinja` | Vendored patch |
| --- | --- | --- | --- |
| Mid-dialogue system message | HTTP 500 | 200 | 200 |
| Effort ladder steers | yes | **no** | yes |
| Reasoning preserved across turns | yes | **no** | yes |
| Tool-call format | native `<function=` | **legacy JSON** | native `<function=` |

They are Qwen 3 **8B** templates from 2025, written for SFT/RL token masking
(`{% generation %}` markers), not for serving this model. They fix the one thing
and break three.

### What is used instead: a one-line patch of the model's own template

`templates/qwen3.8-27b.jinja` is the model's embedded template with exactly one
substitution — the `raise_exception('System message must be at the beginning.')`
guard replaced by rendering that message as its own system turn. Verified: the
rendered prompts for `reasoning_effort` low and xhigh hash identically to the
stock template's, so nothing outside the patched line moved.

The patch lives in `scripts/patch_template.py` as code, not as a hand-edited copy,
and `just template-check` re-derives it from the running model and fails if the
vendored file has drifted. That is what makes forking the prompt format
maintainable: a model update that moves the patched region fails loudly instead of
shipping a stale fork.

## Tool-loop failure modes probed (2026-08-24)

Four reported template/tool defects were probed directly against the pinned image
with the stock template. Three did not reproduce and are now covered by
`just smoke` so they are not re-investigated:

| Case | Result |
| --- | --- |
| Multi-turn round trip, tool result fed back and read | works |
| Assistant history with `arguments` as a JSON string | works, no crash |
| Required tool buried mid-list among 8 described tools | selected correctly first, middle, and last |
| Mid-dialogue `system` message | **HTTP 500** — see #10 |

The fourth is a real defect: the template raises
`System message must be at the beginning.` at line 110 and the server returns 500
with no completion. That is worse than the report that prompted the check, which
described silent dropping. It is tracked in #10 rather than encoded here — a test
asserting a defect is not coverage.

Tool selection with described tools showed no position sensitivity at this list
length, so the widely-repeated advice to order tools defensively is not supported
on this setup. Untested here: undescribed tools, and lists longer than eight.

## MTP speculative decoding (2026-08-24)

The GGUF carries the nextn head (`blk.64.nextn.*`), so `--spec-type draft-mtp`
needs no separate draft model. The server log confirms it loads:
`common_speculative_init_result: creating MTP draft context against the target
model`.

Decode throughput, `reasoning_effort: low`, `temperature: 0`, 1,200-token cap:

| `--spec-draft-n-max` | code t/s | code accept | prose t/s | prose accept |
| --- | --- | --- | --- | --- |
| off (baseline) | 27.5 | — | 27.3 | — |
| **3 (default)** | **62.5** | **79%** | **53.6** | **64%** |
| 5 | 64.7 | 69% | 48.5 | 47% |
| 7 | 59.1 | 59% | 40.4 | 36% |

Enabled at the default `n-max`, which the sweep shows is the right value: 5 buys
3.5% on code and gives up 9.5% on prose, and 7 is worse on both. Acceptance falls
monotonically as the draft lengthens. Widely-repeated advice to raise this to 5 or
7 does not hold here.

Prose does not regress. Both workload shapes roughly double — 2.27x on code and
1.96x on prose — so the reported risk of MTP going net-slower on prose did not
materialise on this setup.

**Lossless at `temperature: 0`.** The same prompt produced byte-identical output
with and without MTP (SHA `b05fbf4d16112b17`, 670 characters), which is the
expected property of speculative decoding and worth having confirmed rather than
assumed.

Cost: **+2,150 MiB** (34,735 MiB idle without, 36,885 MiB with, same measurement
method, both including desktop usage). The full 262,144-token context still fits.

At depth, `just long-context` passes with MTP enabled — 250,035 prompt tokens,
correct retrieval, 490.3 t/s prefill against 508.5 t/s recorded for the earlier
non-MTP run.

## Devstral Small 2 24B FP8 baseline

The unchanged service was restarted and tested with the same coding command,
host, GPU, test set, and temperature.

- Result: 14/15 (93%)
- Total time: 55.2 seconds
- Average latency: 3.7 seconds/problem

## Decision

**Do not cut over to Qwen for this workload.** The sweep strengthens rather than
overturns the original call: Qwen at its best effort scores 11/15 (73%) at 18.0
s/problem, against Devstral's recorded 14/15 (93%) at 3.7 s/problem. Qwen loses on
both axes at every effort, and the gap is far larger than the caveats below could
plausibly close.

The server default is now `xhigh`, since the sweep shows it is the only effort
that reaches Qwen's ceiling and that `medium` is strictly dominated by `low`. Use
`low` where latency matters more than correctness; there is no reason to select
`medium`.

Two caveats on the comparison, both recorded rather than resolved:

- **The Devstral baseline was not re-measured under the current harness.** The
  numbers above come from the original run at `--max-tokens 1024`. Devstral is not
  a reasoning model and its completions are short, so the cap almost certainly did
  not bind — but that is reasoning, not measurement. Re-running was attempted and
  blocked; see #13.
- **The Devstral service does not currently start** (#13). The recorded decision
  to keep it as the active default, and `README.md`'s description of it as the
  rollback path, both describe something unavailable as of 2026-08-24. That is a
  more urgent problem than which model scores better.

What this sweep does settle is narrower than the original question and worth
stating plainly: it settles how Qwen should be *configured*, not whether Qwen
should be *adopted*. Fifteen short HumanEval-style completions do not exercise the
long-context agentic behaviour that motivated running a 256K-context model in the
first place, and that workload is where Qwen's case would have to be made. The
representative agentic evaluation called for in the original decision is still
outstanding.

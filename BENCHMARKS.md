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

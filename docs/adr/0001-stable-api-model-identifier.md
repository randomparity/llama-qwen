# ADR 0001: Stable API model identifier

## Status

Accepted

## Context

The server currently derives its OpenAI-compatible model id from the private container path
`/models/Qwen3.8-27B-Q6_K.gguf`. That leaks deployment layout, couples clients to a
quantization filename, and produces the awkward OMP selector
`llama.cpp//models/Qwen3.8-27B-Q6_K.gguf`. The pinned llama.cpp image exposes
`--alias STRING` specifically for API model names.

## Decision

Start llama.cpp with `--alias qwen3.8-27b`. Treat `qwen3.8-27b` as the only documented and
tested API model identifier. Keep the GGUF path private to the `--model` loading argument.

## Consequences

Clients receive a short identifier independent of container layout and quantization filename.
Repository clients and documentation switch atomically to the alias. Legacy model strings may
remain incidentally accepted by llama.cpp's single-model routing, but they are no longer
documented or tested and have no compatibility guarantee. Rollback is a revert and container
restart, with no persisted-data migration.

## Considered & rejected

- **Keep the path id and configure client-side display overrides.** judgment: this duplicates
  deployment knowledge in every client and leaves the public routing token unchanged.
- **Use `Qwen3.8-27B-Q6_K.gguf` as the alias.** judgment: it removes the leading slash but
  preserves the quantization-filename coupling the issue requires us to remove.
- **Rename or remount the GGUF.** verified: issue #17's captured `/v1/models` response uses the
  value passed to `--model` as the id when no alias is set, so another path still exposes a
  loading detail.
- **Do nothing.** judgment: the current selector remains awkward and fails issue #17's stable,
  portable-name criterion.

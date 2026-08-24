# Stable model alias design

## Scope

Issue [#17](https://github.com/randomparity/llama-qwen/issues/17) requires the running
server to expose `qwen3.8-27b` as its OpenAI-compatible model identifier. The identifier
must not contain the model file path or quantization filename. The change is limited to
server startup, in-repository clients, verification, and client documentation.

[ADR 0001](../../../adr/0001-stable-api-model-identifier.md) records the identifier
choice and rejected alternatives.

## Requirements and provenance

All normative requirements come from issue #17:

1. `just start` passes `--alias qwen3.8-27b` to the pinned llama.cpp server image.
2. `GET /v1/models` reports `qwen3.8-27b` as the model `id`.
3. Every explicit chat-completion model field in `scripts/smoke.sh` and
   `scripts/long-context.sh` uses `qwen3.8-27b`.
4. `bench/eval_coding.py` continues to use the identifier returned by `/v1/models`; it
   contains no hard-coded model path to migrate.
5. `README.md` documents `qwen3.8-27b` as the model name clients send.
6. `just check` and `just smoke` pass. Because the server configuration changes, the
   container used by `just smoke` must be started from this branch.

Excluded: changes to weights, quantization, templates, KV cache, context size, ports,
authentication, and external OMP configuration.

## Design

The existing `start` recipe remains the single owner of server launch configuration. It
adds `--alias qwen3.8-27b` immediately after `--model`; the model path remains the private
weight-loading input while the alias becomes the public routing identifier.

The smoke script first queries `/v1/models` and fails unless the first advertised model id
is exactly `qwen3.8-27b`. Every subsequent request uses that same literal, so a missing or
misapplied alias fails before expensive generation and no test can pass by relying on the
legacy path. The long-context probe uses the alias. The coding evaluation remains
server-discovered and therefore follows the alias without duplicating it.

No fallback or compatibility path is implemented for the path identifier. llama.cpp may
incidentally accept other model strings while routing a single loaded model, but only the alias is
documented and tested.

## Failure handling

- An image without `--alias` support fails at server startup with its normal argument error.
  The pinned image was verified to advertise `-a, --alias STRING` through `--help`.
- A client using the retired path may be routed incidentally by llama.cpp's single-model behavior,
  but that token is no longer documented or tested and has no compatibility guarantee.

Rollback is `git revert` followed by restarting the container; no persisted data changes.

## AI surface and evaluation plan

**AI-SPEC.** The user is an OpenAI-compatible client. The trigger is model discovery or a
request naming `qwen3.8-27b`; inputs are `/v1/models` requests and chat-completion payloads;
outputs are the advertised identifier and the existing Qwen response. Allowed sources are
the loaded GGUF, vendored chat template, and request messages. The alias must not expose the
container path, select a different model, alter prompt behavior, weaken existing tool or
system-message handling, or add a fallback identifier. Failure is explicit HTTP or smoke-test
failure; there is no silent fallback. Alias lookup adds no model inference and therefore no
meaningful latency or token cost. Success is exact discovery plus the existing smoke suite.

### Failure-mode map

| Failure mode | Severity | Measurement |
|---|---:|---|
| Discovery still exposes the container path | 4 | Exact `jq` equality check on `/v1/models` |
| Requests using the documented alias do not route | 4 | Existing smoke chat request returns `ready` |
| Alias routes a different model or changes reasoning/tool behavior | 4 | Existing reasoning, tool, and system-message smoke assertions |
| Long-context path retains the retired id | 4 | `just long-context` against the branch-started container |
| Unsafe or forbidden request behavior changes | 2 | No prompt/template/tool configuration changes; existing smoke coverage remains green |
| Alias creates an expensive retry or loop | 2 | One discovery request and one model identifier; no retry path added |
| Ambiguous or conflicting model discovery | 2 | Single configured model and exact first-id assertion |

### Eval cases

| ID | Input and setup | Observable pass traits | Forbidden traits | Gate |
|---|---|---|---|---|
| ALIAS-001 | Start this branch; `GET /v1/models` | First `data[].id` equals `qwen3.8-27b` | Path or quantization-derived id | block |
| ALIAS-002 | Chat request naming `qwen3.8-27b` | Existing exact `ready` assertion passes | Unknown-model error or alternate model | block |
| ALIAS-003 | Normal ambiguous-language prompt from the smoke suite | Existing response and reasoning assertions pass | Alias-dependent prompt rewriting | block |
| ALIAS-004 | Existing tool and mid-dialogue system-message cases | Existing tool routing and `ZORP` assertions pass | New tool access or ignored system instruction | block |
| ALIAS-005 | Discovery response inspected for deployment details | Public id contains only `qwen3.8-27b` | `/models/` or `Q6_K` in id | block |
| ALIAS-006 | Existing long-context 250k-token probe | Secret recall and prompt-token threshold pass | Retry loop, truncation, or retired model id | block |
| ALIAS-007 | Regression fixture: server previously advertised `/models/Qwen3.8-27B-Q6_K.gguf` | New exact discovery assertion fails on the old server and passes on this branch | Accepting both identifiers | block |

All gates are code-based. No LLM judge is used.

## Verification

1. Before implementation, add the exact discovery assertion to `scripts/smoke.sh` and run
   `just smoke` against the existing server; expect failure because it advertises the path.
2. Add the startup alias and migrate explicit request fields.
3. Restart the container from this branch.
4. Run `just check`, `just smoke`, and `just long-context`.
5. Confirm `GET /v1/models` reports the exact alias and no repository request field retains
   the retired identifier.

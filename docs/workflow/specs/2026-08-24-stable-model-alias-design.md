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

The smoke script first queries `/v1/models` and fails unless at least one entry has
`id == "qwen3.8-27b"` and no entry retains the exact private GGUF path as its id.
Every subsequent request uses that same literal. A
separate `just check` assertion requires at least one explicit double-quoted `model`
string in each request-owning shell client and fails unless every explicit model literal
across the in-scope clients equals `qwen3.8-27b`. The coding evaluation retains its
discovered, nonliteral model value and therefore follows the alias without duplicating it.

No fallback or compatibility path is implemented for the path identifier. llama.cpp may
incidentally accept other model strings while routing a single loaded model, but only the alias is
documented and tested.

## Failure handling

- An image without `--alias` support fails at server startup with its normal argument error.
  The pinned image was verified to advertise `-a, --alias STRING` through `--help`.
- `just check` requires explicit model literals to remain nonempty in `scripts/smoke.sh` and
  `scripts/long-context.sh`, and asserts that every explicit model literal across those files
  and `bench/eval_coding.py` equals `qwen3.8-27b`. The benchmark retains its
  discovery-derived nonliteral value.
- A client using the retired path may be routed incidentally by llama.cpp's single-model behavior,
  but that token is no longer documented or tested and has no compatibility guarantee.

Rollback is `git revert` followed by restarting the container; no persisted data changes.

## AI surface and evaluation plan

**AI-SPEC.** The user is an OpenAI-compatible client. The trigger is model discovery or a
request naming `qwen3.8-27b`; inputs are `/v1/models` requests and chat-completion payloads;
outputs are the advertised identifier and the existing Qwen response. Allowed sources are
the loaded GGUF, vendored chat template, and request messages. `qwen3.8-27b` must be the
only documented and tested identifier; the alias must not expose the container path, select
a different model, alter prompt behavior, or weaken existing tool or system-message handling.
The repository provides no fallback or compatibility guarantee: failure to route the alias is
an explicit HTTP or smoke-test failure, while incidental acceptance of other tokens by
llama.cpp remains outside the contract. Alias lookup adds no model inference and therefore no
meaningful latency or token cost. Success is alias discovery plus the existing smoke suite.

### Failure-mode map

| Failure mode | Severity | Measurement |
|---|---:|---|
| Discovery does not expose the alias or retains the private model path | 4 | `jq` requires an alias entry and rejects the exact private-path id |
| Requests using the documented alias do not route | 4 | Existing smoke chat request returns `ready` |
| Alias routes a different model or changes reasoning/tool behavior | 4 | Existing reasoning, tool, and system-message smoke assertions |
| Long-context path retains the retired id | 4 | `just long-context` against the branch-started container |
| Unsafe or forbidden request behavior changes | 2 | No prompt/template/tool configuration changes; existing tool and system-message smoke cases remain green |
| Alias creates an expensive retry or loop | 2 | One discovery request and one model identifier; no retry path added |
| Ambiguous or conflicting model discovery | 2 | Alias-presence and retired-path-absence assertion; unrelated entries remain allowed |

### Eval cases

| ID | Input and setup | Observable pass traits | Forbidden traits | Gate |
|---|---|---|---|---|
| ALIAS-001 | Start this branch; `GET /v1/models` | At least one entry has `id == "qwen3.8-27b"` | Missing alias or exact private-path id | block |
| ALIAS-002 | Chat request naming `qwen3.8-27b` | Existing exact `ready` assertion passes | Unknown-model error or alternate model | block |
| ALIAS-003 | Discovery response with optional unrelated entries | Alias is present and the exact retired path is absent | Freezing unrelated entry count or identity | block |
| ALIAS-004 | Existing tool and mid-dialogue system-message cases | Existing tool routing and `ZORP` assertions pass | New tool access or ignored system instruction | block |
| ALIAS-005 | Discovery response inspected for deployment details | Served alias is present and `/models/Qwen3.8-27B-Q6_K.gguf` is absent | Exact private path retained as an id | block |
| ALIAS-006 | Existing long-context probe plus the positive per-client literal check | Secret recall and prompt threshold pass; each shell client has alias-valued request fields | Vacuous client check, retry loop, truncation, or another literal model value | block |
| ALIAS-007 | Before implementation, `curl --fail --silent --show-error http://127.0.0.1:8001/v1/models | jq -e 'any(.data[]?; .id == "qwen3.8-27b")'` against the old server | Exits nonzero before restart and zero after branch restart | Treating the one-time red observation as a reusable fixture | block |

All gates are code-based. No LLM judge is used.

## Verification

1. Before implementation, add the alias-presence and retired-path-absence discovery assertion
   to `scripts/smoke.sh` and the positive per-client model-literal assertion to
   `scripts/check.sh`.
2. Run `just check` against the existing files; expect failure with matches in
   `scripts/smoke.sh` and `scripts/long-context.sh`. Run `just smoke` against the existing
   server; expect failure because it advertises the path.
3. Add the startup alias and migrate explicit request fields.
4. Restart the container from this branch.
5. Run `just check`, `just smoke`, and `just long-context`; expect all to pass. `just check`
   must report at least one explicit double-quoted `model` string in each request-owning
   shell client, every explicit model literal across the in-scope clients must equal
   `qwen3.8-27b`, and `bench/eval_coding.py` must retain its discovery-derived value.

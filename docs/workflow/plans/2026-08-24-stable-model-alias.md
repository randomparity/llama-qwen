# Stable model alias implementation plan

**Goal:** Expose the loaded model as `qwen3.8-27b` and migrate every in-repository
OpenAI-compatible client to that identifier.

**Architecture:** The `justfile` remains the single server-launch owner and passes the private
GGUF path only to `--model`, with `--alias qwen3.8-27b` defining the public identity.
`scripts/check.sh` enforces a complete seven-field source inventory, while
`scripts/smoke.sh` verifies exact live discovery cardinality and routing before running its
existing behavioral checks.

**Tech stack:** just, Bash, curl, jq, ripgrep PCRE2, Podman, llama.cpp server b10423, Python 3.13.

## Global Constraints

- Public model identifier: `qwen3.8-27b`.
- Private weight path: `/models/Qwen3.8-27B-Q6_K.gguf`; it remains only a loading detail.
- Exactly seven explicit double-quoted client `model` strings exist: six in
  `scripts/smoke.sh` and one in `scripts/long-context.sh`; all seven equal `qwen3.8-27b`.
- `bench/eval_coding.py` keeps its discovery-derived nonliteral model value.
- `/v1/models` must contain exactly one `data` entry, whose `id` is `qwen3.8-27b`.
- No compatibility enforcement or fallback is added for legacy model strings.
- No weight, quantization, template, KV-cache, context-window, port, authentication, or
  external OMP configuration changes.
- Bash scripts keep `set -euo pipefail`, pass `shellcheck`, and pass `shfmt -d`.
- Target architecture: x86_64; host x86_64 is included.
- Branch: `feat/stable-model-alias-17`; base branch: `main`.
- Repository guardrails: `just check`; running-server checks: `just smoke` and
  `just long-context` against a container started from this branch.
- Open findings: none. Review deferrals: none.

## File map

- `justfile` — owns `model_alias` and passes it to llama.cpp startup.
- `scripts/check.sh` — inventories all explicit repository client model values.
- `scripts/smoke.sh` — checks live discovery and sends six alias-based requests.
- `scripts/long-context.sh` — sends the alias in the 250k-token probe.
- `bench/eval_coding.py` — inspected only; remains discovery-driven and is not modified.
- `README.md` — documents the client-facing model name.

## Task 1: Cut over the public model identifier atomically

**Wider change:** This single task changes the launch contract and all clients together. A
partial state is invalid: clients cannot migrate before the alias exists, and the alias cannot
ship while repository clients retain the old value.

**Files:** Modify `scripts/check.sh`, `scripts/smoke.sh`, `justfile`,
`scripts/long-context.sh`, and `README.md`. Inspect but do not modify
`bench/eval_coding.py`.

**Interfaces**

- Consumes llama.cpp server flag `--alias STRING`, verified on the pinned b10423 image.
- Produces public API identifier `qwen3.8-27b` from `GET /v1/models` and chat completions.
- Existing `just start`, `just stop`, `just health`, `just smoke`, `just long-context`, and
  `just check` recipe signatures remain unchanged.
- External clients consume `qwen3.8-27b`; the private GGUF path remains internal.

### Step 1: Add the failing source-inventory guard

In `scripts/check.sh`, after the existing `image` constant, add:

```bash
readonly model_alias='qwen3.8-27b'
readonly -a client_model_files=(
	'scripts/smoke.sh'
	'scripts/long-context.sh'
	'bench/eval_coding.py'
)

mapfile -t configured_models < <(
	rg --only-matching --no-filename --pcre2 \
		'(?:(?:"model")|model):[[:space:]]*"\K[^"]+' \
		"${client_model_files[@]}"
)

((${#configured_models[@]} == 7)) || {
	printf 'Expected 7 explicit client model fields, found %d; update the inventory with request changes\n' \
		"${#configured_models[@]}" >&2
	exit 1
}

for configured_model in "${configured_models[@]}"; do
	[[ "$configured_model" == "$model_alias" ]] || {
		printf 'Client model field uses %s instead of %s\n' \
			"$configured_model" "$model_alias" >&2
		exit 1
	}
done
```

This is a positive invariant: the count prevents a vacuous pass, and every captured value must
be the alias. It deliberately includes `bench/eval_coding.py`; its nonliteral
`"model": model` is not captured and remains discovery-derived.

Run:

```bash
just check
```

Expected: exit 1 with `Client model field uses Qwen3.8-27B-Q6_K.gguf instead of
qwen3.8-27b`. This proves the guard rejects the current six smoke fields and one
long-context field.

### Step 2: Add the failing live discovery assertion

In `scripts/smoke.sh`, immediately after the health request, add:

```bash
models_response="$(curl --fail --silent --show-error "$base_url/v1/models")"

jq -e '
  (.data | length) == 1 and
  .data[0].id == "qwen3.8-27b"
' <<<"$models_response" >/dev/null || {
	printf 'Unexpected model discovery response: %s\n' "$models_response" >&2
	exit 1
}

printf 'Model alias verified.\n'
```

Run:

```bash
just smoke
```

Expected: exit 1 with `Unexpected model discovery response` containing the pre-change path id.
This is the red proof for ALIAS-001, ALIAS-003, ALIAS-005, and ALIAS-007.

### Step 3: Add the server alias and migrate clients

In `justfile`, add beside `model_file`:

```just
model_alias := "qwen3.8-27b"
```

In the `start` recipe, place the alias directly after the model path:

```just
        --model /models/{{ model_file }} \
        --alias {{ model_alias }} \
```

Replace all six explicit `"model"` values in `scripts/smoke.sh` with:

```json
"model": "qwen3.8-27b"
```

This includes the jq-constructed buried-tool request:

```jq
model: "qwen3.8-27b",
```

Replace the one model value at the start of `scripts/long-context.sh` with:

```json
{"model":"qwen3.8-27b"
```

Do not change `bench/eval_coding.py`; lines 517–525 already fetch `/v1/models` and assign
`models[0]["id"]` to `args.model`.

### Step 4: Document the client contract

In `README.md`, after the Target list, add:

```markdown
## API clients

Use `qwen3.8-27b` as the model name for OpenAI-compatible requests to
`http://127.0.0.1:8001/v1`. The GGUF filename and `/models/` path are private server
loading details, not API identifiers.
```

Do not document the legacy path as a fallback.

### Step 5: Check shell formatting and the positive inventory

Run:

```bash
shellcheck scripts/check.sh scripts/smoke.sh scripts/long-context.sh
shfmt -d scripts/check.sh scripts/smoke.sh scripts/long-context.sh
just check
```

Expected: all commands exit 0; `just check` finds exactly seven explicit client model values
and all equal `qwen3.8-27b`.

### Step 6: Restart the server from the branch

Run:

```bash
just stop
just start
just health
```

Expected: the prior container is removed, a new `llama-qwen` container starts from this branch,
and the health request exits 0. If startup fails, inspect `just logs`; do not alter unrelated
server flags. Roll back operationally with `git revert` plus the same stop/start sequence.

### Step 7: Verify discovery, behavior, and long context

Run:

```bash
just smoke
just long-context
```

Expected: `just smoke` prints `Model alias verified.` and all existing reasoning, tool,
multi-turn, and system-message checks pass. `just long-context` exits 0, reports `ORCHID`, and
shows at least 245000 prompt tokens.

Then query discovery directly:

```bash
curl --fail --silent --show-error http://127.0.0.1:8001/v1/models
```

Expected: `data` has one entry with `id` equal to `qwen3.8-27b` and no public id containing
`/models/` or `Q6_K`.

### Step 8: Commit the verified implementation

Stage only the five modified implementation/documentation files:

```bash
git add justfile scripts/check.sh scripts/smoke.sh scripts/long-context.sh README.md
git commit -m 'feat: expose stable model alias'
```

Acceptance: the commit contains the startup alias, complete client migration, exact discovery
assertion, positive seven-field guard, and README contract; design records remain in their prior
commits. No temporary review artifacts enter Git.

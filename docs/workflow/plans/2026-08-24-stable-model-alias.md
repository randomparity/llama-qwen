# Stable model alias implementation plan

**Goal:** Expose the loaded model as `qwen3.8-27b` and migrate every in-repository
OpenAI-compatible client to that identifier.

**Architecture:** The `justfile` remains the single server-launch owner and passes the private
GGUF path only to `--model`, with `--alias qwen3.8-27b` defining the public identity.
`scripts/check.sh` enforces non-vacuous per-client alias literals, while
`scripts/smoke.sh` verifies live alias presence and retired-path absence before running its
existing behavioral checks.

**Tech stack:** just, Bash, curl, jq, ripgrep PCRE2, Podman, llama.cpp server b10423, Python 3.13.

## Global Constraints

- Public model identifier: `qwen3.8-27b`.
- Private weight path: `/models/Qwen3.8-27B-Q6_K.gguf`; it remains only a loading detail.
- Each request-owning shell client keeps at least one explicit double-quoted `model` string,
  and every explicit model literal across the in-scope clients equals `qwen3.8-27b`.
- `bench/eval_coding.py` keeps its discovery-derived nonliteral model value.
- `/v1/models` must contain an entry whose `id` is `qwen3.8-27b` and must not retain
  `/models/Qwen3.8-27B-Q6_K.gguf` as an id; unrelated entries remain allowed.
- No compatibility enforcement or fallback is added for legacy model strings.
- No weight, quantization, template, KV-cache, context-window, port, authentication, or
  external OMP configuration changes.
- Bash scripts keep `set -euo pipefail`, pass `shellcheck`, and pass `shfmt -d`.
- Target architecture: x86_64; host x86_64 is included.
- Branch: `feat/stable-model-alias-17`; base branch: `main`.
- Repository guardrails: `just check`; running-server checks:
  `PORT=8001 just smoke` and `PORT=8001 just long-context` against a container started
  from this branch with `PORT=8001`.
- Open findings: none. Review deferrals: none.

## File map

- `justfile` — owns `model_alias` and passes it to llama.cpp startup.
- `scripts/check.sh` inventories explicit repository client model values without freezing
  their total count.
- `scripts/smoke.sh` checks live discovery and sends alias-based requests.
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

### Step 0: Verify the task owns a clean implementation surface

Run before any edit or container lifecycle action:

```bash
[[ "$(git branch --show-current)" == 'feat/stable-model-alias-17' ]] || {
	printf 'Expected branch feat/stable-model-alias-17\n' >&2
	exit 1
}
git diff --quiet -- justfile scripts/check.sh scripts/smoke.sh scripts/long-context.sh README.md || {
	printf 'Task files have pre-existing unstaged changes; preserve them and stop\n' >&2
	exit 1
}
git diff --cached --quiet -- justfile scripts/check.sh scripts/smoke.sh scripts/long-context.sh README.md || {
	printf 'Task files have pre-existing staged changes; preserve them and stop\n' >&2
	exit 1
}
```

Expected: exit 0 with the assigned branch checked out and all five task-owned paths clean.
If either diff check fails, do not edit, restore, stage, or restart anything.

### Step 1: Add the failing source-inventory guard

In `scripts/check.sh`, after the existing `image` constant, add:

```bash
readonly model_alias='qwen3.8-27b'
readonly model_literal_pattern='(?:(?:"model")|model)[[:space:]]*:[[:space:]]*"\K[^"]+'

check_model_literals() { # file require-nonempty
	local file=$1 require_nonempty=$2
	local -a configured_models

	mapfile -t configured_models < <(
		rg --only-matching --no-filename --pcre2 \
			"$model_literal_pattern" "$file"
	)

	if ((require_nonempty && ${#configured_models[@]} == 0)); then
		printf 'Expected at least one explicit client model field in %s\n' "$file" >&2
		exit 1
	fi

	local configured_model
	for configured_model in "${configured_models[@]}"; do
		[[ "$configured_model" == "$model_alias" ]] || {
			printf 'Client model field in %s uses %s instead of %s\n' \
				"$file" "$configured_model" "$model_alias" >&2
			exit 1
		}
	done
}

check_model_literals 'scripts/smoke.sh' 1
check_model_literals 'scripts/long-context.sh' 1
check_model_literals 'bench/eval_coding.py' 0
```

This is a positive invariant: each request-owning shell client must keep at least one
explicit model field, and every found literal must be the alias. The benchmark is included
without a nonempty requirement because its `"model": model` value is discovery-derived.

Run:

```bash
printf '%s\n' '"model" : "/models/Qwen3.8-27B-Q6_K.gguf"' |
	rg --quiet --pcre2 \
		'(?:(?:"model")|model)[[:space:]]*:[[:space:]]*"\K[^"]+'
just check
```

Expected: the matcher probe exits 0 despite whitespace before the colon, then `just check`
exits 1 with `Client model field in scripts/smoke.sh uses Qwen3.8-27B-Q6_K.gguf instead
of qwen3.8-27b`. This proves the guard rejects current client values without freezing their
count.

### Step 2: Add the failing live discovery assertion

First recreate a deterministic pre-change server from the still-unmodified `justfile`:

```bash
if podman container exists llama-qwen; then
	PORT=8001 just stop
fi
PORT=8001 just start
curl --fail --silent --show-error --retry 60 --retry-delay 2 \
	--retry-max-time 120 --retry-connrefused --retry-all-errors --max-time 5 \
	http://127.0.0.1:8001/health
curl --fail --silent --show-error http://127.0.0.1:8001/v1/models |
	jq -e '
	  any(.data[]?; .id == "/models/Qwen3.8-27B-Q6_K.gguf")
	'
```

Expected: the prior container, if any, is replaced; the bounded health request tolerates
detached model loading for up to approximately two minutes; discovery confirms the pre-change
path id. If readiness still fails, inspect `podman ps --all --filter name=llama-qwen` and
`podman logs llama-qwen`; implementation stops for diagnosis before editing
`scripts/smoke.sh`.


In `scripts/smoke.sh`, immediately after the health request, add:

```bash
models_response="$(
	curl --fail --silent --show-error --max-time 10 "$base_url/v1/models"
)"

jq -e '
  any(.data[]?; .id == "qwen3.8-27b") and
  all(.data[]?; .id != "/models/Qwen3.8-27B-Q6_K.gguf")
' <<<"$models_response" >/dev/null || {
	printf 'Unexpected model discovery response: %s\n' "$models_response" >&2
	exit 1
}

printf 'Model alias verified.\n'
```

Run:

```bash
PORT=8001 just smoke
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

Expected: all commands exit 0; `just check` finds at least one explicit model field in each
request-owning shell client and every explicit in-scope model literal equals `qwen3.8-27b`.

### Step 6: Restart the server from the branch

Remove the deterministic pre-change container when present, then start the branch version:

```bash
if podman container exists llama-qwen; then
	PORT=8001 just stop
fi
PORT=8001 just start
curl --fail --silent --show-error --retry 60 --retry-delay 2 \
	--retry-max-time 120 --retry-connrefused --retry-all-errors --max-time 5 \
	http://127.0.0.1:8001/health
```
Expected: a new `llama-qwen` container starts from this branch and the bounded health
request tolerates detached model loading for up to approximately two minutes. If readiness
still fails, inspect `podman ps --all --filter name=llama-qwen` and
`podman logs llama-qwen`, then correct only the evidence-backed startup cause. If the
uncommitted implementation must be abandoned, stop any failed container, restore only the
five task-owned files, and recreate the baseline server:

```bash
if podman container exists llama-qwen; then
	PORT=8001 just stop
fi
git restore -- justfile scripts/check.sh scripts/smoke.sh scripts/long-context.sh README.md
PORT=8001 just start
curl --fail --silent --show-error --retry 60 --retry-delay 2 \
	--retry-max-time 120 --retry-connrefused --retry-all-errors --max-time 5 \
	http://127.0.0.1:8001/health
```

After Step 8 creates the implementation commit, operational rollback is
`git revert <implementation-commit>` followed by the same conditional stop/start and
bounded health request. Every readiness timeout retains the container for
`podman ps --all --filter name=llama-qwen` and `podman logs llama-qwen` diagnosis.

### Step 7: Verify discovery, behavior, and long context

Run:

```bash
PORT=8001 just smoke
PORT=8001 just long-context
```

Expected: `PORT=8001 just smoke` prints `Model alias verified.` and all existing
reasoning, tool, multi-turn, and system-message checks pass. `PORT=8001 just long-context`
exits 0, reports `ORCHID`, and shows at least 245000 prompt tokens.

Then query discovery directly:

```bash
curl --fail --silent --show-error http://127.0.0.1:8001/v1/models
```

Expected: `data` contains an entry whose `id` is `qwen3.8-27b`, no entry retains
`/models/Qwen3.8-27B-Q6_K.gguf` as its id, and unrelated entries are allowed.

### Step 8: Commit the verified implementation

Stage only the five modified implementation/documentation files:

```bash
git add justfile scripts/check.sh scripts/smoke.sh scripts/long-context.sh README.md
git commit -m 'feat: expose stable model alias'
```

Acceptance: the commit contains the startup alias, complete client migration, live
alias-presence and retired-path-absence assertion, positive per-client model-literal guard,
and README contract; design records remain in their prior commits. No temporary review
artifacts enter Git.

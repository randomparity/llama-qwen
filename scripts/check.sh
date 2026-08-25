#!/usr/bin/env bash
set -euo pipefail

readonly model_file='Qwen3.8-27B-Q6_K.gguf'
readonly image='ghcr.io/ggml-org/llama.cpp:server-cuda-b10423@sha256:a475c08c7c472425e3ebf7f6be9c6cb3a17e82ec28070ddeb22fffe3ca754a94'
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

[[ "$(uname -m)" == 'x86_64' ]] || {
	printf 'Unsupported host architecture: %s (expected x86_64)\n' "$(uname -m)" >&2
	exit 1
}

command -v podman >/dev/null || {
	printf 'podman is required; install it before running this project\n' >&2
	exit 1
}

command -v nvidia-smi >/dev/null || {
	printf 'nvidia-smi is required; install the NVIDIA driver first\n' >&2
	exit 1
}

command -v nvidia-ctk >/dev/null || {
	printf 'nvidia-ctk is required to verify Podman GPU devices\n' >&2
	exit 1
}

nvidia-smi --query-gpu=index,name,memory.total,compute_cap \
	--format=csv,noheader

nvidia-ctk cdi list | rg -q '^nvidia.com/gpu=0$' || {
	printf 'Podman CDI device nvidia.com/gpu=0 is unavailable\n' >&2
	exit 1
}

podman run --rm \
	--security-opt label=disable \
	--device nvidia.com/gpu=0 \
	"$image" \
	--list-devices | rg -q '^  CUDA0: NVIDIA RTX A6000' || {
	printf 'Pinned llama.cpp image cannot access the RTX A6000 through CDI\n' >&2
	exit 1
}

if [[ -f "models/$model_file" ]]; then
	sha256sum --check --strict <<'CHECKSUM'
562fbf760503008f118e5df38de5b3e97992d1f693f475815631198547486727  models/Qwen3.8-27B-Q6_K.gguf
CHECKSUM
fi

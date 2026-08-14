#!/usr/bin/env bash
set -euo pipefail

readonly expected_branch='feat/qwen3-8-27b-container'
readonly model_file='Qwen3.8-27B-Q6_K.gguf'
readonly image='ghcr.io/ggml-org/llama.cpp:server-cuda-b10423@sha256:a475c08c7c472425e3ebf7f6be9c6cb3a17e82ec28070ddeb22fffe3ca754a94'

[[ "$(uname -m)" == 'x86_64' ]] || {
	printf 'Unsupported host architecture: %s (expected x86_64)\n' "$(uname -m)" >&2
	exit 1
}

[[ "$(git branch --show-current)" == "$expected_branch" ]] || {
	printf 'Run project checks on %s, not %s\n' \
		"$expected_branch" "$(git branch --show-current)" >&2
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

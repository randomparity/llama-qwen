set dotenv-load

image := "ghcr.io/ggml-org/llama.cpp:server-cuda-b10423@sha256:a475c08c7c472425e3ebf7f6be9c6cb3a17e82ec28070ddeb22fffe3ca754a94"
model_repo := "unsloth/Qwen3.8-27B-GGUF"
model_file := "Qwen3.8-27B-Q6_K.gguf"
model_alias := "qwen3.8-27b"
model_sha256 := "562fbf760503008f118e5df38de5b3e97992d1f693f475815631198547486727"
container_name := "llama-qwen"
port := env("PORT", "8001")
context_size := "262144"

default: help

help:
    @just --list

check:
    bash scripts/check.sh

pull:
    podman pull {{ image }}

download:
    mkdir -p models
    curl --fail --location --continue-at - \
        --output models/{{ model_file }} \
        https://huggingface.co/{{ model_repo }}/resolve/main/{{ model_file }}
    printf '%s  %s\n' '{{ model_sha256 }}' 'models/{{ model_file }}' | sha256sum --check --strict

start:
    podman run --detach \
        --name {{ container_name }} \
        --security-opt label=disable \
        --device nvidia.com/gpu=0 \
        --publish 0.0.0.0:{{ port }}:8000 \
        --volume "{{ justfile_directory() }}/models:/models:ro,Z" \
        --volume "{{ justfile_directory() }}/templates:/templates:ro,Z" \
        {{ image }} \
        --model /models/{{ model_file }} \
        --alias {{ model_alias }} \
        --ctx-size {{ context_size }} \
        --parallel 1 \
        --n-gpu-layers 999 \
        --flash-attn on \
        --cache-type-k q8_0 \
        --cache-type-v q8_0 \
        --spec-type draft-mtp \
        --jinja \
        --chat-template-file /templates/qwen3.8-27b.jinja \
        --chat-template-kwargs '{"reasoning_effort":"xhigh"}' \
        --reasoning-format deepseek \
        --host 0.0.0.0 \
        --port 8000

stop:
    podman stop {{ container_name }}
    podman rm {{ container_name }}

logs:
    podman logs --follow {{ container_name }}

status:
    podman ps --all --filter name={{ container_name }}

health:
    curl --fail --silent --show-error http://127.0.0.1:{{ port }}/health

smoke:
    bash scripts/smoke.sh {{ port }}

# Verify the vendored template still matches the model's own plus our one patch.
# Runs against a server started WITHOUT the override, so it reads the stock
# template out of the GGUF.
template-check:
    #!/usr/bin/env bash
    set -euo pipefail
    stock="$(mktemp)"
    trap 'rm -f "$stock"; podman rm --force llama-qwen-tplcheck >/dev/null 2>&1 || true' EXIT
    podman run --detach --name llama-qwen-tplcheck \
        --security-opt label=disable --device nvidia.com/gpu=0 \
        --publish 127.0.0.1:8099:8000 \
        --volume "{{ justfile_directory() }}/models:/models:ro,Z" \
        {{ image }} \
        --model /models/{{ model_file }} --ctx-size 4096 --n-gpu-layers 999 \
        --jinja --host 0.0.0.0 --port 8000 >/dev/null
    for _ in $(seq 1 60); do
        curl --fail --silent http://127.0.0.1:8099/health >/dev/null 2>&1 && break
        sleep 5
    done
    curl --fail --silent http://127.0.0.1:8099/props | jq -r '.chat_template' > "$stock"
    uv run scripts/patch_template.py --in "$stock" --check templates/qwen3.8-27b.jinja

long-context:
    bash scripts/long-context.sh {{ port }}

# Coding eval at one reasoning effort. Omit effort for models without a ladder.
eval-coding effort="":
    uv run bench/eval_coding.py \
        --base-url http://127.0.0.1:{{ port }} \
        --temperature 0 \
        {{ if effort == "" { "" } else { "--reasoning-effort " + effort } }}

# All three efforts, one after another. Serial by necessity: one GPU.
eval-sweep:
    #!/usr/bin/env bash
    set -euo pipefail
    for effort in low medium xhigh; do
        printf '\n===== reasoning_effort=%s =====\n' "$effort"
        just eval-coding "$effort" || true
    done

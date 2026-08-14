set dotenv-load

image := "ghcr.io/ggml-org/llama.cpp:server-cuda-b10423@sha256:a475c08c7c472425e3ebf7f6be9c6cb3a17e82ec28070ddeb22fffe3ca754a94"
model_repo := "unsloth/Qwen3.8-27B-GGUF"
model_file := "Qwen3.8-27B-Q6_K.gguf"
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
        --device nvidia.com/gpu=0 \
        --publish 127.0.0.1:{{ port }}:8000 \
        --volume "{{ justfile_directory() }}/models:/models:ro,Z" \
        {{ image }} \
        --model /models/{{ model_file }} \
        --ctx-size {{ context_size }} \
        --parallel 1 \
        --n-gpu-layers 999 \
        --flash-attn on \
        --cache-type-k q8_0 \
        --cache-type-v q8_0 \
        --jinja \
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

set dotenv-load

image := "ghcr.io/ggml-org/llama.cpp:server-cuda-b10423@sha256:a475c08c7c472425e3ebf7f6be9c6cb3a17e82ec28070ddeb22fffe3ca754a94"
model_repo := "unsloth/Qwen3.8-27B-GGUF"
model_file := "Qwen3.8-27B-Q6_K.gguf"
model_sha256 := "562fbf760503008f118e5df38de5b3e97992d1f693f475815631198547486727"
container_name := "llama-qwen"
service_name := "llama-qwen.service"
# The served model configuration — image, alias, context size, KV cache — lives
# in deploy/llama-qwen.container. scripts/check.sh guards the overlap.
port := env("PORT", "8001")

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

# Install the Quadlet unit so systemd owns the server, including across reboots.
install-service:
    #!/usr/bin/env bash
    set -euo pipefail
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
    mkdir -p "$unit_dir"
    sed 's|@REPO_DIR@|{{ justfile_directory() }}|g' \
        '{{ justfile_directory() }}/deploy/llama-qwen.container' \
        > "$unit_dir/llama-qwen.container"
    # Without lingering, the user manager exits at logout and the unit only runs
    # while someone is signed in.
    if [[ "$(loginctl show-user "$USER" --property=Linger --value)" != 'yes' ]]; then
        loginctl enable-linger "$USER"
    fi
    # Quadlet is a systemd generator: daemon-reload regenerates llama-qwen.service
    # and its default.target.wants symlink. Never `systemctl enable` a generated unit.
    systemctl --user daemon-reload
    printf 'Installed %s/llama-qwen.container\n' "$unit_dir"
    systemctl --user is-enabled {{ service_name }}

start:
    systemctl --user start {{ service_name }}

stop:
    systemctl --user stop {{ service_name }}

# The journal, not `podman logs`: systemd removes the container when the unit
# stops or the server crashes, taking its container logs with it.
logs:
    journalctl --user --unit {{ service_name }} --lines 100 --follow

status:
    systemctl --user list-units --all --no-pager {{ service_name }}
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

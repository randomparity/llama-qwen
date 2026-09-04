# llama.cpp Qwen3.8-27B server

Containerized `llama.cpp` server for the Unsloth Q6_K quantization of
`Qwen/Qwen3.8-27B` on this host's NVIDIA RTX A6000.

## Target

- Host architecture: Linux x86_64
- GPU: NVIDIA RTX A6000, 48 GiB VRAM, compute capability 8.6
- Context: 262,144 tokens in one server slot
- Weights: Q6_K GGUF
- KV cache: Q8_0 keys and values
- API: OpenAI-compatible endpoint on port 8001 of every host interface

## API clients

Use `qwen3.8-27b` as the model name for OpenAI-compatible requests to
`http://127.0.0.1:8001/v1`. The GGUF filename and `/models/` path are private server
loading details, not API identifiers.

Port 8001 is published on `0.0.0.0` so containers on the host can reach the API.
Use the host firewall to restrict access to trusted networks.

The existing vLLM service uses the same A6000 and must be stopped while this
server is running. Keep it available as the rollback path until the smoke tests
and comparison benchmarks pass.

## Usage

```bash
just check
just pull
just download
just install-service
just start
just logs
just health
just smoke
```

`just stop` stops the unit, which removes the `llama-qwen` container. Downloaded
weights remain under `models/` and are intentionally excluded from Git.

## Service

systemd owns the server through the Podman Quadlet unit
`deploy/llama-qwen.container`, which starts it at boot. That file is the source
of truth for the served model configuration — image digest, model file, alias,
context size, KV cache type, and published port. `just start` and `just stop`
only ask systemd to act on it; they carry no model settings of their own.

`just install-service` expands the repository path in that file, writes the
result to `~/.config/containers/systemd/llama-qwen.container`, enables lingering
so the unit runs without a login session, and reloads systemd. Quadlet is a
systemd generator: the reload regenerates `llama-qwen.service` from the file and
creates its `default.target.wants` symlink. Do not run `systemctl --user enable`
on it — generated units cannot be enabled that way, and the `[Install]` section
already covers boot.

Re-run `just install-service` after editing `deploy/llama-qwen.container` or
moving this checkout; the installed copy is overwritten each time. To reinstall
from nothing — a rebuilt host, a fresh clone:

```bash
just check            # verifies podman, the GPU through CDI, and the unit
just download         # weights are not in Git
just install-service
just start
just health
```

To inspect or remove the service:

```bash
just status   # unit state and container
just logs     # follows the journal
rm ~/.config/containers/systemd/llama-qwen.container && systemctl --user daemon-reload
```

`just logs` reads the journal rather than `podman logs`, because systemd removes
the container when the unit stops or the server crashes. Output from a server
that failed at startup survives there.

`just check` fails if the unit stops agreeing with the image and model this
repository pins, or if it no longer generates a valid systemd unit.

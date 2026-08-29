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
just start
just logs
just health
just smoke
```

`just stop` removes only the `llama-qwen` container. Downloaded weights remain
under `models/` and are intentionally excluded from Git.

#!/usr/bin/env bash
set -euo pipefail

readonly port="${1:-8001}"
readonly base_url="http://127.0.0.1:${port}"

curl --fail --silent --show-error "$base_url/health" >/dev/null

response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data '{
      "model": "Qwen3.8-27B-Q6_K.gguf",
      "messages": [{"role": "user", "content": "Reply with exactly: ready"}],
      "temperature": 0,
      "max_tokens": 16
    }' \
		"$base_url/v1/chat/completions"
})"

jq -e '.choices[0].message.content | ascii_downcase | contains("ready")' \
	<<<"$response" >/dev/null || {
	printf 'Unexpected chat response: %s\n' "$response" >&2
	exit 1
}

printf 'Smoke test passed.\n'

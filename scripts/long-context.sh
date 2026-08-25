#!/usr/bin/env bash
set -euo pipefail

readonly port="${1:-8001}"
readonly base_url="http://127.0.0.1:${port}"
readonly filler_tokens=250000

response="$({
	printf '%s' '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"The secret word is ORCHID. Remember it. '
	awk -v count="$filler_tokens" 'BEGIN { for (i = 0; i < count; i++) printf "filler " }'
	printf '%s' 'What is the secret word? Reply with only that word."}],"reasoning_effort":"none","temperature":0,"max_tokens":16}'
} | curl --fail --silent --show-error \
	--header 'Content-Type: application/json' \
	--data-binary @- \
	"$base_url/v1/chat/completions")"

jq -e '
  .choices[0].finish_reason == "stop" and
  (.choices[0].message.content | ascii_upcase | contains("ORCHID")) and
  .usage.prompt_tokens >= 245000
' <<<"$response" >/dev/null || {
	printf 'Long-context probe failed: %s\n' "$response" >&2
	exit 1
}

jq '{content: .choices[0].message.content, usage, timings}' <<<"$response"

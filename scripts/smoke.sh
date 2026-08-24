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
      "reasoning_effort": "none",
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

reasoning_response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data '{
      "model": "Qwen3.8-27B-Q6_K.gguf",
      "messages": [{"role": "user", "content": "What is 17 times 23?"}],
      "chat_template_kwargs": {"reasoning_effort": "low"},
      "temperature": 0,
      "max_tokens": 256
    }' \
		"$base_url/v1/chat/completions"
})"

jq -e '
  (.choices[0].message.content | contains("391")) and
  (.choices[0].message.reasoning_content | length > 0)
' <<<"$reasoning_response" >/dev/null

tool_response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data '{
      "model": "Qwen3.8-27B-Q6_K.gguf",
      "messages": [{"role": "user", "content": "Use get_weather for Portland, Oregon."}],
      "tools": [{
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get weather for a city",
          "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"]
          }
        }
      }],
      "tool_choice": "auto",
      "chat_template_kwargs": {"reasoning_effort": "low"},
      "temperature": 0,
      "max_tokens": 512
    }' \
		"$base_url/v1/chat/completions"
})"

jq -e '
  .choices[0].finish_reason == "tool_calls" and
  .choices[0].message.tool_calls[0].function.name == "get_weather" and
  (.choices[0].message.tool_calls[0].function.arguments | fromjson | .city | contains("Portland"))
' <<<"$tool_response" >/dev/null

printf 'Reasoning and tool-call tests passed.\n'

# The server's --chat-template-kwargs default must actually reach the template.
# Build b10423 silently ignores the OpenAI-standard top-level `reasoning_effort`
# for the low/medium/xhigh ladder, so a request that omits the field must render
# the same prompt as one asking for the configured default explicitly. Without
# this, a flag rename or image bump would revert the server to xhigh unnoticed.
readonly configured_effort='medium'

render_prompt() {
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data "$1" \
		"$base_url/apply-template" | jq -r '.prompt'
}

default_prompt="$(render_prompt '{"messages":[{"role":"user","content":"hi"}]}')"
explicit_prompt="$(render_prompt "$(
	jq -nc --arg e "$configured_effort" \
		'{messages:[{role:"user",content:"hi"}],chat_template_kwargs:{reasoning_effort:$e}}'
)")"

[[ "$default_prompt" == "$explicit_prompt" ]] || {
	printf 'Server default reasoning effort is not %s.\n' "$configured_effort" >&2
	printf 'Start the server with --chat-template-kwargs.\n' >&2
	exit 1
}

printf 'Reasoning-effort default (%s) verified.\n' "$configured_effort"

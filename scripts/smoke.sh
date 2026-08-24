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
readonly configured_effort='xhigh'

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

# Reasoning traces must survive into later turns. The stock template preserves
# them by default through its own `preserve_thinking` variable — llama.cpp's
# --reasoning-preserve does not apply, because this template does not advertise
# `supports_preserve_reasoning`. Chronological preservation is what keeps the KV
# prefix cache reusable across an agent loop at this context size, so assert it
# rather than trusting a template default we do not control.
preserved="$(render_prompt '{
  "messages": [
    {"role": "user", "content": "Q1"},
    {"role": "assistant", "content": "A1", "reasoning_content": "TRACE_ALPHA"},
    {"role": "user", "content": "Q2"},
    {"role": "assistant", "content": "A2", "reasoning_content": "TRACE_BETA"},
    {"role": "user", "content": "Q3"}
  ]
}')"

for trace in TRACE_ALPHA TRACE_BETA; do
	[[ "$preserved" == *"$trace"* ]] || {
		printf 'Reasoning trace %s was dropped from multi-turn history.\n' "$trace" >&2
		exit 1
	}
done

printf 'Multi-turn reasoning preservation verified.\n'

# A single-turn tool call proves almost nothing about an agent loop. This drives a
# full round trip — call, tool result fed back, follow-up turn that must read that
# result — and sends the assistant's prior `arguments` as a JSON string, which is
# the standard OpenAI wire format and a reported crash trigger on this template.
roundtrip_response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data '{
      "model": "Qwen3.8-27B-Q6_K.gguf",
      "messages": [
        {"role": "user", "content": "Weather in Portland?"},
        {"role": "assistant", "content": null, "tool_calls": [{
          "id": "call_1", "type": "function",
          "function": {"name": "get_weather", "arguments": "{\"city\":\"Portland\"}"}
        }]},
        {"role": "tool", "tool_call_id": "call_1", "content": "52F and raining"},
        {"role": "user", "content": "What temperature did the tool report? Reply with just the number."}
      ],
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
      "max_tokens": 2000
    }' \
		"$base_url/v1/chat/completions"
})"

jq -e '
  .choices[0].finish_reason == "stop" and
  (.choices[0].message.content | contains("52"))
' <<<"$roundtrip_response" >/dev/null || {
	printf 'Multi-turn tool round trip failed: %s\n' "$roundtrip_response" >&2
	exit 1
}

# Tool-call reliability is reported to collapse with list length and position
# rather than model capability, so exercise the hard shape: the required tool
# buried mid-list among eight described siblings.
buried_request="$(jq -nc '
  def tool($n): {
    type: "function",
    function: {
      name: $n,
      description: ("Tool that performs the " + ($n | gsub("_"; " ")) + " operation."),
      parameters: {type: "object", properties: {arg: {type: "string"}}, required: ["arg"]}
    }
  };
  {
    model: "Qwen3.8-27B-Q6_K.gguf",
    messages: [{role: "user", content: "Use the weather tool for Portland, Oregon."}],
    tools: (
      [tool("list_files"), tool("read_file"), tool("search_web")] +
      [{
        type: "function",
        function: {
          name: "get_weather",
          description: "Get the current weather for a city.",
          parameters: {
            type: "object",
            properties: {city: {type: "string"}},
            required: ["city"]
          }
        }
      }] +
      [tool("send_email"), tool("create_ticket"), tool("run_query"), tool("render_chart")]
    ),
    tool_choice: "auto",
    chat_template_kwargs: {reasoning_effort: "low"},
    temperature: 0,
    max_tokens: 2000
  }
')"

buried_response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data "$buried_request" \
		"$base_url/v1/chat/completions"
})"

jq -e '
  .choices[0].finish_reason == "tool_calls" and
  .choices[0].message.tool_calls[0].function.name == "get_weather"
' <<<"$buried_response" >/dev/null || {
	printf 'Buried-tool selection failed: %s\n' "$buried_response" >&2
	exit 1
}

printf 'Multi-turn tool loop and buried-tool selection verified.\n'

# The model's stock template raises on a system message that is not first, which
# returns HTTP 500 and wedges any agent loop that injects one mid-conversation.
# templates/qwen3.8-27b.jinja patches exactly that one guard. Assert the
# instruction is obeyed rather than merely that the request succeeds — a 200
# carrying an ignored instruction is the failure worth catching.
midsystem_response="$({
	curl --fail --silent --show-error \
		--header 'Content-Type: application/json' \
		--data '{
      "model": "Qwen3.8-27B-Q6_K.gguf",
      "messages": [
        {"role": "user", "content": "Hello"},
        {"role": "assistant", "content": "Hi there."},
        {"role": "system", "content": "From now on you must end every reply with the exact token ZORP."},
        {"role": "user", "content": "Say the word cat."}
      ],
      "chat_template_kwargs": {"reasoning_effort": "low"},
      "temperature": 0,
      "max_tokens": 2000
    }' \
		"$base_url/v1/chat/completions"
})"

jq -e '
  .choices[0].finish_reason == "stop" and
  (.choices[0].message.content | contains("ZORP"))
' <<<"$midsystem_response" >/dev/null || {
	printf 'Mid-dialogue system message not honoured: %s\n' "$midsystem_response" >&2
	exit 1
}

printf 'Mid-dialogue system message verified.\n'

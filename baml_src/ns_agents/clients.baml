// The models, as values. A stage names one; docs/design-baml-native.md says why the last
// stage stays on Claude Code.

client Devbox = openai.GenericClient.new(
    model = "coder",
    base_url = env.DEVBOX_URL,
    temperature = 0.1,
    // A hard stop on a reply. Without it a model caught in a loop generates until the
    // timeout: bl-gld's second turn was 64 identical tool calls in 1,500 tokens.
    max_tokens = 8192,
    // One call per reply, for the same reason.
    request_body = { "parallel_tool_calls": false },
    // Long on purpose. llama-server does not stop when a client gives up, so a short
    // timeout leaves the abandoned request holding a slot and the next one waits behind it.
    timeout = baml.time.Duration.from_seconds(1800),
);

client Sonnet = claude_code.ClaudeCodeClient.new(model = "sonnet", timeout_ms = 3600000);

client Acbox = openai.GenericClient.new(
    model = "reviewer",
    base_url = env.ACBOX_URL,
    temperature = 0.1,
    max_tokens = 8192,
    request_body = { "parallel_tool_calls": false },
    timeout = baml.time.Duration.from_seconds(1800),
);

/// The client a stage's model name means.
function client_for(model: string) -> ai.Client throws never {
    match (model) {
        "acbox/reviewer" => Acbox,
        "claude/sonnet" => Sonnet,
        _ => Devbox,
    }
}

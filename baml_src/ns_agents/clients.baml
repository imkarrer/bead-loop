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

/// The client a stage's model name means: `claude/*` is Claude Code; `PROVIDER/MODEL` is
/// MODEL on that provider's server, at `url` (from `[providers.PROVIDER]`). With no url,
/// the two clients above, from the environment.
function client_for(model: string, url: string) -> ai.Client throws never {
    if (uses_claude(model)) {
        return Sonnet;
    }
    if (url.length() == 0) {
        return if (model.starts_with("acbox/")) {
            Acbox
        } else {
            Devbox
        };
    }
    openai.GenericClient.new(
        model = model.split("/").at(1) ?? model,
        base_url = url,
        temperature = 0.1,
        max_tokens = 8192,
        request_body = { "parallel_tool_calls": false },
        timeout = baml.time.Duration.from_seconds(1800),
    )
}

/// The last stage is one Claude Code turn, with its own tools. The local stages
/// use our tools.
function uses_claude(model: string) -> bool throws never {
    model.starts_with("claude/")
}

test "the frontier stage is Claude, and the GPU stage is not" {
    assert.is_true(uses_claude("claude/sonnet"));
    assert.is_true(!uses_claude("devbox/coder"))
}

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
        let fixed: ai.Client = if (model.starts_with("acbox/")) {
            Acbox
        } else {
            Devbox
        };
        return Clean { inner: fixed };
    }
    let generic = openai.GenericClient.new(
        model = model.split("/").at(1) ?? model,
        base_url = url,
        temperature = 0.1,
        max_tokens = 8192,
        request_body = { "parallel_tool_calls": false },
        timeout = baml.time.Duration.from_seconds(1800),
    );
    Clean { inner: generic }
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

/// A reply as BAML should see it, with gpt-oss's Harmony tags gone. llama-server leaves
/// them in the content when it cannot split a reply into thinking and answer: web-2ad.4's
/// reviewer (gpt-oss-120b on acbox, 8 Nov) answered `<|channel|>analysis<|message|>...` and
/// stopped. BAML could not parse it, sent it back as history with "answer again", and the
/// model's chat template refused any history carrying those tags (HTTP 500), so the round
/// was held though the model had only run long. The final channel's text is the answer
/// when there is one; otherwise the text is kept with its tags stripped.
function harmony_clean(text: string) -> string throws never {
    if (!text.includes("<|channel|>")) {
        return text;
    }
    let final_mark = "<|channel|>final<|message|>";
    if (text.includes(final_mark)) {
        let after = text.split(final_mark).at(text.split(final_mark).length() - 1) ?? "";
        let answer = (after.split("<|end|>").at(0) ?? after).split("<|return|>").at(0) ?? after;
        return answer.trim();
    }
    let out = text;
    for (let name in ["analysis", "commentary"]) {
        out = out.replace_all(`<|channel|>${name}<|message|>`, "");
    }
    for (
        let tag in [
            "<|start|>assistant",
            "<|start|>",
            "<|end|>",
            "<|return|>",
            "<|call|>",
            "<|message|>",
            "<|channel|>",
            "<|constrain|>",
        ]
    ) {
        out = out.replace_all(tag, "");
    }
    out.trim()
}

function clean_block(b: ai.content.ModelBlock) -> ai.content.ModelBlock throws never {
    match (b) {
        let t: ai.content.Text => ai.content.Text { text: harmony_clean(t.text) },
        _ => b,
    }
}

/// A local model's client, with each reply cleaned of Harmony tags before BAML reads it.
class Clean {
    inner: ai.Client,

    implements ai.Client {
        function requested_model(self) -> string throws never {
            self.inner.requested_model()
        }

        function provider(self) -> string throws never {
            self.inner.provider()
        }

        function render(
            self,
            input: ai.ModelTurnInput,
        ) -> baml.http.Request throws ai.errors.InvokeError {
            self.inner.render(input)
        }

        function invoke(
            self,
            input: ai.ModelTurnInput,
        ) -> ai.ModelTurn throws ai.errors.InvokeError {
            let t = self.inner.invoke(input);
            ai.ModelTurn {
                calls: t.calls,
                child_turns: t.child_turns,
                content: t.content.map((b) -> {
                    clean_block(b)
                }),
                stop_reason: t.stop_reason,
            }
        }
    }
}

test "a reply's Harmony tags are gone before BAML reads it" {
    assert.equal(harmony_clean("{\"decision\":\"Approve\"}"), "{\"decision\":\"Approve\"}");
    assert.equal(
        harmony_clean(
            "<|channel|>analysis<|message|>think<|end|><|start|>assistant<|channel|>final<|message|>{\"a\":1}<|return|>",
        ),
        "{\"a\":1}",
    );
    let only = harmony_clean("<|channel|>analysis<|message|>We need to verify the diff.<|end|>");
    assert.equal(only, "We need to verify the diff.");
    assert.is_true(!only.includes("<|"))
}

// The worker loop. Agent.run keeps every tool result it has sent, and a 30B step
// then prefills that whole prompt again (bl-b1a.1, 7 Nov: one file re-read, then
// about 10 minutes a step). This loop compacts the journal before each call.
// The last two tool results stay. Older ones become a length stub. A read whose
// text was cut can be read again.

/// Characters of tool output kept. The last two results may each be this long;
/// everything older is stubbed once the total passes it.
const TOOL_BUDGET: int = 24000;

function tool_texts(events: ai.events.Event[]) -> string[] throws never {
    let out: string[] = [];
    for (let e in events) {
        if let done: ai.events.ToolCompleted = e {
            out.push(done.text());
        }
    }
    out
}

function same_texts(a: string[], b: string[]) -> bool throws never {
    if (a.length() != b.length()) {
        return false;
    }
    let i = 0;
    while (i < a.length()) {
        if ((a.at(i) ?? "") != (b.at(i) ?? "")) {
            return false;
        }
        i = i + 1;
    }
    true
}

/// Tool results compacted to `budget`. Every other event stays where it was.
function compact_events(events: ai.events.Event[], budget: int) -> ai.events.Event[] throws never {
    let texts = tool_texts(events);
    let compacted = compact_outputs(texts, budget);
    if (same_texts(texts, compacted)) {
        return events;
    }
    let out: ai.events.Event[] = [];
    let n = 0;
    for (let e in events) {
        if let done: ai.events.ToolCompleted = e {
            out.push(ai.events.ToolCompleted.new(done.id, compacted.at(n) ?? ""));
            n = n + 1;
        } else {
            out.push(e);
        }
    }
    out
}

function texts_were_cut(before: ai.events.Event[], after: ai.events.Event[]) -> bool throws never {
    !same_texts(tool_texts(before), tool_texts(after))
}

/// Rewrite the journal the next call will send. True when a tool result was cut,
/// which is when a later read of the same file must return the file again.
function compact_journal(j: ai.Journal) -> bool throws never {
    let before = j.entries();
    let after = compact_events(before, TOOL_BUDGET);
    if (!texts_were_cut(before, after)) {
        return false;
    }
    j.log = after;
    true
}

function deliver(
    j: ai.Journal,
    from: int,
    on_event: (ai.events.Event) -> void throws never,
) -> int throws never {
    let entries = j.entries();
    let i = from;
    while (i < entries.length()) {
        if let e: ai.events.Event = entries.at(i) {
            on_event(e);
        }
        i = i + 1;
    }
    entries.length()
}

function run_one_tool(
    tools: ai.tools.Toolbox,
    call: ai.content.ToolUse,
    j: ai.Journal,
) -> void throws never {
    match (tools.get(call.name)) {
        let t: ai.tools.Tool => {
            let output = t.call(call.args) catch_all (e) {
                _ => {
                    j.append_all([ai.events.ToolFailed { id: call.id, message: e.to_string() }]);
                    return;
                },
            };
            j.append_all([ai.events.ToolCompleted.new(call.id, output)]);
        },
        null => {
            j.append_all(
                [
                    ai.events.ToolFailed {
                        id: call.id,
                        message: `tool is not in the active toolbox: ${call.name}`,
                    },
                ],
            );
        },
    }
}

function try_parse<Out>(spec: ai.FunctionSpec<Out>, text: string) -> Out? {
    spec.parse(text) catch_all (e) {
        _ => null,
    }
}

/// One worker session. Tools run one at a time. A reply that does not parse gets
/// one correction, which does not count as a step.
function run_compacted<Out>(
    client: ai.Client,
    spec: ai.FunctionSpec<Out>,
    max_steps: int,
    on_event: (ai.events.Event) -> void throws never,
) -> Out {
    let j = ai.Journal.new(spec);
    let sent = deliver(j, 0, on_event);
    let steps = 0;
    let repairs = 0;
    // A fresh session's journal is new, but the read record at this pid may not be:
    // bl-gc1.4, a revision session in the same process found its own README "already
    // read this session" for a read it never made.
    root.tools.forget_reads();
    while (steps < max_steps) {
        if (compact_journal(j)) {
            root.tools.forget_reads();
        }
        let turn = client.invoke(
            ai.ModelTurnInput {
                prompt: spec.prompt_template,
                journal: j,
                toolbox: spec.tools(),
                output_type: spec.output_type(),
            },
        );
        let batch: ai.events.Event[] = [
            ai.events.AssistantMessage {
                content: turn.content,
                resolved_model: turn.resolved_model,
                requested_model: turn.requested_model,
            },
        ];
        for (let call in turn.all_calls()) {
            batch.push(call);
        }
        for (let u in turn.tool_uses()) {
            batch.push(ai.events.ToolRequested { id: u.id, name: u.name, args: u.args });
        }
        let candidate = turn.terminal_text() ?? "";
        let provider = turn.resolved_model?.provider ?? "unknown";
        if (turn.tool_uses().length() > 0) {
            j.append_all(batch);
            sent = deliver(j, sent, on_event);
            for (let u in turn.tool_uses()) {
                run_one_tool(spec.tools(), u, j);
                sent = deliver(j, sent, on_event);
            }
            steps = steps + 1;
            repairs = 0;
        } else {
            if (turn.stop_reason == ai.content.StopReason.MaxTokens) {
                j.append_all(batch);
                let _ = deliver(j, sent, on_event);
                throw ai.errors.FinishReasonError {
                    provider: provider,
                    finish_reason: turn.stop_reason,
                    raw_output: candidate,
                };
            }
            if let value: Out = try_parse<Out>(spec, candidate) {
                j.append_all(batch);
                let _ = deliver(j, sent, on_event);
                return value;
            }
            if (repairs < 1) {
                batch.push(
                    ai.events.UserMessage.new(
                        "The reply did not match the required schema. Answer again with only the corrected value.",
                    ),
                );
                j.append_all(batch);
                sent = deliver(j, sent, on_event);
                repairs = repairs + 1;
            } else {
                j.append_all(batch);
                let _ = deliver(j, sent, on_event);
                throw ai.errors.ParseFailed { provider: provider, raw_output: candidate };
            }
        }
    }
    throw ai.errors.StepBudgetExceeded { steps: steps }
}

test "older tool results are stubbed and the last two stay" {
    let old = "the whole file follows and it is long enough that a stub is shorter than the original text of the tool result";
    let events: ai.events.Event[] = [
        ai.events.UserMessage.new("the bead"),
        ai.events.ToolCompleted.new("1", old),
        ai.events.ToolCompleted.new("2", "xx"),
        ai.events.ToolCompleted.new("3", "yy"),
    ];
    let out = compact_events(events, 40);
    let done = tool_texts(out);
    assert.equal(done.at(0), `[${old.length()} characters cut]`);
    assert.equal(done.at(1), "xx");
    assert.equal(done.at(2), "yy");
    assert.equal(out.length(), 4)
}

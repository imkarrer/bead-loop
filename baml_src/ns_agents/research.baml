// The researcher: reads, does not edit, and writes the brief a smaller worker starts from.

class ResearchResult {
    outcome: "brief" | "blocked" @description(
        "brief: the four headings below are filled. blocked: a claim in the bead is false.",
    ),
    files: string @description("one path per line, with the line range and what changes or is read-only"),
    shape: string @description("the change, step by step, naming functions and types as they are spelled"),
    check: string @description("the command that proves it, exactly as the worker should run it"),
    pitfalls: string @description("what will go wrong for a worker that follows the bead's text alone"),
    line: string? @description(
        "when blocked: BLOCKED: the false claim, with file:line of what is actually there",
    ),
}

const RESEARCH_CHARTER: string = `
    You are the researcher for one bead that a smaller model will implement after you.
    You read; you do not edit. The smaller model has a short context and loses rounds
    exploring, so your brief is what lets it start editing on its first call.

    Find every file the change touches, the shape of the change, the command that proves
    it, and what the code does that the bead's text does not say. Check each claim the
    bead makes against the code. A false claim the bead cannot be done with means you
    stop and report blocked, naming the file and line.

    When the prompt carries a previous brief and a send-back note, refine the brief so
    the next round does not fail the same way. Keep what was right.
`;

function Research(bead: string) -> ResearchResult {
    client: Devbox
    tools: [root.tools.read_file, root.tools.search, root.tools.list_files]
    prompt: `
        ${role("system")}
        ${RESEARCH_CHARTER}
        ${role("user")}
        ${bead}

        ${ctx.output_format()}
    `
}

function brief_text(r: ResearchResult) -> string throws never {
    `Files:\n${r.files}\n\nShape:\n${r.shape}\n\nCheck:\n${r.check}\n\nPitfalls:\n${r.pitfalls}`
}

function research_outcome(r: ResearchResult, second: bool) -> root.machine.Event throws never {
    if (r.outcome == "blocked") {
        root.machine.ResearchBlocked {
            kind: "research_blocked",
            line: r.line ?? "BLOCKED: (the researcher gave no line)",
            second_opinion: second,
        }
    } else {
        root.machine.BriefWritten { kind: "brief_written", overruled: second, text: brief_text(r) }
    }
}

function result_of(outcome: "brief" | "blocked", line: string = "") -> ResearchResult throws never {
    ResearchResult {
        outcome: outcome,
        files: "f",
        shape: "s",
        check: "c",
        pitfalls: "p",
        line: line,
    }
}

test "a brief is the four headings" {
    let e = research_outcome(result_of("brief"), false);
    if let x: root.machine.BriefWritten = e {
        assert.contains(x.text, "Files:");
        assert.contains(x.text, "Shape:");
        assert.is_true(!x.overruled);
    } else {
        assert.is_true(false);
    }
}

test "a blocked research is the line, and a second opinion is marked" {
    let e = research_outcome(result_of("blocked", line = "BLOCKED: no such fn"), true);
    if let x: root.machine.ResearchBlocked = e {
        assert.equal(x.line, "BLOCKED: no such fn");
        assert.is_true(x.second_opinion);
    } else {
        assert.is_true(false);
    }
}

test "a brief need not carry the BLOCKED line" {
    let r = baml.json.decode<ResearchResult>(
        "{\"outcome\":\"brief\",\"files\":\"layouts/_default/sponsors.html\",\"shape\":\"1. ...\",\"check\":\"hugo\",\"pitfalls\":\"p\"}",
    );
    assert.is_type<root.machine.BriefWritten>(research_outcome(r, false));
}

// The park brief: what the owner reads when the loop has given up. The supervisor
// writes it from the reason it already has; the agent is for a later round that
// reads the logs.

class ParkBrief {
    happened: string @description("one line per round: what it tried, what stopped it"),
    why: string @description("the cause: the bead is wrong, underspecified, the environment, or the model"),
    question: string @description("one to three questions, each answerable in a sentence"),
}

const PARK_CHARTER: string = `
    You write the brief a bead's owner reads when the automated loop has given up.
    The brief has to be true to the logs. Quote the line that decided each round when
    it is short. Then say why, one of: the bead is wrong; the bead is right but
    underspecified; the environment; the model. End with the question for the owner.
`;

function ParkBriefAgent(bead: string, notes: string, because: string) -> ParkBrief {
    client: Devbox
    tools: [root.tools.read_file]
    prompt: `
        ${role("system")}
        ${PARK_CHARTER}
        ${role("user")}
        <bead>
        ${bead}
        </bead>
        <notes>
        ${notes}
        </notes>
        <because>
        ${because}
        </because>
        ${ctx.output_format()}
    `
}

/// The brief the supervisor can write without a model call: the reason it parked, said
/// once (pw-xl2's, 8 Nov, said it three times), and the question it leaves you.
function park_brief_text(because: string, last_note: string) -> string throws never {
    let happened = if (last_note.length() > 0 && last_note != because) {
        `${last_note}\n${because}`
    } else {
        because
    };
    `WHAT HAPPENED:\n${happened}\nQUESTION:\nWhat should the next round know? Answer it on the page, or Reopen or Escalate it.`
}

test "a park brief says why once, and asks" {
    let t = park_brief_text("BLOCKED: no such file", "");
    assert.contains(t, "WHAT HAPPENED:\nBLOCKED: no such file\nQUESTION:");
    assert.equal(t.split("no such file").length(), 2);
    assert.contains(
        park_brief_text("the stages are exhausted", "worker made no commit"),
        "worker made no commit",
    )
}

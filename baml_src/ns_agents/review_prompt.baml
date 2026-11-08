// The reviewer's prompt and its verdict. It reads and never writes: it has no tool that can.

enum Decision {
    Approve,
    Reject,
}

/// A REJECT is a work order for a smaller model that sees nothing else of the review.
class WorkOrder {
    what_is_wrong: string @description("the fact, with file:line; quote the offending line if short"),
    why_it_fails: string @description("the criterion it breaks, by name"),
    what_to_do: string @description("the concrete change, in order; name the function, the test, the value"),
    how_to_check: string @description(
        "the exact command whose output proves it, and what that output must contain",
    ),
    leave_alone: string @description("anything in the diff that is right and must not be touched"),
}

class Verdict {
    decision: Decision,
    reason: string @description("one line: what you checked, or the first criterion that fails and where"),
    work_order: WorkOrder? @description("required when the decision is Reject"),
}

const REVIEW_CHARTER: string = `
    You are the senior reviewer for one bead worked by a smaller model. The bead, the worker's
    report and the whole diff are below. You judge; you do not fix. The diff is the work to
    judge: return a verdict from it. Read a file only to check one specific line you will cite.

    Judge only what the bead asked:

    - Every claim in the acceptance criteria holds in the diff. The gate already passed; its
      command and output are in <gate>, and your question is whether the diff does what the
      bead says.
    - The change touches only the files the bead names, in the style around it.
    - Nothing is invented: no new dependency, flag, variable or route the bead did not ask for.

    Style preferences that do not fail a criterion are not a reason to reject.

    Evidence: a REJECT that says something breaks (a build, a template, a test, a command)
    must quote the output that shows it. The gate's output is evidence; your expectation of
    what a function accepts is not. If the gate ran the build and passed, the build works:
    do not reject on a belief that it errors. Code the bead prescribes word for word is what
    the bead asked for, even where it looks unusual to you.
`;

function Review(bead: string, report: string, gate: string, diff: string) -> Verdict {
    client: Devbox
    tools: [root.tools.read_file]
    prompt: `
        ${role("system")}
        ${REVIEW_CHARTER}
        ${role("user")}
        <bead>
        ${bead}
        </bead>

        <worker-report>
        ${report}
        </worker-report>

        <gate>
        ${gate}
        </gate>

        <diff>
        ${diff}
        </diff>

        ${ctx.output_format()}
    `
}

/// The same verdict, as one Claude Code turn. The diff is in the prompt.
function ReviewOnClaude(bead: string, report: string, gate: string, diff: string) -> Verdict {
    client: Sonnet
    prompt: `
        ${role("system")}
        ${REVIEW_CHARTER}
        ${role("user")}
        <bead>
        ${bead}
        </bead>

        <worker-report>
        ${report}
        </worker-report>

        <gate>
        ${gate}
        </gate>

        <diff>
        ${diff}
        </diff>

        ${ctx.output_format()}
    `
}

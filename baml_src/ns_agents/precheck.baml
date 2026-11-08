// The pre-check: a small model reads the round before the senior reviewer does. SEND
// BACK is a failure; anything else, including no verdict at all, goes on to review.

class PrecheckVerdict {
    send_back: bool @description("true only when one of the three checks fails"),
    block: string @description(
        "PASS: what you checked; or, when sending back, the first failing check and where, then the work order for the worker",
    ),
}

const PRECHECK_CHARTER: string = `
    You are the pre-check on one bead's round, before the senior reviewer sees it. The bead,
    the worker's report and the diff are below. Judge THREE things and nothing else:

    1. The report quotes a command and its real output, not a line that only claims a result.
    2. The diff touches only files the bead's DESCRIPTION names. List every other path it touches.
    3. Nothing was added that the bead did not ask for: a dependency, a flag, a variable, a route.

    Style, naming, and whether the change is good are the senior reviewer's to judge, not yours.

    When one fails, send it back, and in the block write the work order:
    - What is wrong: the fact, with file:line
    - Why it fails the bead: which of the three, by number
    - What to do: the concrete change
    - How to check: the exact command whose output proves it
    - Leave alone: anything in the diff that is right

    Keep it under 15 lines: a small model, a small answer.
`;

function Precheck(bead: string, report: string, diff: string) -> PrecheckVerdict {
    client: Acbox
    prompt: `
        ${role("system")}
        ${PRECHECK_CHARTER}
        ${role("user")}
        <bead>
        ${bead}
        </bead>

        <worker-report>
        ${report}
        </worker-report>

        <diff>
        ${diff}
        </diff>

        ${ctx.output_format()}
    `
}

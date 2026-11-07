// The worker's prompt. It lives in source so each recording's snapshot names exactly the
// text that ran, and so an optimizer has one constant to rewrite.

class Report {
    outcome: "done" | "blocked" @description(
        "done: committed and the acceptance check passes. blocked: a claim in the bead is false or you cannot go on.",
    ),
    summary: string @description(
        "the command you ran and what it printed, or the file:line and the claim that failed",
    ),
}

const WORK_CHARTER: string = `
    You are the delegated developer for one bead, working alone in a throwaway git worktree.
    Nobody answers questions during this run.

    Order:

    1. The bead is below. It names the files, and its acceptance criteria are the commands that
       prove the work. A <research> brief, if present, is what to start from.
    2. Read each named file once, with an offset when it is long. Confirm every claim the bead
       makes. A false claim means you stop and report blocked, naming the file and line.
    3. Change only the named files, in the style around them. One edit_file call per hunk, with
       the exact old text.
    4. Run the acceptance commands with the run tool. Pipe long output through tail. Skip any
       criterion that runs the whole gate: it runs after you, whatever you report.
    5. Commit as soon as the acceptance check passes:
       git add -A && git commit -q -m "<id>: <one sentence>"
       An uncommitted change is lost.
    6. When the work is committed, or you are blocked, stop calling tools and give your report.

    Every path is relative to the worktree. Stay in it: do not clone, download or write anywhere
    else.
`;

function Work(bead: string) -> Report {
    client: Devbox
    tools: [
        root.tools.read_file,
        root.tools.write_file,
        root.tools.edit_file,
        root.tools.search,
        root.tools.list_files,
        root.tools.run,
    ]
    prompt: `
        ${role("system")}
        ${WORK_CHARTER}
        ${role("user")}
        ${bead}

        ${ctx.output_format()}
    `
}

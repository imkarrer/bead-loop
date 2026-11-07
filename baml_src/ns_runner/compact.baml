// Compaction for a session whose tool outputs have grown past the model's context.
// Agent.run always starts a fresh Journal, so this cannot yet drop messages the
// runner already sent; it is the function a runner of our own will call, and the
// tests pin the rule: keep the latest outputs, stub the oldest.

const KEEP_LAST: int = 2;

function total_len(outputs: string[]) -> int throws never {
    outputs.reduce(
        (n, s) -> {
            n + s.length()
        },
        0,
    )
}

function stub(s: string) -> string throws never {
    `[${s.length()} characters cut]`
}

function tail_to(s: string, budget: int) -> string throws never {
    if (s.length() <= budget) {
        return s;
    }
    `[first ${s.length() - budget} characters cut]\n${s.slice(s.length() - budget, s.length())}`
}

function replace_at(items: string[], at: int, value: string) -> string[] throws never {
    let out: string[] = [];
    let i = 0;
    while (i < items.length()) {
        if (i == at) {
            out.push(value);
        } else {
            out.push(items.at(i) ?? "");
        }
        i = i + 1;
    }
    out
}

/// Oldest first. The last KEEP_LAST stay (tailed to the budget if one of them
/// alone is larger). Earlier ones become stubs until the total fits.
function compact_outputs(outputs: string[], budget: int) -> string[] throws never {
    if (outputs.length() == 0 || budget <= 0) {
        return outputs;
    }
    let keep_from = if (outputs.length() <= KEEP_LAST) {
        0
    } else {
        outputs.length() - KEEP_LAST
    };
    let out: string[] = [];
    let i = 0;
    while (i < outputs.length()) {
        let s = outputs.at(i) ?? "";
        if (i >= keep_from) {
            out.push(tail_to(s, budget));
        } else {
            out.push(s);
        }
        i = i + 1;
    }
    i = 0;
    while (i < keep_from && total_len(out) > budget) {
        let s = out.at(i) ?? "";
        let cut = stub(s);
        if (s.length() > cut.length()) {
            out = replace_at(out, i, cut);
        }
        i = i + 1;
    }
    out
}

test "under the budget nothing is cut" {
    assert.equal(compact_outputs(["aa", "bb"], 100), ["aa", "bb"])
}

test "the oldest output is stubbed first" {
    let old = "the whole file follows and it is long enough that a stub is shorter than the original text of the tool result";
    let out = compact_outputs([old, "xx", "yy"], 40);
    assert.equal(out.at(0), `[${old.length()} characters cut]`);
    assert.equal(out.at(1), "xx");
    assert.equal(out.at(2), "yy")
}

test "the last output is kept even when it is the whole budget" {
    let out = compact_outputs(["zzzzzzzzzz"], 4);
    assert.contains(out.at(0) ?? "", "zzzz")
}

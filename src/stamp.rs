//! The stamp: what produced one model session, written to `beads/ID/stamps.jsonl` (one
//! line per session, including the round that lands) so a later question — did this
//! change help, is config A better than config B — can slice production by what ran it.
//! The session stamp itself is not wired to a round yet (docs/design-measurement.md
//! piece 1, ADR 0001); `write_claim`'s `claim` line is (piece 2, decision 14).
use crate::config::{Approvals, Repo, Resolved};
use crate::shell::git_ok;
use crate::state::StageHit;
use crate::util::{append_file, cut_bytes, date_iminutes, read_to_string};
use serde_json::{json, Value};
use std::path::Path;

/// FNV-1a, 64-bit, as 16 hex digits. No crate: the hash only needs to be stable and
/// cheap, never cryptographic.
pub fn fnv_hex(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// A file's content hash, or `"missing"` when it cannot be read.
#[allow(dead_code)]
pub fn hash_file(p: &Path) -> String {
    match std::fs::read(p) {
        Ok(bytes) => fnv_hex(&bytes),
        Err(_) => "missing".into(),
    }
}

/// A directory tree's content hash, following symlinks (`install.sh` links `skills/NAME`
/// into place): every file under `dir`, sorted by its relative path, each folded in as
/// `path\0bytes\0`. `"missing"` when `dir` is not a directory.
#[allow(dead_code)]
pub fn hash_tree(dir: &Path) -> String {
    if !dir.is_dir() {
        return "missing".into();
    }
    let mut files = Vec::new();
    collect_files(dir, dir, &mut files);
    files.sort();
    let mut buf = Vec::new();
    for rel in files {
        buf.extend_from_slice(rel.to_string_lossy().as_bytes());
        buf.push(0);
        if let Ok(bytes) = std::fs::read(dir.join(&rel)) {
            buf.extend_from_slice(&bytes);
        }
        buf.push(0);
    }
    fnv_hex(&buf)
}

#[allow(dead_code)]
fn collect_files(root: &Path, dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        if meta.is_dir() {
            collect_files(root, &path, out);
        } else if meta.is_file() {
            if let Ok(rel) = path.strip_prefix(root) {
                out.push(rel.to_path_buf());
            }
        }
    }
}

#[allow(dead_code)]
fn approvals_str(a: &Approvals) -> String {
    match a {
        Approvals::All => "all".into(),
        Approvals::Any => "any".into(),
        Approvals::Count(n) => format!("count={n}"),
    }
}

/// The resolved stage and the round-changing target keys, hashed; never `attach`,
/// `probe`, `command`, `via` or anything else from `opencode.json` (credentials, URLs).
#[allow(dead_code)]
pub fn config_hash(repo: &Repo, stage: Option<&StageHit>, r: &Resolved) -> String {
    let mut lines = Vec::new();
    if let Some(s) = stage {
        lines.push(format!("stage.model={}", s.model));
        lines.push(format!("stage.review={}", s.review));
        lines.push(format!("stage.failures={}", s.failures));
        for (i, seat) in s.seats.iter().enumerate() {
            lines.push(format!("stage.seat.{i}.model={}", seat.model));
            lines.push(format!("stage.seat.{i}.agent={}", seat.agent));
        }
        lines.push(format!("stage.approvals={}", approvals_str(&s.approvals)));
    }
    lines.push(format!("provider.name={}", r.provider.name));
    lines.push(format!("provider.harness={}", r.provider.harness));
    lines.push(format!("provider.parallel={}", r.provider.parallel));
    lines.push(format!("provider.cost={}", r.provider.cost));
    lines.push(format!("harness={}", r.harness));
    lines.push(format!("model={}", r.model));
    lines.push(format!("repo.gate={}", repo.gate));
    lines.push(format!("repo.setup={}", repo.setup));
    lines.push(format!("repo.base={}", repo.base));
    fnv_hex(lines.join("\n").as_bytes())
}

/// One model session, as written to `stamps.jsonl`.
#[allow(dead_code)]
pub struct Stamp {
    pub round: u64,
    pub dirty: bool,
    pub kind: String,
    pub log: String,
    pub loop_sha: String,
    pub prompt_hash: String,
    pub skills_hash: String,
    pub base_sha: String,
    pub stage: String,
    pub provider: String,
    pub model: String,
    pub harness: String,
    pub config_hash: String,
}

impl Stamp {
    #[allow(dead_code)]
    pub fn to_json(&self) -> Value {
        json!({
            "round": self.round,
            "dirty": self.dirty,
            "kind": self.kind,
            "log": self.log,
            "loop_sha": self.loop_sha,
            "prompt_hash": self.prompt_hash,
            "skills_hash": self.skills_hash,
            "base_sha": self.base_sha,
            "stage": self.stage,
            "provider": self.provider,
            "model": self.model,
            "harness": self.harness,
            "config_hash": self.config_hash,
        })
    }
}

/// Append one stamp line to `beads/ID/stamps.jsonl`.
pub fn append(repo: &Repo, id: &str, line: &Value) {
    append_file(&repo.stamps_path(id), &format!("{line}\n"));
}

/// The stamps of a bead, oldest first — the lines that parse.
pub fn read(repo: &Repo, id: &str) -> Vec<Value> {
    read_to_string(&repo.stamps_path(id)).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// The claim line: a bead's features at the moment it is first claimed, so a later
/// question ("the beads got easier" vs "the loop got better") reads what was true then,
/// never rebuilt (decision 14, docs/design-measurement.md). A no-op once a claim line
/// exists, or for a bead with rounds from before this change (`park::rounds`).
pub fn write_claim(repo: &Repo, id: &str, bead_json: &Value) {
    if read(repo, id).iter().any(|l| l.get("claim").is_some()) {
        return;
    }
    if !crate::park::rounds(repo, id).is_empty() {
        return;
    }
    let b = bead_json.get(0).cloned().unwrap_or(Value::Null);
    let s = |k: &str| b.get(k).and_then(|v| v.as_str()).unwrap_or("");
    let description = s("description");
    let acceptance = s("acceptance_criteria");
    let labels: Vec<&str> =
        b.get("labels").and_then(|l| l.as_array()).map(|a| a.iter().filter_map(|v| v.as_str()).collect()).unwrap_or_default();

    let base_ref = format!("{}/{}", repo.base_remote, repo.base);
    let tokens = crate::harness::path_tokens(description);
    let on_base: Vec<bool> = tokens.iter().map(|t| git_ok(&repo.repo, &["cat-file", "-e", &format!("{base_ref}:{t}")])).collect();
    let files_on_base = on_base.iter().filter(|b| **b).count();
    let greenfield = tokens.iter().zip(&on_base).any(|(t, on_base)| t.contains('/') && t.contains('.') && !on_base);

    let stage = repo.stage_for(repo.failures_of(id));
    let start_stage = stage.as_ref().map(|s| repo.stages[s.index - 1].name.clone()).unwrap_or_default();
    let harness = stage.as_ref().map(|s| crate::round::harness_for(&labels, &s.model, None).0).unwrap_or_default();

    let planned_in = labels.iter().find_map(|l| l.strip_prefix("planned-in:")).unwrap_or("").to_string();

    append(
        repo,
        id,
        &json!({"claim": {
            "when": date_iminutes(),
            "title": cut_bytes(s("title"), 20000),
            "description": cut_bytes(description, 20000),
            "acceptance": cut_bytes(acceptance, 20000),
            "labels": labels,
            "files_named": tokens.len(),
            "files_on_base": files_on_base,
            "description_chars": description.chars().count(),
            "start_stage": start_stage,
            "harness": harness,
            "acceptance_kind": acceptance_kind(acceptance),
            "greenfield": greenfield,
            "linted": linted_of(s("notes")),
            "planned_in": planned_in,
        }}),
    );
}

/// `none` for an empty acceptance; `command` when a backtick span in it starts with one
/// of the shapes a loop check runs (`cargo`, `bash`, `sh`, `test`, `grep`, `rg`, `git`,
/// `node`, `npm`, `make`, `flox`, `shellcheck`, `./` or `test/`); else `prose`.
fn acceptance_kind(s: &str) -> &'static str {
    if s.is_empty() {
        return "none";
    }
    const PREFIXES: &[&str] =
        &["cargo", "bash", "sh", "test", "grep", "rg", "git", "node", "npm", "make", "flox", "shellcheck", "./", "test/"];
    let is_command = s.split('`').enumerate().any(|(i, span)| i % 2 == 1 && PREFIXES.iter().any(|p| span.trim_start().starts_with(p)));
    if is_command {
        "command"
    } else {
        "prose"
    }
}

/// `pass` for a notes line `bead-loop lint DATE: pass`, `fail` for any other
/// `bead-loop lint DATE:` line, else `""` (decisions 17, 18). The last such line wins.
fn linted_of(notes: &str) -> String {
    let mut out = String::new();
    for l in notes.lines() {
        if let Some(rest) = l.trim_start().strip_prefix("bead-loop lint ") {
            if let Some((_, what)) = rest.split_once(": ") {
                out = if what == "pass" { "pass".to_string() } else { "fail".to_string() };
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{scratch, test_repo, Provider, Seat};

    #[test]
    fn hash_tree_is_equal_for_two_copies_and_differs_on_a_change() {
        let d = scratch("hash-tree");
        let a = d.join("a");
        let b = d.join("b");
        std::fs::create_dir_all(a.join("sub")).unwrap();
        std::fs::create_dir_all(b.join("sub")).unwrap();
        std::fs::write(a.join("one"), "hello").unwrap();
        std::fs::write(a.join("sub/two"), "world").unwrap();
        std::fs::write(b.join("one"), "hello").unwrap();
        std::fs::write(b.join("sub/two"), "world").unwrap();
        let ha = hash_tree(&a);
        let hb = hash_tree(&b);
        assert_eq!(ha, hb, "two copies of the same tree hash the same");

        std::fs::write(b.join("sub/two"), "worlds").unwrap();
        assert_ne!(hash_tree(&b), hb, "one changed byte changes the hash");

        std::fs::write(b.join("sub/two"), "world").unwrap();
        std::fs::write(b.join("three"), "new").unwrap();
        assert_ne!(hash_tree(&b), hb, "an added file changes the hash");

        assert_eq!(hash_tree(&d.join("missing")), "missing");
    }

    fn resolved(model: &str, parallel: u64, attach: &str) -> Resolved {
        let mut provider = Provider::implicit("x");
        provider.parallel = parallel;
        provider.attach = attach.to_string();
        Resolved { provider, harness: "opencode".into(), model: model.into() }
    }

    fn stage() -> StageHit {
        StageHit {
            model: "fast".into(),
            review: "rev".into(),
            failures: 2,
            timeout: 900,
            last: false,
            index: 1,
            seats: vec![Seat { model: "rev".into(), agent: String::new() }],
            approvals: Approvals::All,
        }
    }

    #[test]
    fn config_hash_moves_with_parallel_and_model_not_attach() {
        let d = scratch("config-hash");
        let repo = test_repo(&d, &["fast:rev:2"]);
        let base = config_hash(&repo, Some(&stage()), &resolved("x/one", 1, "a"));

        assert_ne!(base, config_hash(&repo, Some(&stage()), &resolved("x/one", 2, "a")), "parallel changes the hash");
        assert_ne!(base, config_hash(&repo, Some(&stage()), &resolved("x/two", 1, "a")), "the model changes the hash");
        assert_eq!(base, config_hash(&repo, Some(&stage()), &resolved("x/one", 1, "b")), "attach never changes the hash");
    }

    #[test]
    fn append_then_read_round_trips() {
        let d = scratch("stamp-rw");
        let repo = test_repo(&d, &["fast:rev:2"]);
        append(&repo, "t-1", &json!({"round": 1, "kind": "worker"}));
        append(&repo, "t-1", &json!({"round": 1, "kind": "review"}));
        let lines = read(&repo, "t-1");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["kind"], "worker");
        assert_eq!(lines[1]["kind"], "review");
    }

    fn git(dir: &Path, args: &[&str]) {
        assert!(std::process::Command::new("git").args(args).current_dir(dir).status().unwrap().success(), "git {args:?} in {dir:?}");
    }

    #[test]
    fn write_claim_captures_the_bead_at_first_claim() {
        let d = scratch("write-claim");
        let repo = test_repo(&d, &["fast:rev:2"]);
        git(&repo.repo, &["init", "-q"]);
        git(&repo.repo, &["config", "user.email", "t@t"]);
        git(&repo.repo, &["config", "user.name", "t"]);
        std::fs::create_dir_all(repo.repo.join("src")).unwrap();
        std::fs::write(repo.repo.join("src/on_base.rs"), "").unwrap();
        git(&repo.repo, &["add", "-A"]);
        git(&repo.repo, &["commit", "-q", "-m", "base"]);
        git(&repo.repo, &["update-ref", "refs/remotes/origin/main", "HEAD"]);

        let bead = json!([{
            "title": "T",
            "description": "Edit src/on_base.rs and add src/new_feature.ts to it.",
            "acceptance_criteria": "Run `cargo test path_tokens`",
            "labels": ["foo", "planned-in:abc"],
            "notes": "bead-loop lint 2026-01-01T00:00+00:00: pass",
        }]);
        write_claim(&repo, "t-1", &bead);
        let lines = read(&repo, "t-1");
        assert_eq!(lines.len(), 1, "one claim line");
        let claim = &lines[0]["claim"];
        assert_eq!(claim["title"], "T");
        assert_eq!(claim["files_named"], 2, "src/on_base.rs and src/new_feature.ts");
        assert_eq!(claim["files_on_base"], 1, "only src/on_base.rs is on base");
        assert_eq!(claim["start_stage"], "1");
        assert_eq!(claim["harness"], "fast");
        assert_eq!(claim["acceptance_kind"], "command");
        assert_eq!(claim["greenfield"], true, "src/new_feature.ts is not on base");
        assert_eq!(claim["linted"], "pass");
        assert_eq!(claim["planned_in"], "abc");

        write_claim(&repo, "t-1", &bead);
        assert_eq!(read(&repo, "t-1").len(), 1, "a second claim is a no-op");
    }

    #[test]
    fn write_claim_skips_a_bead_with_rounds_from_before_the_change() {
        let d = scratch("write-claim-old");
        let repo = test_repo(&d, &["fast:rev:2"]);
        append_file(&repo.rounds_path("t-1"), "{\"round\":1}\n");
        write_claim(&repo, "t-1", &json!([{"title": "T"}]));
        assert!(read(&repo, "t-1").is_empty(), "no claim for a bead with prior rounds");
    }
}

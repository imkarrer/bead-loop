//! The stamp: what produced one model session, written to `beads/ID/stamps.jsonl` (one
//! line per session, including the round that lands) so a later question — did this
//! change help, is config A better than config B — can slice production by what ran it.
//! Nothing here is wired to a round yet (docs/design-measurement.md piece 1, ADR 0001).
use crate::config::{Approvals, Repo, Resolved};
use crate::state::StageHit;
use crate::util::{append_file, read_to_string};
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
#[allow(dead_code)]
pub fn append(repo: &Repo, id: &str, line: &Value) {
    append_file(&repo.stamps_path(id), &format!("{line}\n"));
}

/// The stamps of a bead, oldest first — the lines that parse.
#[allow(dead_code)]
pub fn read(repo: &Repo, id: &str) -> Vec<Value> {
    read_to_string(&repo.stamps_path(id)).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
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
}

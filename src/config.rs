//! Two TOML files, every key optional: the global `~/.config/bead-loop/config.toml` and
//! the repo's `.bead-loop.toml`. A key in the repo file wins over the global one; the
//! global one wins over the default. A file that does not parse stops the run with its
//! name. `Repo` is what the bash's `load_repo` left in its variables: everything a round
//! needs to know about one repo, read afresh every time (so a config edit takes effect on
//! the next round).
use crate::util::{die, expand_tilde, home};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// One `[[stages]]` table: a stage takes the bead for the next `failures` send-backs.
#[derive(Clone, Debug, PartialEq)]
pub struct Stage {
    pub worker: String,
    pub reviewer: String,
    pub failures: u64,
    pub timeout: Option<u64>,
}

/// The two files as JSON objects.
#[derive(Clone, Debug)]
pub struct Layers {
    pub global: Value,
    pub repo: Value,
}

/// `toml_json FILE`: the file as one JSON object ({} when absent or empty); a parse error
/// is a loud stop naming the file.
pub fn toml_json(path: &Path) -> Value {
    match parse_toml(path) {
        Ok(v) => v,
        Err(e) => die(&e),
    }
}

/// The file as one JSON object; Err names the file and what did not parse.
pub fn parse_toml(path: &Path) -> Result<Value, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return Ok(Value::Object(Default::default())),
    };
    if text.trim().is_empty() {
        return Ok(Value::Object(Default::default()));
    }
    match text.parse::<toml::Table>() {
        Ok(t) => Ok(serde_json::to_value(t).unwrap_or(Value::Object(Default::default()))),
        Err(e) => Err(format!("{}: {}", path.display(), e.message())),
    }
}

/// A scalar as text, the way `yq -r` printed it: booleans as true/false, numbers plain,
/// arrays joined by spaces.
fn scalar(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::Array(a) => a.iter().map(scalar).collect::<Vec<_>>().join(" "),
        Value::Null => String::new(),
        Value::Object(_) => String::new(),
    }
}

impl Layers {
    pub fn load(global_path: &Path, repo_path: Option<&Path>) -> Layers {
        Layers { global: toml_json(global_path), repo: repo_path.map(toml_json).unwrap_or(Value::Object(Default::default())) }
    }

    /// `cfg KEY [DEFAULT]`: the repo file, then the global one, then DEFAULT.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.repo.get(key).filter(|v| !v.is_null()).or_else(|| self.global.get(key).filter(|v| !v.is_null()))
    }

    pub fn str(&self, key: &str, default: &str) -> String {
        self.get(key).map(scalar).unwrap_or_else(|| default.to_string())
    }

    pub fn u64(&self, key: &str, default: u64) -> u64 {
        match self.get(key) {
            Some(Value::Number(n)) => n.as_u64().unwrap_or(default),
            Some(Value::String(s)) => s.trim().parse().unwrap_or(default),
            _ => default,
        }
    }

    pub fn bool(&self, key: &str, default: bool) -> bool {
        match self.get(key) {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => s == "true",
            _ => default,
        }
    }

    /// `repos`, global only, `~` expanded.
    pub fn repos(&self) -> Vec<PathBuf> {
        match self.global.get("repos") {
            Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str()).map(expand_tilde).collect(),
            Some(Value::String(s)) => s.split_whitespace().map(expand_tilde).collect(),
            _ => Vec::new(),
        }
    }

    /// The stages table the repo file sets, else the global one's; empty when neither
    /// does. `attempts` is the older name for `failures` and still reads; a stage with
    /// neither takes one failure.
    pub fn stages(&self) -> Vec<Stage> {
        let table = match self.repo.get("stages").or_else(|| self.global.get("stages")) {
            Some(Value::Array(a)) => a,
            _ => return Vec::new(),
        };
        table
            .iter()
            .map(|s| Stage {
                worker: s.get("worker").map(scalar).unwrap_or_default(),
                reviewer: s.get("reviewer").map(scalar).unwrap_or_default(),
                failures: s
                    .get("failures")
                    .or_else(|| s.get("attempts"))
                    .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|t| t.parse().ok())))
                    .unwrap_or(1),
                timeout: s.get("timeout").and_then(|v| v.as_u64()),
            })
            .collect()
    }
}

/// The global config's path: `$BEAD_LOOP_CONFIG/config.toml`, default `~/.config/bead-loop`.
pub fn config_dir() -> PathBuf {
    std::env::var_os("BEAD_LOOP_CONFIG").map(PathBuf::from).unwrap_or_else(|| home().join(".config/bead-loop"))
}

/// The state dir: `$BEAD_LOOP_STATE`, default `~/.local/state/bead-loop`.
pub fn state_dir() -> PathBuf {
    let d = std::env::var_os("BEAD_LOOP_STATE").map(PathBuf::from).unwrap_or_else(|| home().join(".local/state/bead-loop"));
    let _ = std::fs::create_dir_all(&d);
    d
}

/// Where this checkout is (agents/, ui/): `$BEAD_LOOP_HOME`, else the binary's parent's
/// parent (target/debug/x → the checkout; ~/.local/bin/x → ~/.local, where install.sh
/// puts an agents/ link too).
pub fn loop_home() -> PathBuf {
    if let Some(h) = std::env::var_os("BEAD_LOOP_HOME") {
        return PathBuf::from(h);
    }
    let exe = std::env::current_exe().ok().and_then(|p| std::fs::canonicalize(p).ok());
    if let Some(exe) = exe {
        // target/debug/bead-supervisor or target/release/bead-supervisor → the checkout
        let mut p = exe.clone();
        for _ in 0..4 {
            if !p.pop() {
                break;
            }
            if p.join("agents").is_dir() && p.join("ui").is_dir() {
                return p;
            }
        }
        if let Some(parent) = exe.parent().and_then(|p| p.parent()) {
            return parent.to_path_buf();
        }
    }
    PathBuf::from(".")
}

/// Everything the bash's `load_repo` set, for one repo.
#[derive(Clone, Debug)]
pub struct Repo {
    pub repo: PathBuf,
    pub slug: String,
    pub label: String,
    pub merge: String,
    pub merge_label: String,
    pub setup: String,
    pub gate: String,
    pub model: String,
    pub review_model: String,
    pub stages: Vec<Stage>,
    pub on_exhaust: String,
    pub conflict_worker: String,
    /// who writes the brief when a bead is parked: the last stage's worker unless set; `none` for no brief
    pub brief_model: String,
    pub adopt: bool,
    pub max_inflight: u64,
    pub worker_timeout: u64,
    pub attach: String,
    pub base: String,
    /// `$STATE_DIR/<slug>`
    pub rs: PathBuf,
    pub state_dir: PathBuf,
}

impl Repo {
    /// `load_repo REPO`, with the worker model flag (`--model M`) applied.
    pub fn load(path: &Path, model_flag: Option<&str>) -> Repo {
        let repo = match std::fs::canonicalize(path) {
            Ok(p) if p.is_dir() => p,
            _ => die(&format!("no such repo: {}", path.display())),
        };
        if !repo.join(".beads").is_dir() {
            die(&format!("{} has no .beads/", repo.display()));
        }
        let cfg = Layers::load(&config_dir().join("config.toml"), Some(&repo.join(".bead-loop.toml")));
        let slug = repo.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let model = model_flag.map(str::to_string).unwrap_or_else(|| cfg.str("model", ""));
        let review_model = cfg.str("review_model", "");
        let mut stages = cfg.stages();
        if stages.is_empty() {
            stages.push(Stage { worker: model.clone(), reviewer: review_model.clone(), failures: 3, timeout: None });
        }
        for s in &stages {
            if s.worker.starts_with("claude/") || s.reviewer.starts_with("claude/") {
                need("claude");
            }
            if s.worker.starts_with("aider:") {
                need("aider");
            }
        }
        let mut base = cfg.str("base", "");
        if base.is_empty() {
            base = origin_head(&repo);
        }
        if base.is_empty() {
            die(&format!("{slug}: cannot tell the base branch; set base in .bead-loop.toml"));
        }
        let state_dir = state_dir();
        let rs = state_dir.join(&slug);
        make_state_dirs(&rs);
        Repo {
            label: cfg.str("label", "delegate:local"),
            merge: cfg.str("merge", "auto"),
            merge_label: cfg.str("merge_label", "automerge"),
            setup: cfg.str("setup", ""),
            gate: cfg.str("gate", ""),
            on_exhaust: cfg.str("on_exhaust", "park"),
            conflict_worker: cfg.str("conflict_worker", ""),
            brief_model: cfg.str("brief_model", ""),
            adopt: cfg.bool("adopt", true),
            max_inflight: cfg.u64("max_inflight", u64::MAX),
            worker_timeout: cfg.u64("worker_timeout", 3600),
            attach: cfg.str("attach", ""),
            model,
            review_model,
            stages,
            base,
            slug,
            repo,
            rs,
            state_dir,
        }
    }
}

/// The repo's state directories, and the older `attempts/` carried into `failures/`:
/// same counter, file by file (a status run may have made failures/ first), then the
/// old directory goes.
pub fn make_state_dirs(rs: &Path) {
    for d in ["inflight", "logs", "wt", "review", "failures", "held", "parked", "rejoin"] {
        let _ = std::fs::create_dir_all(rs.join(d));
    }
    let old = rs.join("attempts");
    if old.is_dir() {
        if let Ok(rd) = std::fs::read_dir(&old) {
            for e in rd.flatten() {
                let dst = rs.join("failures").join(e.file_name());
                if !dst.exists() {
                    let _ = std::fs::rename(e.path(), dst);
                }
            }
        }
        let _ = std::fs::remove_dir_all(&old);
    }
}

/// A `Repo` over a scratch directory, for the unit tests: no git, no bd, no config
/// files — `root/repo` as the checkout, `root/state` as the state dir, the stages given
/// as `worker[:reviewer[:failures]]`.
#[cfg(test)]
pub fn test_repo(root: &Path, stages: &[&str]) -> Repo {
    let repo = root.join("repo");
    let state_dir = root.join("state");
    let rs = state_dir.join("repo");
    let _ = std::fs::create_dir_all(&repo);
    let _ = std::fs::create_dir_all(&state_dir);
    make_state_dirs(&rs);
    let stages: Vec<Stage> = stages
        .iter()
        .map(|s| {
            let mut it = s.split(':');
            Stage {
                worker: it.next().unwrap_or("").to_string(),
                reviewer: it.next().unwrap_or("").to_string(),
                failures: it.next().and_then(|n| n.parse().ok()).unwrap_or(1),
                timeout: None,
            }
        })
        .collect();
    let model = stages.first().map(|s| s.worker.clone()).unwrap_or_default();
    let review_model = stages.first().map(|s| s.reviewer.clone()).unwrap_or_default();
    Repo {
        slug: "repo".into(),
        label: "delegate:local".into(),
        merge: "auto".into(),
        merge_label: "automerge".into(),
        setup: String::new(),
        gate: String::new(),
        on_exhaust: "park".into(),
        conflict_worker: String::new(),
        brief_model: String::new(),
        adopt: true,
        max_inflight: u64::MAX,
        worker_timeout: 60,
        attach: String::new(),
        base: "main".into(),
        model,
        review_model,
        stages,
        repo,
        rs,
        state_dir,
    }
}

/// A fresh scratch directory under the system temp dir, unique to the test.
#[cfg(test)]
pub fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("bead-loop-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let _ = std::fs::create_dir_all(&d);
    d
}

/// `need NAME`: die when a tool the config asks for is not installed.
pub fn need(name: &str) {
    if !crate::util::have(name) {
        die(&format!("{name} is not installed"));
    }
}

/// origin's HEAD branch, from the clone's `refs/remotes/origin/HEAD`, else `git remote
/// show origin`; empty when neither says.
fn origin_head(repo: &Path) -> String {
    let o = crate::util::output(crate::util::cmd("git").args(["-C"]).arg(repo).args([
        "symbolic-ref",
        "-q",
        "--short",
        "refs/remotes/origin/HEAD",
    ]));
    if let Ok(o) = o {
        if o.status.success() {
            let s = crate::util::stdout_str(&o).trim().to_string();
            if let Some(b) = s.strip_prefix("origin/") {
                if !b.is_empty() {
                    return b.to_string();
                }
            }
        }
    }
    let o = crate::util::output(crate::util::cmd("git").args(["-C"]).arg(repo).args(["remote", "show", "origin"]));
    if let Ok(o) = o {
        for line in crate::util::stdout_str(&o).lines() {
            if let Some(b) = line.trim().strip_prefix("HEAD branch: ") {
                return b.trim().to_string();
            }
        }
    }
    String::new()
}

/// One lane: it takes the rounds whose model matches `models` (globs: `devbox/*`, or
/// `*` alone) and none of `exclude`, in the roles it has. `[[lanes]]` in the global
/// config; without it, the pair the loop always had — `dev` (worker rounds) and `review`
/// (reviewer rounds) — plus a `claude` lane when a stage names `claude/*`.
///
/// ```toml
/// [[lanes]]
/// name = "gpu"
/// models = ["devbox/*"]
/// [[lanes]]
/// name = "cpu"
/// models = ["acbox/*"]       # roles = ["worker", "reviewer"] is the default
/// [[lanes]]
/// name = "claude"
/// models = ["claude/*"]
/// ```
#[derive(Clone, Debug, PartialEq)]
pub struct LaneSpec {
    pub name: String,
    pub models: Vec<String>,
    pub exclude: Vec<String>,
    pub worker: bool,
    pub reviewer: bool,
    /// the first lane: it also parks a bead whose stages are exhausted
    pub parks: bool,
    /// the first lane with the reviewer role: it also takes a round with no reviewer
    /// (straight to PR), which names no model for a pattern to match
    pub fallback: bool,
}

pub fn glob_match(pat: &str, s: &str) -> bool {
    if pat == "*" {
        true
    } else if let Some(p) = pat.strip_suffix('*') {
        s.starts_with(p)
    } else {
        pat == s
    }
}

impl LaneSpec {
    pub fn takes(&self, model: &str) -> bool {
        self.models.iter().any(|p| glob_match(p, model)) && !self.exclude.iter().any(|p| glob_match(p, model))
    }
}

impl Layers {
    /// The lanes, from `[[lanes]]` in the global file, else the defaults.
    pub fn lanes(&self, has_claude: bool) -> Vec<LaneSpec> {
        if let Some(Value::Array(a)) = self.global.get("lanes") {
            if !a.is_empty() {
                let mut first_reviewer = true;
                return a
                    .iter()
                    .enumerate()
                    .map(|(i, l)| {
                        let strs = |k: &str| -> Vec<String> {
                            match l.get(k) {
                                Some(Value::Array(v)) => v.iter().filter_map(|s| s.as_str()).map(str::to_string).collect(),
                                Some(Value::String(s)) => vec![s.clone()],
                                _ => Vec::new(),
                            }
                        };
                        let roles = strs("roles");
                        let worker = roles.is_empty() || roles.iter().any(|r| r == "worker");
                        let reviewer = roles.is_empty() || roles.iter().any(|r| r == "reviewer");
                        let fallback = reviewer && first_reviewer;
                        if reviewer {
                            first_reviewer = false;
                        }
                        let mut models = strs("models");
                        if models.is_empty() {
                            models.push("*".into());
                        }
                        LaneSpec {
                            name: l.get("name").and_then(|n| n.as_str()).unwrap_or(&format!("lane{}", i + 1)).to_string(),
                            models,
                            exclude: strs("exclude"),
                            worker,
                            reviewer,
                            parks: i == 0,
                            fallback,
                        }
                    })
                    .collect();
            }
        }
        let exclude: Vec<String> = if has_claude { vec!["claude/*".into()] } else { Vec::new() };
        let mut v = vec![
            LaneSpec {
                name: "dev".into(),
                models: vec!["*".into()],
                exclude: exclude.clone(),
                worker: true,
                reviewer: false,
                parks: true,
                fallback: false,
            },
            LaneSpec {
                name: "review".into(),
                models: vec!["*".into()],
                exclude,
                worker: false,
                reviewer: true,
                parks: false,
                fallback: true,
            },
        ];
        if has_claude {
            v.push(LaneSpec {
                name: "claude".into(),
                models: vec!["claude/*".into()],
                exclude: Vec::new(),
                worker: true,
                reviewer: true,
                parks: false,
                fallback: false,
            });
        }
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lanes_default_and_from_toml() {
        let l = layers("", "");
        let names: Vec<String> = l.lanes(true).into_iter().map(|s| s.name).collect();
        assert_eq!(names, ["dev", "review", "claude"]);
        assert_eq!(l.lanes(false).len(), 2);
        assert!(!l.lanes(true)[0].takes("claude/opus") && l.lanes(true)[0].takes("devbox/coder"));
        let l = layers(
            "[[lanes]]\nname = \"gpu\"\nmodels = [\"devbox/*\"]\n[[lanes]]\nname = \"cpu\"\nmodels = [\"acbox/*\"]\nroles = [\"worker\"]",
            "",
        );
        let v = l.lanes(true);
        assert_eq!(v.len(), 2, "[[lanes]] replaces the defaults, claude lane included");
        assert!(v[0].takes("devbox/coder") && !v[0].takes("acbox/coder") && v[0].parks && v[0].reviewer && v[0].fallback);
        assert!(v[1].worker && !v[1].reviewer && !v[1].fallback);
        assert!(glob_match("*", "anything") && glob_match("a/*", "a/b") && !glob_match("a/b", "a/c"));
    }

    fn layers(global: &str, repo: &str) -> Layers {
        let g: toml::Table = global.parse().unwrap();
        let r: toml::Table = repo.parse().unwrap();
        Layers { global: serde_json::to_value(g).unwrap(), repo: serde_json::to_value(r).unwrap() }
    }

    #[test]
    fn repo_wins_over_global_over_default() {
        let l = layers("model = \"g\"\nmax_inflight = 3", "model = \"r\"");
        assert_eq!(l.str("model", "d"), "r");
        assert_eq!(l.u64("max_inflight", 1), 3);
        assert_eq!(l.str("gate", "none"), "none");
    }

    #[test]
    fn attempts_is_an_alias_of_failures() {
        let l =
            layers("[[stages]]\nworker = \"a\"\nattempts = 2\n[[stages]]\nworker = \"b\"\nreviewer = \"c\"\nfailures = 1\ntimeout = 7", "");
        let s = l.stages();
        assert_eq!(s[0].failures, 2);
        assert_eq!(s[0].reviewer, "");
        assert_eq!(s[1].timeout, Some(7));
        assert_eq!((s[1].worker.as_str(), s[1].reviewer.as_str(), s[1].failures), ("b", "c", 1));
    }

    #[test]
    fn repo_stages_replace_global_stages() {
        let l = layers("[[stages]]\nworker = \"g\"", "[[stages]]\nworker = \"r\"");
        assert_eq!(l.stages()[0].worker, "r");
        assert_eq!(l.stages().len(), 1);
    }

    #[test]
    fn a_stage_without_a_count_takes_one() {
        let l = layers("[[stages]]\nworker = \"a\"", "");
        assert_eq!(l.stages()[0].failures, 1);
    }

    #[test]
    fn scalars_read_as_yq_printed_them() {
        let l = layers("adopt = \"false\"\nmax_inflight = \"2\"\ngate = true\nrepos = [\"a\", \"b\"]", "");
        assert!(!l.bool("adopt", true), "a quoted false is false");
        assert_eq!(l.u64("max_inflight", 9), 2, "a quoted number is a number");
        assert_eq!(l.str("gate", ""), "true", "a bare true prints as true");
        assert_eq!(l.str("repos", ""), "a b", "an array joins by spaces");
        assert_eq!(l.u64("nope", 7), 7);
        assert!(l.bool("nope", true));
    }

    #[test]
    fn a_config_file_parses_or_says_why() {
        let d = scratch("toml");
        let f = d.join("c.toml");
        assert_eq!(parse_toml(&f).unwrap(), serde_json::json!({}), "an absent file is empty");
        std::fs::write(&f, "  \n").unwrap();
        assert_eq!(parse_toml(&f).unwrap(), serde_json::json!({}), "an empty file is empty");
        std::fs::write(&f, "gate = 'true'   # trailing comment\nmerge = \"auto\"\n").unwrap();
        let v = parse_toml(&f).unwrap();
        assert_eq!(v["gate"], "true", "a trailing comment is not part of the value");
        assert_eq!(v["merge"], "auto");
        std::fs::write(&f, "gate = \"unterminated\n").unwrap();
        let err = parse_toml(&f).unwrap_err();
        assert!(err.starts_with(&f.display().to_string()), "the error names the file: {err}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn attempts_carry_over_into_failures() {
        // The older attempts/ counter moves into failures/ file by file, even when
        // failures/ already exists, and the old directory goes.
        let d = scratch("attempts");
        let rs = d.join("rs");
        std::fs::create_dir_all(rs.join("attempts")).unwrap();
        std::fs::create_dir_all(rs.join("failures")).unwrap();
        std::fs::write(rs.join("attempts/t-1"), "2\n").unwrap();
        std::fs::write(rs.join("attempts/t-1.notes"), "round 1 (x): y\n").unwrap();
        std::fs::write(rs.join("attempts/t-9"), "1\n").unwrap();
        std::fs::write(rs.join("failures/t-9"), "5\n").unwrap();
        make_state_dirs(&rs);
        assert_eq!(std::fs::read_to_string(rs.join("failures/t-1")).unwrap(), "2\n");
        assert_eq!(std::fs::read_to_string(rs.join("failures/t-1.notes")).unwrap(), "round 1 (x): y\n", "the history too");
        assert_eq!(std::fs::read_to_string(rs.join("failures/t-9")).unwrap(), "5\n", "an existing counter is not overwritten");
        assert!(!rs.join("attempts").exists(), "attempts/ gone");
        for sub in ["inflight", "logs", "wt", "review", "failures", "held", "rejoin"] {
            assert!(rs.join(sub).is_dir(), "{sub}/ made");
        }
        let _ = std::fs::remove_dir_all(&d);
    }
}

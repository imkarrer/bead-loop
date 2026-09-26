//! Two TOML files, every key optional: the global `~/.config/bead-loop/config.toml` and
//! the repo's `.bead-loop.toml`. A key in the repo file wins over the global one; the
//! global one wins over the default. A file that does not parse stops the run with its
//! name. `Repo` is what the bash's `load_repo` left in its variables: everything a round
//! needs to know about one repo, read afresh every time (so a config edit takes effect on
//! the next round).
use crate::util::{die, expand_tilde, home};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// One `[[stages]]` table: a stage takes the bead for the next `failures` send-backs.
#[derive(Clone, Debug, PartialEq)]
pub struct Stage {
    pub name: String,
    pub worker: String,
    pub reviewer: String,
    pub failures: u64,
    pub timeout: Option<u64>,
    pub seats: Vec<Seat>,
    pub approvals: Approvals,
}

/// One reviewer seat: a model, and the agent identity it reviews as (`""` is
/// bead-reviewer).
#[derive(Clone, Debug, PartialEq)]
pub struct Seat {
    pub model: String,
    pub agent: String,
}

/// How many of a stage's seats must approve: every one, any one, or at least N.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Approvals {
    #[default]
    All,
    Any,
    Count(u64),
}

/// The two files as JSON objects.
#[derive(Clone, Debug)]
pub struct Layers {
    pub global: Value,
    pub repo: Value,
}

/// One `[targets.NAME]` table: a checkout the round works in and the GitHub repo its PR
/// goes to, named by a bead's `work:NAME` label (docs/design-targets.md). Every field but
/// `name` and `path` is `None` when the target does not set it, so `Repo::for_bead` can
/// tell "the target says so" from "inherit the beads repo's".
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Target {
    pub name: String,
    pub path: PathBuf,
    pub base: Option<String>,
    pub base_remote: Option<String>,
    pub push_remote: Option<String>,
    pub pr_repo: Option<String>,
    pub setup: Option<String>,
    pub gate: Option<String>,
    pub merge: Option<String>,
    pub merge_label: Option<String>,
    pub adopt: Option<bool>,
    pub max_inflight: Option<u64>,
    pub open_pr: Option<String>,
    pub pr_style: Option<String>,
}

/// One `[providers.NAME]` table in the global file: a model endpoint — how its sessions
/// run, how many at once, what they cost (docs/design-providers.md, "Providers"). A model
/// is `NAME/model`; a model naming no table gets an implicit one (`Provider::implicit`).
#[derive(Clone, Debug, PartialEq)]
pub struct Provider {
    pub name: String,
    /// `opencode` · `claude-code` · `aider` · `command`
    pub harness: String,
    pub parallel: u64,
    /// `local` · `metered`
    pub cost: String,
    pub probe: String,
    /// for `aider`: the opencode provider whose baseURL and key it speaks to
    pub via: String,
    pub attach: String,
    pub command: String,
    pub model_flag: String,
}

impl Provider {
    /// The provider a model gets when no `[providers.NAME]` names it: `claude` is the
    /// Claude Code subscription, anything else an opencode provider, one slot, local.
    pub fn implicit(name: &str) -> Provider {
        let claude = name == "claude";
        Provider {
            name: name.to_string(),
            harness: if claude { "claude-code" } else { "opencode" }.into(),
            parallel: 1,
            cost: if claude { "metered" } else { "local" }.into(),
            probe: String::new(),
            via: String::new(),
            attach: String::new(),
            command: String::new(),
            model_flag: String::new(),
        }
    }
}

/// A model name resolved: its provider, the harness its session runs under, and the
/// model as that harness wants it spelled.
#[derive(Clone, Debug, PartialEq)]
pub struct Resolved {
    pub provider: Provider,
    pub harness: String,
    pub model: String,
}

/// The provider a model names: the text before the first `/`, after an `aider:` prefix
/// is stripped; the whole string when there is no `/`. `aider:devbox/coder` is devbox's:
/// the prefix picks a harness, not a server.
pub fn provider_name(model: &str) -> &str {
    let m = model.strip_prefix("aider:").unwrap_or(model);
    m.split('/').next().unwrap_or(m)
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

/// `reviewer`: a string (one seat; `""` is none), an array of model strings, or an array
/// mixing those with `{ model = "...", agent = "..." }` tables.
fn parse_seats(v: &Value) -> Vec<Seat> {
    match v {
        Value::String(s) if s.is_empty() => Vec::new(),
        Value::String(s) => vec![Seat { model: s.clone(), agent: String::new() }],
        Value::Array(a) => a
            .iter()
            .map(|item| match item {
                Value::Object(_) => Seat {
                    model: item.get("model").map(scalar).unwrap_or_default(),
                    agent: item.get("agent").map(scalar).unwrap_or_default(),
                },
                _ => Seat { model: scalar(item), agent: String::new() },
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// `approvals`: "all" | "any" | a number (or a numeric string); absent is All.
fn parse_approvals(v: Option<&Value>) -> Approvals {
    match v {
        Some(Value::String(s)) if s == "any" => Approvals::Any,
        Some(Value::String(s)) if s == "all" => Approvals::All,
        Some(Value::String(s)) => s.trim().parse().map(Approvals::Count).unwrap_or_default(),
        Some(Value::Number(n)) => n.as_u64().map(Approvals::Count).unwrap_or_default(),
        _ => Approvals::All,
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
            .enumerate()
            .map(|(i, s)| {
                let seats = s.get("reviewer").map(parse_seats).unwrap_or_default();
                Stage {
                    name: s.get("name").map(scalar).unwrap_or_else(|| (i + 1).to_string()),
                    worker: s.get("worker").map(scalar).unwrap_or_default(),
                    reviewer: seats.first().map(|seat| seat.model.clone()).unwrap_or_default(),
                    failures: s
                        .get("failures")
                        .or_else(|| s.get("attempts"))
                        .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|t| t.parse().ok())))
                        .unwrap_or(1),
                    timeout: s.get("timeout").and_then(|v| v.as_u64()),
                    approvals: parse_approvals(s.get("approvals")),
                    seats,
                }
            })
            .collect()
    }

    /// `[providers.NAME]` tables, global file only: providers describe the machine, not the
    /// repo. A harness or cost the loop does not know stops the run, naming the provider.
    pub fn providers(&self) -> Vec<Provider> {
        self.try_providers().unwrap_or_else(|e| die(&e))
    }

    pub fn try_providers(&self) -> Result<Vec<Provider>, String> {
        let Some(Value::Object(map)) = self.global.get("providers") else { return Ok(Vec::new()) };
        let mut out = Vec::new();
        for (name, v) in map {
            let Value::Object(_) = v else { continue };
            let mut p = Provider::implicit(name);
            let s = |k: &str| v.get(k).map(scalar);
            if let Some(h) = s("harness") {
                if !["opencode", "claude-code", "aider", "command"].contains(&h.as_str()) {
                    return Err(format!("[providers.{name}]: harness = \"{h}\": one of opencode, claude-code, aider, command"));
                }
                p.harness = h;
            }
            if let Some(c) = s("cost") {
                if c != "local" && c != "metered" {
                    return Err(format!("[providers.{name}]: cost = \"{c}\": local or metered"));
                }
                p.cost = c;
            }
            if let Some(n) = v.get("parallel").and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|t| t.trim().parse().ok()))) {
                p.parallel = n.max(1);
            }
            p.probe = s("probe").unwrap_or_default();
            p.via = s("via").unwrap_or_default();
            p.attach = s("attach").unwrap_or_default();
            p.command = s("command").unwrap_or_default();
            p.model_flag = s("model_flag").unwrap_or_default();
            out.push(p);
        }
        Ok(out)
    }

    /// `[targets.NAME]` tables, repo file only — a target's configuration lives beside the
    /// beads it comes from, never in the global file.
    pub fn targets(&self) -> BTreeMap<String, Target> {
        let mut out = BTreeMap::new();
        if let Some(Value::Object(map)) = self.repo.get("targets") {
            for (name, v) in map {
                let Value::Object(_) = v else { continue };
                out.insert(
                    name.clone(),
                    Target {
                        name: name.clone(),
                        path: v.get("path").and_then(|p| p.as_str()).map(expand_tilde).unwrap_or_default(),
                        base: v.get("base").map(scalar),
                        base_remote: v.get("base_remote").map(scalar),
                        push_remote: v.get("push_remote").map(scalar),
                        pr_repo: v.get("pr_repo").map(scalar),
                        setup: v.get("setup").map(scalar),
                        gate: v.get("gate").map(scalar),
                        merge: v.get("merge").map(scalar),
                        merge_label: v.get("merge_label").map(scalar),
                        adopt: v.get("adopt").and_then(|x| match x {
                            Value::Bool(b) => Some(*b),
                            Value::String(s) => Some(s == "true"),
                            _ => None,
                        }),
                        max_inflight: v
                            .get("max_inflight")
                            .and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))),
                        open_pr: v.get("open_pr").map(scalar),
                        pr_style: v.get("pr_style").map(scalar),
                    },
                );
            }
        }
        out
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
#[derive(Clone, Debug, PartialEq)]
pub struct Repo {
    /// the checkout a round works in: the beads repo itself for the default target,
    /// a `[targets.NAME]` path after `for_bead` resolves a `work:NAME` label
    pub repo: PathBuf,
    /// where `bd` runs and `.bead-loop.toml` lives — the beads repo's own path, always;
    /// `for_bead` never changes it
    pub beads: PathBuf,
    /// `""` for the default target (the beads repo itself), else the `[targets.NAME]` name
    /// `for_bead` resolved to
    pub target: String,
    /// the `[targets.NAME]` tables from the beads repo's `.bead-loop.toml`
    pub targets: BTreeMap<String, Target>,
    /// the label prefix that names a target (config key `target_label`, default `"work"`)
    pub target_label: String,
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
    /// who pre-checks a round's diff before the senior reviewer sees it; `""` is off
    pub precheck_model: String,
    /// who writes the research brief before a bead's worker round; `""` is off
    pub research_model: String,
    /// `first` (once, before round 1) or `every` (again after each send-back)
    pub research: String,
    /// seconds a research round may run (capped by the stage's timeout); default 900
    pub research_timeout: u64,
    /// the `[providers.NAME]` tables of the global file
    pub providers: Vec<Provider>,
    pub adopt: bool,
    pub max_inflight: u64,
    pub worker_timeout: u64,
    /// opencode sessions only: past this many compaction events, the watchdog aborts the
    /// session as stalled — a read/compaction loop the model never broke out of on its
    /// own. `0` disables the check (bl-uhl)
    pub stall_compactions: u64,
    /// opencode sessions only: past this many tool calls since the last edit/write/patch
    /// call, the watchdog aborts the session as stalled. `0` disables the check (bl-uhl)
    pub stall_steps: u64,
    pub attach: String,
    pub base: String,
    /// where `bead/*` branches fork from and PR into; default `origin` — for a target,
    /// `upstream` when that remote exists there, else `origin`
    pub base_remote: String,
    /// where `bead/*` branches are pushed; default `origin`
    pub push_remote: String,
    /// `owner/repo` the PR is opened against; default `base_remote`'s GitHub repo
    pub pr_repo: String,
    /// `auto` (the loop opens the PR) or `ask` (the operator publishes it); default `auto`
    pub open_pr: Option<String>,
    /// `loop` (today's `ID: title` / "Opened by bead-loop" PR) or `plain` (a contribution,
    /// no loop id or line); default `loop`
    pub pr_style: String,
    /// `$STATE_DIR/<slug>`
    pub rs: PathBuf,
    pub state_dir: PathBuf,
}

impl Repo {
    /// `load_repo REPO`, with the worker model flag (`--model M`) applied.
    pub fn load(path: &Path, model_flag: Option<&str>) -> Repo {
        let beads = match std::fs::canonicalize(path) {
            Ok(p) if p.is_dir() => p,
            _ => die(&format!("no such repo: {}", path.display())),
        };
        if !beads.join(".beads").is_dir() {
            die(&format!("{} has no .beads/", beads.display()));
        }
        let cfg = Layers::load(&config_dir().join("config.toml"), Some(&beads.join(".bead-loop.toml")));
        let slug = beads.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let model = model_flag.map(str::to_string).unwrap_or_else(|| cfg.str("model", ""));
        let review_model = cfg.str("review_model", "");
        let mut stages = cfg.stages();
        if stages.is_empty() {
            stages.push(Stage {
                name: "1".to_string(),
                worker: model.clone(),
                reviewer: review_model.clone(),
                failures: 3,
                timeout: None,
                seats: if review_model.is_empty() { Vec::new() } else { vec![Seat { model: review_model.clone(), agent: String::new() }] },
                approvals: Approvals::All,
            });
        }
        for s in &stages {
            if s.worker.is_empty() {
                die(&format!("{slug}: stage {} names no worker; set its worker, or model when there is no [[stages]]", s.name));
            }
        }
        let base_remote = cfg.str("base_remote", "origin");
        let mut base = cfg.str("base", "");
        if base.is_empty() {
            base = remote_head(&beads, &base_remote);
        }
        if base.is_empty() {
            die(&format!("{slug}: cannot tell the base branch; set base in .bead-loop.toml"));
        }
        let pr_repo = cfg.str("pr_repo", &remote_owner_repo(&beads, &base_remote));
        let state_dir = state_dir();
        let rs = state_dir.join(&slug);
        make_state_dirs(&rs);
        let r = Repo {
            label: cfg.str("label", "delegate:local"),
            merge: cfg.str("merge", "auto"),
            merge_label: cfg.str("merge_label", "automerge"),
            setup: cfg.str("setup", ""),
            gate: cfg.str("gate", ""),
            on_exhaust: cfg.str("on_exhaust", "park"),
            conflict_worker: cfg.str("conflict_worker", ""),
            brief_model: cfg.str("brief_model", ""),
            precheck_model: cfg.str("precheck_model", ""),
            research_model: cfg.str("research_model", ""),
            research: cfg.str("research", "first"),
            research_timeout: cfg.u64("research_timeout", 900),
            providers: cfg.providers(),
            adopt: cfg.bool("adopt", true),
            max_inflight: cfg.u64("max_inflight", u64::MAX),
            worker_timeout: cfg.u64("worker_timeout", 3600),
            stall_compactions: cfg.u64("stall_compactions", 10),
            stall_steps: cfg.u64("stall_steps", 60),
            attach: cfg.str("attach", ""),
            base_remote,
            push_remote: cfg.str("push_remote", "origin"),
            pr_repo,
            open_pr: cfg.get("open_pr").map(|v| v.as_str().unwrap_or("auto").to_string()),
            pr_style: cfg.str("pr_style", "loop"),
            target: String::new(),
            targets: cfg.targets(),
            target_label: cfg.str("target_label", "work"),
            model,
            review_model,
            stages,
            base,
            slug,
            repo: beads.clone(),
            beads,
            rs,
            state_dir,
        };
        for s in &r.stages {
            for m in std::iter::once(&s.worker).chain(s.seats.iter().map(|x| &x.model)) {
                match r.resolve(m).harness.as_str() {
                    "claude-code" => need("claude"),
                    "aider" => need("aider"),
                    _ => {}
                }
            }
        }
        r
    }

    /// The bead's `work:NAME`-style labels (prefix `target_label`) resolved against this
    /// beads repo's `[targets]`: no such label is the default target (a clone of `self`);
    /// exactly one is a clone with `repo` at the target's path and every key it sets
    /// layered over `self`'s (target > beads repo file > global > default — `self` already
    /// carries the last three); two, or one naming no `[targets]` entry, or a path that is
    /// not a directory, is a config mistake, named in the `Err`. The dev lane calls this at
    /// claim (bl-6hg, docs/design-targets.md); an `Err` holds the bead, no failure charged.
    pub fn for_bead(&self, labels: &[&str]) -> Result<Repo, String> {
        let prefix = format!("{}:", self.target_label);
        let names: Vec<&str> = labels.iter().filter_map(|l| l.strip_prefix(prefix.as_str())).collect();
        let name = match names.as_slice() {
            [] => return Ok(self.clone()),
            [name] => *name,
            _ => return Err(format!("more than one {prefix}* label: {}", names.join(", "))),
        };
        self.for_target(name, &prefix)
    }

    /// `for_id ID`: the target `dev_one` resolved and wrote to `$RS/target/ID` at claim
    /// (`state.rs target_of`), applied the same way `for_bead` does. Missing file, or a
    /// name no longer in `[targets]`, is the default target — so a bead already in flight
    /// when the config changes under it is unaffected, and this never errs.
    pub fn for_id(&self, id: &str) -> Repo {
        let name = self.target_of(id);
        if name.is_empty() {
            return self.clone();
        }
        let prefix = format!("{}:", self.target_label);
        self.for_target(&name, &prefix).unwrap_or_else(|_| self.clone())
    }

    /// Every target this beads repo configures, resolved, plus the default target
    /// (`self`) — for `adopt`, which asks GitHub about each distinct `pr_repo` once. A
    /// target whose path is missing or not configured right is skipped, not an error:
    /// `for_bead`/`for_id` already hold the beads that would resolve to it.
    pub fn target_repos(&self) -> Vec<Repo> {
        let prefix = format!("{}:", self.target_label);
        let mut v = vec![self.clone()];
        for name in self.targets.keys() {
            if let Ok(r) = self.for_target(name, &prefix) {
                v.push(r);
            }
        }
        v
    }

    /// The resolution `for_bead`/`for_id` share once a target NAME is known: apply
    /// `[targets.NAME]` over `self`, target's own key winning, an unset one inheriting.
    fn for_target(&self, name: &str, prefix: &str) -> Result<Repo, String> {
        let target = match self.targets.get(name) {
            Some(t) => t,
            None => return Err(format!("{prefix}{name}: no [targets.{name}] in .bead-loop.toml")),
        };
        if !target.path.is_dir() {
            return Err(format!("{prefix}{name}: {} is not a directory", target.path.display()));
        }
        let path = match std::fs::canonicalize(&target.path) {
            Ok(p) => p,
            Err(e) => return Err(format!("{prefix}{name}: {e}")),
        };
        let base_remote =
            target
                .base_remote
                .clone()
                .unwrap_or_else(|| if remote_exists(&path, "upstream") { "upstream".into() } else { "origin".into() });
        let push_remote = target.push_remote.clone().unwrap_or_else(|| "origin".into());
        let pr_repo = target.pr_repo.clone().unwrap_or_else(|| remote_owner_repo(&path, &base_remote));
        let base = target.base.clone().unwrap_or_else(|| remote_head(&path, &base_remote));
        let mut r = self.clone();
        r.repo = path;
        r.target = name.to_string();
        r.base_remote = base_remote;
        r.push_remote = push_remote;
        r.pr_repo = pr_repo;
        r.base = base;
        r.setup = target.setup.clone().unwrap_or(r.setup);
        r.gate = target.gate.clone().unwrap_or(r.gate);
        r.merge = target.merge.clone().unwrap_or(r.merge);
        r.merge_label = target.merge_label.clone().unwrap_or(r.merge_label);
        r.adopt = target.adopt.unwrap_or(r.adopt);
        r.max_inflight = target.max_inflight.unwrap_or(r.max_inflight);
        r.open_pr = Some(resolve_open_pr(target.open_pr.as_deref(), &r.pr_repo, gh_login().as_deref()));
        r.pr_style = target.pr_style.clone().unwrap_or_else(|| {
            if r.open_pr.as_deref() == Some("ask") {
                "plain".to_string()
            } else {
                r.pr_style.clone()
            }
        });
        Ok(r)
    }

    /// `head_ref BRANCH`: what `gh pr create --head` / `pr list --head` takes for this
    /// branch. On our own repos the push remote's `owner/repo` (parsed from its url) is
    /// `pr_repo` itself, so the bare branch name is enough; pushing to a fork whose PR
    /// goes to someone else's repo needs `OWNER:BRANCH`, OWNER parsed the same way. A
    /// push remote whose url does not parse (a local path, in the test suite) is treated
    /// as matching — nothing to disambiguate with, so the bare branch stands.
    pub fn head_ref(&self, branch: &str) -> String {
        let push_owner_repo = remote_owner_repo(&self.repo, &self.push_remote);
        if push_owner_repo.is_empty() || push_owner_repo == self.pr_repo {
            return branch.to_string();
        }
        match push_owner_repo.split_once('/') {
            Some((owner, _)) => format!("{owner}:{branch}"),
            None => branch.to_string(),
        }
    }

    /// A model name as a provider, a harness and the name that harness takes. The
    /// provider is the `[providers.NAME]` table `provider_name` names, else the implicit
    /// one. `aider:P/M` is aider on P's server (`via` = P): the prefix overrides the
    /// harness, not the provider, so the round stays on P's lane. opencode takes `P/M`
    /// whole; claude-code, aider and a command take the `M` after the slash.
    pub fn resolve(&self, model: &str) -> Resolved {
        let name = provider_name(model);
        let provider = self.providers.iter().find(|p| p.name == name).cloned().unwrap_or_else(|| Provider::implicit(name));
        let bare = model.strip_prefix("aider:");
        let after_slash = |m: &str| m.split_once('/').map(|(_, m)| m.to_string()).unwrap_or_else(|| m.to_string());
        if let Some(m) = bare {
            let mut provider = provider;
            provider.via = name.to_string();
            return Resolved { provider, harness: "aider".into(), model: after_slash(m) };
        }
        let harness = provider.harness.clone();
        let model = if harness == "opencode" { model.to_string() } else { after_slash(model) };
        Resolved { provider, harness, model }
    }
}

/// The repo's state directories, and the older layouts carried into `beads/ID/` file by
/// file, then gone: `failures/` and `research/`, then the oldest, `attempts/`.
///
/// A file still under `failures/` or `research/` was written by an older loop than the
/// one running this — in a deploy, the old process until its restart, while a status
/// run of the new binary has already moved the rest — so it is the newer copy: it
/// replaces the one under `beads/ID/`, and a history is appended to rather than replaced.
/// `attempts/` is older than everything: its counter goes only where there is none.
pub fn make_state_dirs(rs: &Path) {
    for d in ["inflight", "logs", "wt", "review", "beads", "held", "parked", "rejoin", "target", "proposed"] {
        let _ = std::fs::create_dir_all(rs.join(d));
    }
    carry_into_beads(rs, "failures", failures_file, true);
    carry_into_beads(rs, "research", research_file, true);
    carry_into_beads(rs, "attempts", failures_file, false);
    let _ = std::fs::remove_dir_all(rs.join("attempts"));
}

/// `failures/NAME` (and `attempts/NAME`): the bead and its file under `beads/ID/`.
fn failures_file(name: &str) -> (&str, &'static str) {
    if let Some(id) = name.strip_suffix(".rounds.jsonl") {
        (id, "rounds.jsonl")
    } else if let Some(id) = name.strip_suffix(".notes") {
        (id, "notes")
    } else {
        (name, "failures")
    }
}

/// `research/NAME`: the bead and its file under `beads/ID/`.
fn research_file(name: &str) -> (&str, &'static str) {
    match name.strip_suffix(".prev") {
        Some(id) => (id, "brief.prev"),
        None => (name, "brief"),
    }
}

/// Each file of `rs/DIR` to `rs/beads/ID/FILE`, `place` naming both; `newer`, it replaces
/// the one there (a history appended to it), else it goes only where there is none.
/// The emptied directory goes.
fn carry_into_beads(rs: &Path, dir: &str, place: fn(&str) -> (&str, &'static str), newer: bool) {
    let old = rs.join(dir);
    let Ok(rd) = std::fs::read_dir(&old) else { return };
    for e in rd.flatten() {
        let Ok(name) = e.file_name().into_string() else { continue };
        let (id, file) = place(&name);
        let dst = rs.join("beads").join(id).join(file);
        if dst.exists() && !newer {
            continue;
        }
        let _ = std::fs::create_dir_all(rs.join("beads").join(id));
        if dst.exists() && file == "rounds.jsonl" {
            if let Ok(s) = std::fs::read_to_string(e.path()) {
                crate::util::append_file(&dst, &s);
                let _ = std::fs::remove_file(e.path());
            }
        } else {
            let _ = std::fs::rename(e.path(), &dst);
        }
    }
    let _ = std::fs::remove_dir(&old);
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
        .enumerate()
        .map(|(i, s)| {
            let mut it = s.split(':');
            let worker = it.next().unwrap_or("").to_string();
            let reviewer = it.next().unwrap_or("").to_string();
            let failures = it.next().and_then(|n| n.parse().ok()).unwrap_or(1);
            Stage {
                name: (i + 1).to_string(),
                seats: if reviewer.is_empty() { Vec::new() } else { vec![Seat { model: reviewer.clone(), agent: String::new() }] },
                worker,
                reviewer,
                failures,
                timeout: None,
                approvals: Approvals::All,
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
        precheck_model: String::new(),
        research_model: String::new(),
        research: "first".into(),
        research_timeout: 900,
        providers: Vec::new(),
        adopt: true,
        max_inflight: u64::MAX,
        worker_timeout: 60,
        stall_compactions: 10,
        stall_steps: 60,
        attach: String::new(),
        base: "main".into(),
        base_remote: "origin".into(),
        push_remote: "origin".into(),
        pr_repo: String::new(),
        open_pr: Some("auto".to_string()),
        pr_style: "loop".into(),
        target: String::new(),
        targets: BTreeMap::new(),
        target_label: "work".into(),
        model,
        review_model,
        stages,
        beads: repo.clone(),
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

/// REMOTE's HEAD branch, from the clone's `refs/remotes/REMOTE/HEAD`, else `git remote
/// show REMOTE`; empty when neither says.
fn remote_head(repo: &Path, remote: &str) -> String {
    let o = crate::util::output(crate::util::cmd("git").args(["-C"]).arg(repo).args([
        "symbolic-ref",
        "-q",
        "--short",
        &format!("refs/remotes/{remote}/HEAD"),
    ]));
    if let Ok(o) = o {
        if o.status.success() {
            let s = crate::util::stdout_str(&o).trim().to_string();
            if let Some(b) = s.strip_prefix(&format!("{remote}/")) {
                if !b.is_empty() {
                    return b.to_string();
                }
            }
        }
    }
    let o = crate::util::output(crate::util::cmd("git").args(["-C"]).arg(repo).args(["remote", "show", remote]));
    if let Ok(o) = o {
        for line in crate::util::stdout_str(&o).lines() {
            if let Some(b) = line.trim().strip_prefix("HEAD branch: ") {
                return b.trim().to_string();
            }
        }
    }
    String::new()
}

/// `git -C DIR remote get-url NAME` succeeds: whether that remote exists.
fn remote_exists(dir: &Path, name: &str) -> bool {
    crate::util::output(crate::util::cmd("git").args(["-C"]).arg(dir).args(["remote", "get-url", name]))
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// REMOTE's `owner/repo`, parsed from `git -C DIR remote get-url REMOTE`; empty when the
/// remote is absent or its url does not parse.
fn remote_owner_repo(dir: &Path, remote: &str) -> String {
    match crate::util::output(crate::util::cmd("git").args(["-C"]).arg(dir).args(["remote", "get-url", remote])) {
        Ok(o) if o.status.success() => owner_repo(crate::util::stdout_str(&o).trim()).unwrap_or_default(),
        _ => String::new(),
    }
}

/// This process's `gh api user -q .login`, cached after the first call — a target whose
/// `open_pr` is unset checks `pr_repo`'s owner against it. `None` on a failed call (no
/// `gh`, not logged in, no network); the caller treats that as a foreign owner.
fn gh_login() -> Option<String> {
    static LOGIN: OnceLock<Option<String>> = OnceLock::new();
    LOGIN
        .get_or_init(|| {
            let o = crate::util::output(crate::util::cmd("gh").args(["api", "user", "-q", ".login"])).ok()?;
            if !o.status.success() {
                return None;
            }
            let login = crate::util::stdout_str(&o).trim().to_string();
            (!login.is_empty()).then_some(login)
        })
        .clone()
}

/// A target's resolved `open_pr`: EXPLICIT when the target sets it; otherwise "auto"
/// when `pr_repo`'s owner is LOGIN, "ask" otherwise — so the loop never opens a PR on
/// someone else's repo unasked. LOGIN `None` (a failed `gh` lookup) also means "ask".
fn resolve_open_pr(explicit: Option<&str>, pr_repo: &str, login: Option<&str>) -> String {
    if let Some(v) = explicit {
        return v.to_string();
    }
    let owner = pr_repo.split('/').next().unwrap_or("");
    if !owner.is_empty() && login == Some(owner) { "auto" } else { "ask" }.to_string()
}

/// `owner/repo` out of a git remote url, ssh (`git@host:owner/repo.git`) or https
/// (`https://host/owner/repo.git`); `None` when the shape does not match either.
fn owner_repo(url: &str) -> Option<String> {
    let path = if let Some(rest) = url.strip_prefix("git@") {
        rest.split_once(':').map(|(_, p)| p)?
    } else {
        let idx = url.find("://")?;
        url[idx + 3..].split_once('/').map(|(_, p)| p)?
    };
    let path = path.strip_suffix(".git").unwrap_or(path).trim_matches('/');
    let (rest, repo) = path.rsplit_once('/')?;
    let owner = rest.rsplit('/').next()?;
    if owner.is_empty() || repo.is_empty() {
        return None;
    }
    Some(format!("{owner}/{repo}"))
}

/// One lane: it takes the rounds whose model matches `models` (globs: `devbox/*`, or
/// `*` alone) and none of `exclude`, in the roles it has. `[[lanes]]` in the global
/// config; without it, one lane per provider the stages name (docs/design-providers.md,
/// "Lanes: derived by default").
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
    /// the slot's name: the lane's for slot 1, `NAME.K` for slot K (`slots`)
    pub name: String,
    /// the lane's name, whichever slot this is: the pause flag goes by it
    pub lane: String,
    /// how many rounds the lane runs at once, each in a slot of its own (`slots`)
    pub parallel: u64,
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
        // an aider round runs on its provider's server: the same lane as its opencode rounds
        let model = model.strip_prefix("aider:").unwrap_or(model);
        self.models.iter().any(|p| glob_match(p, model)) && !self.exclude.iter().any(|p| glob_match(p, model))
    }

    /// The lane's slots, a thread each: slot 1 keeps the lane's name, slot K is `NAME.K`,
    /// so each has its own lock and marker (`lane.NAME.K`, one bead each). Every bead has
    /// its own worktree already, so two rounds of one lane never share a checkout.
    pub fn slots(&self) -> Vec<LaneSpec> {
        (1..=self.parallel.max(1))
            .map(|k| LaneSpec { name: if k == 1 { self.name.clone() } else { format!("{}.{k}", self.name) }, ..self.clone() })
            .collect()
    }
}

/// Every lane's slots, in lane order: what the loop runs a thread for.
pub fn slots_of(lanes: &[LaneSpec]) -> Vec<LaneSpec> {
    lanes.iter().flat_map(LaneSpec::slots).collect()
}

impl Layers {
    /// The lanes, from `[[lanes]]` in the global file, else one per provider in
    /// `providers` (lanes.rs `providers_named`), in that order: `NAME/*`, both roles, the
    /// first one parking and taking the rounds with no reviewer.
    pub fn lanes(&self, providers: &[String]) -> Vec<LaneSpec> {
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
                        let name = l.get("name").and_then(|n| n.as_str()).unwrap_or(&format!("lane{}", i + 1)).to_string();
                        LaneSpec {
                            lane: name.clone(),
                            name,
                            parallel: l.get("parallel").and_then(|p| p.as_u64()).unwrap_or(1).max(1),
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
        // a derived lane is as wide as its provider's `parallel`
        let tables = self.try_providers().unwrap_or_default();
        let width = |p: &str| tables.iter().find(|t| t.name == p).map(|t| t.parallel).unwrap_or(1);
        let mut v: Vec<LaneSpec> = providers
            .iter()
            .enumerate()
            .map(|(i, p)| LaneSpec {
                name: p.clone(),
                lane: p.clone(),
                parallel: width(p),
                models: vec![format!("{p}/*"), p.clone()],
                exclude: Vec::new(),
                worker: true,
                reviewer: true,
                parks: i == 0,
                fallback: i == 0,
            })
            .collect();
        if v.is_empty() {
            // no provider given (a command that runs no lane; main.rs passes none): one lane for all
            v.push(LaneSpec {
                name: "dev".into(),
                lane: "dev".into(),
                parallel: 1,
                models: vec!["*".into()],
                exclude: Vec::new(),
                worker: true,
                reviewer: true,
                parks: true,
                fallback: true,
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
        let v = l.lanes(&[]);
        assert_eq!(v.len(), 1, "no provider named: one lane for everything");
        assert!(v[0].takes("anything/at-all") && v[0].worker && v[0].reviewer && v[0].parks && v[0].fallback);
        let l = layers(
            "[[lanes]]\nname = \"gpu\"\nmodels = [\"devbox/*\"]\n[[lanes]]\nname = \"cpu\"\nmodels = [\"acbox/*\"]\nroles = [\"worker\"]",
            "",
        );
        let v = l.lanes(&["claude".into()]);
        assert_eq!(v.len(), 2, "[[lanes]] replaces the defaults, claude lane included");
        assert!(v[0].takes("devbox/coder") && !v[0].takes("acbox/coder") && v[0].parks && v[0].reviewer && v[0].fallback);
        assert!(v[1].worker && !v[1].reviewer && !v[1].fallback);
        let v = layers("[[lanes]]\nname = \"claude\"\nmodels = [\"claude/*\"]\nparallel = 2\n[[lanes]]\nname = \"gpu\"", "").lanes(&[]);
        assert_eq!((v[0].parallel, v[1].parallel), (2, 1), "parallel from [[lanes]]; unset, 1");
        let slots = slots_of(&v);
        let names: Vec<&str> = slots.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["claude", "claude.2", "gpu"], "slot 1 keeps the lane's name");
        assert!(slots[1].lane == "claude" && slots[1].takes("claude/sonnet"), "a slot is its lane under another name");
        assert!(glob_match("*", "anything") && glob_match("a/*", "a/b") && !glob_match("a/b", "a/c"));
    }

    #[test]
    fn lanes_derive_from_the_providers_named() {
        let l = layers("", "");
        let v = l.lanes(&["devbox".into(), "claude".into()]);
        let names: Vec<&str> = v.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["devbox", "claude"], "one lane per provider, in the order given");
        assert!(v[0].takes("devbox/coder") && !v[0].takes("claude/opus") && v[1].takes("claude/opus"));
        assert!(v.iter().all(|s| s.worker && s.reviewer), "both roles");
        assert!(v[0].parks && v[0].fallback && !v[1].parks && !v[1].fallback, "the first parks and takes no-reviewer rounds");
        assert!(!v[0].takes(""), "no lane takes a round with no model: a stage with no worker stops the run (Repo::load)");
        let v = l.lanes(&["stub".into()]);
        assert!(v[0].takes("aider:stub/x"), "an aider round is on its provider's lane");
        assert_eq!(v[0].parallel, 1, "one slot by default");
        let v = layers("[providers.claude]\nparallel = 2", "").lanes(&["devbox".into(), "claude".into()]);
        assert_eq!((v[0].parallel, v[1].parallel), (1, 2), "as wide as the provider's parallel");
        let l = layers("[[lanes]]\nname = \"all\"\nmodels = [\"*\"]", "");
        let names: Vec<String> = l.lanes(&["devbox".into(), "claude".into()]).into_iter().map(|s| s.name).collect();
        assert_eq!(names, ["all"], "[[lanes]] still replaces the derived ones");
    }

    fn layers(global: &str, repo: &str) -> Layers {
        let g: toml::Table = global.parse().unwrap();
        let r: toml::Table = repo.parse().unwrap();
        Layers { global: serde_json::to_value(g).unwrap(), repo: serde_json::to_value(r).unwrap() }
    }

    #[test]
    fn providers_parse_and_default() {
        let l = layers(
            "[providers.claude]\nharness = \"claude-code\"\nparallel = 2\ncost = \"metered\"\n[providers.devbox]\nprobe = \"http://127.0.0.1:8100/health\"",
            "[providers.ignored]\nharness = \"aider\"",
        );
        let p = l.providers();
        assert_eq!(p.len(), 2, "the global file only: providers describe the machine");
        let claude = p.iter().find(|p| p.name == "claude").unwrap();
        assert_eq!((claude.harness.as_str(), claude.parallel, claude.cost.as_str()), ("claude-code", 2, "metered"));
        let devbox = p.iter().find(|p| p.name == "devbox").unwrap();
        assert_eq!(devbox.probe, "http://127.0.0.1:8100/health");
        assert_eq!((devbox.harness.as_str(), devbox.parallel, devbox.cost.as_str()), ("opencode", 1, "local"), "the defaults");
        assert!(devbox.via.is_empty() && devbox.command.is_empty() && devbox.attach.is_empty() && devbox.model_flag.is_empty());
        let err = layers("[providers.x]\nharness = \"ollama\"", "").try_providers().unwrap_err();
        assert!(err.contains("[providers.x]") && err.contains("ollama"), "names the provider and the harness: {err}");
        let err = layers("[providers.y]\ncost = \"free\"", "").try_providers().unwrap_err();
        assert!(err.contains("[providers.y]"), "an unknown cost too: {err}");
        assert!(layers("", "").providers().is_empty());
    }

    #[test]
    fn implicit_providers_keep_todays_spellings() {
        assert_eq!(provider_name("devbox/coder"), "devbox");
        assert_eq!(provider_name("aider:devbox/coder"), "devbox");
        assert_eq!(provider_name("claude/sonnet"), "claude");
        assert_eq!(provider_name("bare"), "bare", "no slash: the whole string");
        let c = Provider::implicit("claude");
        assert_eq!((c.harness.as_str(), c.cost.as_str(), c.parallel), ("claude-code", "metered", 1));
        let d = Provider::implicit("devbox");
        assert_eq!((d.harness.as_str(), d.cost.as_str(), d.parallel), ("opencode", "local", 1));
    }

    #[test]
    fn resolve_names_the_harness_and_the_model() {
        let d = scratch("resolve");
        let mut r = test_repo(&d, &["m"]);
        let x = r.resolve("devbox/coder");
        assert_eq!((x.provider.name.as_str(), x.harness.as_str(), x.model.as_str()), ("devbox", "opencode", "devbox/coder"));
        let x = r.resolve("claude/opus");
        assert_eq!((x.harness.as_str(), x.provider.cost.as_str(), x.model.as_str()), ("claude-code", "metered", "opus"));
        let x = r.resolve("aider:devbox/coder");
        assert_eq!((x.provider.name.as_str(), x.harness.as_str(), x.model.as_str()), ("devbox", "aider", "coder"));
        assert_eq!(x.provider.via, "devbox", "aider speaks to the provider it is prefixed onto");
        r.providers = layers("[providers.acbox]\nparallel = 3\ncost = \"metered\"", "").providers();
        let x = r.resolve("acbox/coder");
        assert_eq!((x.provider.parallel, x.provider.cost.as_str(), x.model.as_str()), (3, "metered", "acbox/coder"), "the table's");
        let _ = std::fs::remove_dir_all(&d);
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
    fn a_reviewer_string_is_one_seat() {
        let l = layers("[[stages]]\nworker = \"w\"\nreviewer = \"a/b\"", "");
        let s = &l.stages()[0];
        assert_eq!(s.seats, vec![Seat { model: "a/b".into(), agent: "".into() }]);
        assert_eq!(s.reviewer, "a/b");
    }

    #[test]
    fn seats_parse_models_and_tables() {
        let l = layers("[[stages]]\nworker = \"w\"\nreviewer = [\"a/x\", { model = \"b/y\", agent = \"bead-second\" }]\napprovals = 1", "");
        let s = &l.stages()[0];
        assert_eq!(
            s.seats,
            vec![Seat { model: "a/x".into(), agent: "".into() }, Seat { model: "b/y".into(), agent: "bead-second".into() }]
        );
        assert_eq!(s.reviewer, "a/x");
        assert_eq!(s.approvals, Approvals::Count(1));
        let l = layers("[[stages]]\nworker = \"w\"\nreviewer = \"a\"\napprovals = \"any\"", "");
        assert_eq!(l.stages()[0].approvals, Approvals::Any);
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
    fn older_layouts_carry_over_into_beads() {
        // failures/, research/ and the oldest attempts/ move into beads/ID/ file by file,
        // the ids with dots in them too, and the old directories go.
        let d = scratch("attempts");
        let rs = d.join("rs");
        for sub in ["attempts", "failures", "research", "beads/t-5"] {
            std::fs::create_dir_all(rs.join(sub)).unwrap();
        }
        let read = |p: &str| std::fs::read_to_string(rs.join(p)).unwrap();
        std::fs::write(rs.join("attempts/t-1"), "2\n").unwrap();
        std::fs::write(rs.join("attempts/t-1.notes"), "round 1 (x): y\n").unwrap();
        std::fs::write(rs.join("attempts/t-9"), "1\n").unwrap();
        std::fs::write(rs.join("failures/t-9"), "5\n").unwrap();
        std::fs::write(rs.join("failures/bl-3x2.2"), "3\n").unwrap();
        std::fs::write(rs.join("failures/bl-3x2.2.rounds.jsonl"), "{\"round\":1}\n").unwrap();
        std::fs::write(rs.join("research/bl-3x2.2"), "Files:\n- a\n").unwrap();
        std::fs::write(rs.join("research/bl-3x2.2.prev"), "old\n").unwrap();
        // what a new binary's status run moved, then the old process (until its restart)
        // wrote again: the old path is the newer copy
        std::fs::write(rs.join("beads/t-5/failures"), "1\n").unwrap();
        std::fs::write(rs.join("beads/t-5/rounds.jsonl"), "{\"round\":1}\n").unwrap();
        std::fs::write(rs.join("failures/t-5"), "2\n").unwrap();
        std::fs::write(rs.join("failures/t-5.rounds.jsonl"), "{\"round\":2}\n").unwrap();
        make_state_dirs(&rs);
        assert_eq!(read("beads/t-1/failures"), "2\n");
        assert_eq!(read("beads/t-1/notes"), "round 1 (x): y\n", "the history too");
        assert_eq!(read("beads/t-9/failures"), "5\n", "attempts/ never replaces a counter");
        assert_eq!(read("beads/bl-3x2.2/failures"), "3\n");
        assert_eq!(read("beads/bl-3x2.2/rounds.jsonl"), "{\"round\":1}\n");
        assert_eq!(read("beads/bl-3x2.2/brief"), "Files:\n- a\n");
        assert_eq!(read("beads/bl-3x2.2/brief.prev"), "old\n");
        assert_eq!(read("beads/t-5/failures"), "2\n", "the newer counter wins");
        assert_eq!(read("beads/t-5/rounds.jsonl"), "{\"round\":1}\n{\"round\":2}\n", "the newer round appended");
        for gone in ["attempts", "failures", "research"] {
            assert!(!rs.join(gone).exists(), "{gone}/ gone");
        }
        for sub in ["inflight", "logs", "wt", "review", "beads", "held", "rejoin"] {
            assert!(rs.join(sub).is_dir(), "{sub}/ made");
        }
        make_state_dirs(&rs);
        assert_eq!(read("beads/t-5/rounds.jsonl"), "{\"round\":1}\n{\"round\":2}\n", "a second run moves nothing");
        let _ = std::fs::remove_dir_all(&d);
    }

    fn git(dir: &Path, args: &[&str]) {
        assert!(std::process::Command::new("git").args(args).current_dir(dir).status().unwrap().success(), "git {args:?} in {dir:?}");
    }

    #[test]
    fn for_bead_with_no_target_label_is_the_default_target() {
        let d = scratch("target-none");
        let r = test_repo(&d, &["m"]);
        assert_eq!(r.for_bead(&[]).unwrap(), r);
        assert_eq!(r.for_bead(&["priority:high", "delegate:local"]).unwrap(), r, "no work: label among these");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn for_bead_resolves_a_configured_target() {
        let d = scratch("target-t");
        let checkout = d.join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        git(&checkout, &["init", "-q"]);
        // a local, unreachable path is enough: `remote_exists` only reads .git/config, and
        // `remote_head`'s fallback fails fast on a path that is not a repo, no network.
        git(&checkout, &["remote", "add", "upstream", d.join("nonexistent-upstream").to_str().unwrap()]);

        let mut r = test_repo(&d, &["m"]);
        r.targets.insert("t".into(), Target { name: "t".into(), path: checkout.clone(), ..Default::default() });

        let out = r.for_bead(&["work:t"]).unwrap();
        assert_eq!(out.repo, std::fs::canonicalize(&checkout).unwrap());
        assert_eq!(out.beads, r.beads, "beads unchanged");
        assert_eq!(out.base_remote, "upstream");
        assert_eq!(out.push_remote, "origin");
        assert_eq!(out.target, "t");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_target_key_overrides_the_repo_files_and_an_unset_one_inherits_it() {
        let d = scratch("target-override");
        let checkout = d.join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let mut r = test_repo(&d, &["m"]);
        r.gate = "repo gate".into();
        r.setup = "repo setup".into();
        r.targets.insert("t".into(), Target { name: "t".into(), path: checkout, gate: Some("target gate".into()), ..Default::default() });

        let out = r.for_bead(&["work:t"]).unwrap();
        assert_eq!(out.gate, "target gate", "the target's own key wins");
        assert_eq!(out.setup, "repo setup", "an unset target key inherits the repo's");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn open_pr_defaults_to_ask_for_a_foreign_pr_repo_owner() {
        assert_eq!(resolve_open_pr(None, "stubuser/x", Some("stubuser")), "auto", "pr_repo owner matches the login");
        assert_eq!(resolve_open_pr(None, "someone/x", Some("stubuser")), "ask", "pr_repo owner differs from the login");
        assert_eq!(resolve_open_pr(Some("auto"), "someone/x", Some("stubuser")), "auto", "an explicit setting wins");
    }

    #[test]
    fn for_bead_errs_on_two_labels_or_an_unconfigured_target() {
        let d = scratch("target-err");
        let r = test_repo(&d, &["m"]);
        let err = r.for_bead(&["work:t", "work:u"]).unwrap_err();
        assert!(err.contains("t, u"), "names both labels: {err}");
        let err = r.for_bead(&["work:nope"]).unwrap_err();
        assert!(err.contains("work:nope"), "names the label: {err}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn target_label_changes_which_prefix_names_a_target() {
        let d = scratch("target-label");
        let checkout = d.join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let mut r = test_repo(&d, &["m"]);
        r.target_label = "target".into();
        r.targets.insert("t".into(), Target { name: "t".into(), path: checkout, ..Default::default() });

        let out = r.for_bead(&["target:t"]).unwrap();
        assert_eq!(out.target, "t", "target: is the configured prefix");
        let out = r.for_bead(&["work:t"]).unwrap();
        assert_eq!(out.target, "", "work: names nothing under this prefix");
        assert_eq!(out.repo, r.repo, "so it is the default target");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn config_keys_are_documented() {
        const KEYS: &[&str] = &[
            "repos",
            "lanes",
            "label",
            "base",
            "setup",
            "gate",
            "precheck_model",
            "model",
            "review_model",
            "stages",
            "on_exhaust",
            "conflict_worker",
            "brief_model",
            "research_model",
            "research",
            "research_timeout",
            "merge",
            "merge_label",
            "adopt",
            "max_inflight",
            "worker_timeout",
            "stall_compactions",
            "stall_steps",
            "attach",
            "target_label",
        ];

        let docs = include_str!("../docs/config.md");
        let example = include_str!("../bead-loop.example.toml");

        // Every key is a row in the config reference table.
        for key in KEYS {
            let pattern = if *key == "stages" || *key == "lanes" { format!("| `[[{key}]]` |") } else { format!("| `{key}` |") };
            if !docs.contains(&pattern) {
                panic!("key `{key}` missing from the config reference (docs/config.md): expected `{pattern}`");
            }
        }

        // Every key but the two global-only ones has an example line.
        for key in KEYS {
            if *key == "repos" || *key == "lanes" {
                continue;
            }
            let bare = format!("{key} =");
            let bracketed = format!("[[{key}]]");
            let found = example.lines().any(|line| {
                let line = line.strip_prefix("# ").unwrap_or(line);
                line.starts_with(&bare) || line.starts_with(&bracketed)
            });
            if !found {
                panic!("key `{key}` missing from bead-loop.example.toml: expected `{bare}` or `{bracketed}` at the start of a line");
            }
        }

        // And nothing in the table's rows is undocumented in KEYS.
        for line in docs.lines() {
            if line.starts_with("## ") {
                break;
            }
            if let Some(rest) = line.strip_prefix("| `") {
                let cell = rest.split('`').next().unwrap_or("");
                let key = cell.trim_start_matches("[[").trim_end_matches("]]");
                if !KEYS.contains(&key) {
                    panic!("docs/config.md documents `{key}`, which is not in KEYS");
                }
            }
        }
    }
}

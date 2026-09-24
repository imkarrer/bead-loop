//! One probe per dependency the loop needs, each its own red or green line.
use crate::config::{Repo, Stage};
use crate::harness::opencode_provider;
use crate::shell::curl_get;
use crate::util::{cmd, first_line, have, output, stderr_str, stdout_str};
use serde_json::Value;

pub struct ProbeResult {
    pub name: String,
    pub ok: bool,
    pub detail: String,
}

impl ProbeResult {
    fn ok(name: impl Into<String>, detail: impl Into<String>) -> Self {
        Self { name: name.into(), ok: true, detail: detail.into() }
    }
    fn fail(name: impl Into<String>, detail: impl Into<String>) -> Self {
        Self { name: name.into(), ok: false, detail: detail.into() }
    }
    pub fn to_line(&self) -> String {
        format!("[{}] {}: {}", if self.ok { "green" } else { "red" }, self.name, self.detail)
    }
}

pub fn bd_probe() -> ProbeResult {
    match output(cmd("bd").arg("--version")) {
        Ok(o) if o.status.success() => ProbeResult::ok("bd", first_line(&stdout_str(&o))),
        Ok(o) => ProbeResult::fail("bd", first_line(&stderr_str(&o))),
        Err(e) => ProbeResult::fail("bd", format!("bd not runnable: {e}")),
    }
}

pub fn git_probe() -> ProbeResult {
    match output(cmd("git").arg("--version")) {
        Ok(o) if o.status.success() => ProbeResult::ok("git", first_line(&stdout_str(&o))),
        Ok(o) => ProbeResult::fail("git", first_line(&stderr_str(&o))),
        Err(e) => ProbeResult::fail("git", format!("git not runnable: {e}")),
    }
}

pub fn gh_probe() -> ProbeResult {
    match output(cmd("gh").args(["auth", "status"])) {
        Ok(o) if o.status.success() => ProbeResult::ok("gh auth", first_line(&stdout_str(&o))),
        Ok(o) => ProbeResult::fail("gh auth", first_line(&stderr_str(&o))),
        Err(e) => ProbeResult::fail("gh auth", format!("gh not runnable: {e}")),
    }
}

/// `claude auth status`: JSON on stdout either way (`loggedIn`), exit 1 when signed out —
/// the JSON is read regardless of the exit code, the same as `harness::claude_ok`.
pub fn claude_probe() -> ProbeResult {
    match output(cmd("claude").args(["auth", "status"])) {
        Ok(o) => {
            let v: Value = serde_json::from_str(&stdout_str(&o)).unwrap_or(Value::Null);
            if v.get("loggedIn").and_then(|b| b.as_bool()).unwrap_or(false) {
                let method = v.get("authMethod").and_then(|m| m.as_str()).unwrap_or("signed in");
                ProbeResult::ok("claude auth", method)
            } else {
                ProbeResult::fail("claude auth", "signed out")
            }
        }
        Err(e) => ProbeResult::fail("claude auth", format!("claude not runnable: {e}")),
    }
}

/// The opencode providers a repo's stages name: the part of `worker`/`reviewer` before the
/// first `/` (after stripping the `aider:` prefix, the same as `harness::run_agent`
/// resolves it); `claude/*` names no opencode provider. Sorted, unique.
fn providers_in(stages: &[Stage]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in stages {
        for model in [s.worker.as_str(), s.reviewer.as_str()] {
            if model.is_empty() || model.starts_with("claude/") {
                continue;
            }
            let rest = model.strip_prefix("aider:").unwrap_or(model);
            if let Some(p) = rest.split('/').next().filter(|p| !p.is_empty()) {
                if !out.iter().any(|x| x == p) {
                    out.push(p.to_string());
                }
            }
        }
    }
    out.sort();
    out
}

/// `GET baseURL/models`, 5 s: whether the provider's opencode server is reachable, for
/// every provider name any repo's stages use.
pub fn opencode_provider_probes(repos: &[Repo]) -> Vec<ProbeResult> {
    let mut providers: Vec<String> = Vec::new();
    for r in repos {
        for p in providers_in(&r.stages) {
            if !providers.contains(&p) {
                providers.push(p);
            }
        }
    }
    providers.sort();
    providers
        .iter()
        .map(|provider| {
            let name = format!("opencode provider {provider}");
            let (base, _key) = opencode_provider(provider);
            if base.is_empty() {
                return ProbeResult::fail(name, format!("no baseURL for {provider} in opencode.json"));
            }
            match curl_get(&format!("{base}/models"), None, 5) {
                Some(_) => ProbeResult::ok(name, format!("reachable at {base}")),
                None => ProbeResult::fail(name, format!("cannot reach {base}/models")),
            }
        })
        .collect()
}

/// `GET attach/session`, 5 s: the attached opencode server the loop runs rounds on.
pub fn attach_probe(repos: &[Repo]) -> ProbeResult {
    match repos.iter().map(|r| r.attach.as_str()).find(|a| !a.is_empty()) {
        None => ProbeResult::fail("attach server", "no attach server configured"),
        Some(attach) => match curl_get(&format!("{attach}/session"), None, 5) {
            Some(_) => ProbeResult::ok("attach server", format!("reachable at {attach}")),
            None => ProbeResult::fail("attach server", format!("cannot reach {attach}/session")),
        },
    }
}

/// `df -h` on the state dir: where every worktree, log and lane marker lives.
pub fn disk_free_probe() -> ProbeResult {
    let dir = crate::config::state_dir();
    match output(cmd("df").arg("-h").arg(&dir)) {
        Ok(o) if o.status.success() => {
            let line = stdout_str(&o).lines().nth(1).unwrap_or("").trim().to_string();
            ProbeResult::ok("disk free", if line.is_empty() { format!("unknown for {}", dir.display()) } else { line })
        }
        _ => ProbeResult::fail("disk free", format!("df failed for {}", dir.display())),
    }
}

/// The three units `systemctl --user enable --now` starts (README's Run), when systemctl
/// exists at all; skipped (green) on a box without one.
const UNITS: [&str; 3] = ["opencode-web.service", "bead-loop-ui.service", "bead-supervisor.timer"];

pub fn systemctl_probe() -> ProbeResult {
    if !have("systemctl") {
        return ProbeResult::ok("systemd units", "not available (no systemctl)");
    }
    let mut states = Vec::new();
    let mut all_active = true;
    for unit in UNITS {
        let state = match output(cmd("systemctl").args(["--user", "is-active", unit])) {
            Ok(o) => first_line(&stdout_str(&o)).to_string(),
            Err(_) => "unknown".to_string(),
        };
        if state != "active" {
            all_active = false;
        }
        states.push(format!("{unit}: {state}"));
    }
    let detail = states.join(", ");
    if all_active {
        ProbeResult::ok("systemd units", detail)
    } else {
        ProbeResult::fail("systemd units", detail)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage(worker: &str, reviewer: &str) -> Stage {
        Stage { worker: worker.into(), reviewer: reviewer.into(), failures: 1, timeout: None }
    }

    #[test]
    fn providers_named_in_the_stages() {
        assert_eq!(providers_in(&[stage("devbox/coder", "acbox/reviewer")]), vec!["acbox", "devbox"]);
        assert_eq!(providers_in(&[stage("claude/opus", "")]), Vec::<String>::new(), "claude names no opencode provider");
        assert_eq!(providers_in(&[stage("aider:acbox/coder", "")]), vec!["acbox"], "aider: strips to its opencode provider");
        assert_eq!(
            providers_in(&[stage("devbox/coder", "devbox/coder"), stage("devbox/fast", "acbox/reviewer")]),
            vec!["acbox", "devbox"],
            "sorted, unique"
        );
    }

    #[test]
    fn probe_result_lines() {
        assert_eq!(ProbeResult::ok("git", "git version 2").to_line(), "[green] git: git version 2");
        assert_eq!(ProbeResult::fail("claude auth", "signed out").to_line(), "[red] claude auth: signed out");
    }
}

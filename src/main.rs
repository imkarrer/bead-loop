//! bead-supervisor: work labelled beads in any repo with local models — implement, gate,
//! review, PR, merge on green, close the bead — as a resident loop over three queues.
//!
//!   bead-supervisor run                   the resident loop: reconcile, then the dev and review lanes and the
//!                                         merge watcher, for ever; a lane with nothing to do blocks on the bell
//!   bead-supervisor tick [REPO...]        one pass to idle: reconcile, both lanes side by side until both queues
//!                                         drain and both lanes idle, reconcile again, exit
//!   bead-supervisor work REPO [BEAD_ID]   one bead through dev and review now (top of the dev queue, or the id given)
//!   bead-supervisor lane NAME   one lane by itself, until its queue is empty (NAME is a lane name from the
//!                                         [[lanes]] config table)
//!   bead-supervisor pause NAME  the lane starts no new round until `resume` (the others go on)
//!   bead-supervisor resume NAME
//!   bead-supervisor priority REPO|none    the repo the lanes look at first on every pass (else round-robin)
//!   bead-supervisor wake                  ring the bell: every lane looks at its queue now
//!   bead-supervisor escalate REPO ID      put the bead on the last stage (Claude, usually) and back in the dev
//!                                         queue now, ahead of its failure count
//!   bead-supervisor answer REPO ID TEXT   your answer to a bead in the human queue: noted on the bead, back in
//!                                         the dev queue at the stage it stopped on
//!   bead-supervisor publish REPO ID [--title T] [--body-file F]   open the PR an open_pr = "ask" round
//!                                         left in proposed/ID — its title/body, or these instead
//!   bead-supervisor open REPO ID          an interactive Claude Code session in the bead's worktree, the bead,
//!                                         its history and the open question in the first prompt
//!   bead-supervisor reconcile [REPO...]   only the merge queue: merge green, close beads, send red back to dev
//!   bead-supervisor recover [REPO...]     what run does first: clear stale lane markers, abort orphan sessions,
//!                                         reopen a dev round the last stop cut short (no failure)
//!   bead-supervisor status [REPO...]      what is in flight: PRs, ready beads, worktrees and their sessions
//!   bead-supervisor watch [REPO...]       status every 5 s (BEAD_LOOP_WATCH=N), the last log lines above it
//!   bead-supervisor stats [REPO...]       the scoreboard: landed, first-try, without Claude, rounds and time per
//!                                         landing, send-backs by reason and model, model cost — 24h/7d/30d/all
//!   bead-supervisor log REPO [BEAD_ID]    follow the newest worker/reviewer session: tool calls and text
//!   bead-supervisor doctor [--json]         one line per dependency probe (green/red), or JSON array
//!
//!   --dry-run    pick the bead, print the prompt, change nothing
//!   --once       tick: one pass of each lane, in turn, whether or not more is queued
//!   --serial     tick: the lanes one after the other instead of side by side
//!   --json       status as one JSON object per repo, stats as one object (what the web UI reads)
//!   --local      implement, gate and review; keep the branch here, no push, no PR
//!   --model M    opencode provider/model for the worker this run
mod config;
mod doctor;
mod harness;
mod human;
mod lanes;
mod merge;
mod park;
mod round;
mod shell;
mod signals;
mod state;
mod stats;
mod status;
mod util;

use config::{config_dir, Layers, Repo};
use doctor::run as doctor_run;
use round::Opts;
use std::path::PathBuf;
use util::{die, log};

/// The commands `main` knows; the usage above names each one.
const COMMANDS: &[&str] = &[
    "run",
    "tick",
    "work",
    "lane",
    "pause",
    "resume",
    "priority",
    "wake",
    "escalate",
    "answer",
    "publish",
    "open",
    "reconcile",
    "recover",
    "status",
    "watch",
    "stats",
    "log",
    "doctor",
];

fn usage_text() -> String {
    let src = include_str!("main.rs");
    src.lines().take_while(|l| l.starts_with("//!")).map(|l| format!("{}\n", l.trim_start_matches("//!").trim_start_matches(' '))).collect()
}

fn usage() -> ! {
    print!("{}", usage_text());
    std::process::exit(0)
}

/// What is wrong with the arguments left after the known flags, if anything: a command
/// `main` does not have, or a flag it does not know. publish reads its own flags and
/// answer's TEXT is free text, so those two are not checked past the command. Checked
/// before the lock: a typo never takes it, or says it skipped a tick.
fn bad_args(args: &[String]) -> Option<String> {
    let cmd = args.first().map(String::as_str).unwrap_or("tick");
    if !COMMANDS.contains(&cmd) {
        return Some(if cmd.starts_with('-') { format!("unknown flag {cmd}") } else { format!("unknown command {cmd}") });
    }
    if matches!(cmd, "publish" | "answer") {
        return None;
    }
    args.iter().skip(1).find(|a| a.starts_with('-')).map(|a| format!("unknown flag {a}"))
}

fn main() {
    signals::install();
    let mut opts = Opts::default();
    let mut once = false;
    let mut serial = false;
    let mut json = false;
    let mut args: Vec<String> = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--dry-run" => opts.dry_run = true,
            "--once" => {
                once = true;
                serial = true;
            }
            "--serial" => serial = true,
            "--json" => json = true,
            "--local" => opts.local = true,
            "--model" => opts.model_flag = it.next(),
            "-h" | "--help" => usage(),
            _ => args.push(a),
        }
    }
    if let Some(e) = bad_args(&args) {
        eprint!("bead-supervisor: {e}\n\n{}", usage_text());
        std::process::exit(2);
    }
    let cmd = args.first().cloned().unwrap_or_else(|| "tick".to_string());
    let mut rest: Vec<String> = args.iter().skip(1).cloned().collect();
    let g_conf = config_dir().join("config.toml");
    let global = Layers::load(&g_conf, None);
    let lane_name = match cmd.as_str() {
        "lane" | "pause" | "resume" => {
            if rest.is_empty() {
                None
            } else {
                Some(rest.remove(0))
            }
        }
        _ => None,
    };
    let mut repos: Vec<PathBuf> = rest.iter().map(PathBuf::from).collect();
    let arg_repos = repos.len();
    if repos.is_empty() && cmd != "work" && cmd != "log" && cmd != "priority" && cmd != "wake" {
        repos = global.repos();
    }
    if repos.is_empty() && !matches!(cmd.as_str(), "priority" | "wake") {
        die(&format!("no repos: pass one or set repos in {}", g_conf.display()));
    }
    let state_dir = config::state_dir();
    // One supervisor at a time for anything that runs rounds or the merge queue; the
    // read-only and the one-bead commands are free.
    let _lock = match cmd.as_str() {
        "status" | "stats" | "log" | "watch" | "lane" | "pause" | "resume" | "escalate" | "answer" | "open" | "publish" | "priority"
        | "wake" | "doctor" => None,
        _ => match lanes::try_lock(&state_dir.join("lock")) {
            Some(l) => Some(l),
            None => {
                log(&format!("another bead-supervisor holds {}/lock; skipping this tick", state_dir.display()));
                std::process::exit(0)
            }
        },
    };
    // The lanes: [[lanes]] in the global config, else one per provider the repos' config
    // names. Only the commands that run or name lanes need to load the repos to know.
    let providers = if matches!(cmd.as_str(), "tick" | "run" | "lane" | "pause" | "resume" | "recover") {
        lanes::providers_named(&repos, opts.model_flag.as_deref())
    } else {
        Vec::new()
    };
    let lane_specs = global.lanes(&providers);
    let ctx = lanes::Ctx {
        repos: repos.clone(),
        opts: opts.clone(),
        once,
        serial,
        state_dir: state_dir.clone(),
        until_idle: true,
        lanes: config::slots_of(&lane_specs),
    };
    let lane_known = |n: &str| lane_specs.iter().any(|l| l.name == n) || matches!(n, "dev" | "review" | "claude");
    let lane_list = lane_specs.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join("|");
    let repo_at = |i: usize| -> Repo {
        if repos.len() <= i {
            die("REPO is required");
        }
        Repo::load(&repos[i], opts.model_flag.as_deref())
    };
    let _ = arg_repos;
    match cmd.as_str() {
        "tick" => lanes::tick(&ctx),
        "run" => lanes::run(&lanes::Ctx { until_idle: false, ..ctx }),
        "work" => {
            let repo = repo_at(0);
            round::work(&repo, &opts, rest.get(1).map(String::as_str));
        }
        "lane" => match lane_name.as_deref().and_then(|n| lane_specs.iter().find(|l| l.name == n)) {
            Some(spec) => lanes::lane(&ctx, spec, std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0))),
            None => die(&format!("lane {lane_list}")),
        },
        "pause" => match lane_name.as_deref() {
            Some(n) if lane_known(n) => {
                util::write_file(&state_dir.join(format!("pause.{n}")), "");
                log(&format!("{n} lane paused: it starts no new round until resume"));
            }
            _ => die(&format!("pause {lane_list}")),
        },
        "resume" => match lane_name.as_deref() {
            Some(n) if lane_known(n) => {
                let _ = std::fs::remove_file(state_dir.join(format!("pause.{n}")));
                util::touch(&state_dir.join("wake"));
                log(&format!("{n} lane resumed; the next pass picks it up"));
            }
            _ => die(&format!("resume {lane_list}")),
        },
        "priority" => lanes::set_priority(&state_dir, rest.first().map(String::as_str)),
        "wake" => {
            util::touch(&state_dir.join("wake"));
            log("bell rung: the lanes look at their queues now");
        }
        "escalate" => {
            let repo = repo_at(0);
            let id = rest.get(1).cloned().unwrap_or_else(|| die("escalate REPO ID"));
            human::escalate(&repo, &id);
        }
        "answer" => {
            let repo = repo_at(0);
            if rest.len() < 3 {
                die("answer REPO ID TEXT");
            }
            human::answer(&repo, &rest[1], &rest[2]);
        }
        "open" => {
            let repo = repo_at(0);
            let id = rest.get(1).cloned().unwrap_or_else(|| die("open REPO ID"));
            human::open_bead(&repo, &id);
        }
        "publish" => {
            let repo = repo_at(0);
            let id = rest.get(1).cloned().unwrap_or_else(|| die("publish REPO ID [--title T] [--body-file F]"));
            let mut title = None;
            let mut body_file = None;
            let mut i = 2;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--title" => {
                        i += 1;
                        title = Some(rest.get(i).cloned().unwrap_or_else(|| die("--title needs a value")));
                    }
                    "--body-file" => {
                        i += 1;
                        body_file = Some(rest.get(i).cloned().unwrap_or_else(|| die("--body-file needs a value")));
                    }
                    other => die(&format!("publish: unknown flag {other}")),
                }
                i += 1;
            }
            human::publish(&repo, &id, title, body_file);
        }
        "reconcile" => {
            for r in &repos {
                merge::reconcile(&Repo::load(r, opts.model_flag.as_deref()));
            }
        }
        "recover" => lanes::recover(&ctx),
        "status" => {
            for r in &repos {
                let repo = Repo::load(r, opts.model_flag.as_deref());
                if json {
                    println!("{}", serde_json::to_string(&status::status_json(&repo)).unwrap());
                } else {
                    print!("{}", status::status_one(&repo));
                }
            }
        }
        "stats" => {
            let loaded: Vec<Repo> = repos.iter().map(|r| Repo::load(r, opts.model_flag.as_deref())).collect();
            let j = stats::stats_json(&loaded);
            if json {
                println!("{}", serde_json::to_string(&j).unwrap());
            } else {
                print!("{}", stats::stats_text(&j));
            }
        }
        "watch" => {
            let every = std::env::var("BEAD_LOOP_WATCH").ok().and_then(|s| s.parse().ok()).unwrap_or(5);
            status::watch_loop(&repos, every, opts.model_flag.as_deref());
        }
        "log" => {
            let repo = repo_at(0);
            status::log_follow(&repo, rest.get(1).map(String::as_str));
        }
        "doctor" => {
            let loaded: Vec<Repo> = repos.iter().map(|r| Repo::load(r, opts.model_flag.as_deref())).collect();
            doctor_run(&loaded, json);
        }
        other => die(&format!("unknown command {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn an_unknown_flag_or_command_is_a_usage_error() {
        assert_eq!(bad_args(&v(&["--version"])).as_deref(), Some("unknown flag --version"));
        assert_eq!(bad_args(&v(&["-V"])).as_deref(), Some("unknown flag -V"));
        assert_eq!(bad_args(&v(&["stauts"])).as_deref(), Some("unknown command stauts"));
        assert_eq!(bad_args(&v(&["tick", "--verbose"])).as_deref(), Some("unknown flag --verbose"));
        assert_eq!(bad_args(&v(&["status", "--jsn"])).as_deref(), Some("unknown flag --jsn"));
        assert_eq!(bad_args(&v(&[])), None, "bare: a tick");
        assert_eq!(bad_args(&v(&["status", "/r"])), None);
        assert_eq!(bad_args(&v(&["publish", "/r", "x-1", "--title", "-t"])), None, "publish reads its own flags");
        assert_eq!(bad_args(&v(&["answer", "/r", "x-1", "-- yes"])), None, "answer's TEXT is free text");
    }

    #[test]
    fn usage_starts_at_the_first_line_and_names_every_command() {
        let u = usage_text();
        assert!(u.starts_with("bead-supervisor: work labelled beads"), "{u}");
        for c in COMMANDS {
            assert!(u.contains(&format!("bead-supervisor {c}")), "usage does not name {c}");
        }
    }
}

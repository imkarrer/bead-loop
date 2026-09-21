//! bead-supervisor: work labelled beads in any repo with local models — implement, gate,
//! review, PR, merge on green, close the bead — as a resident loop over three queues.
//!
//!   bead-supervisor run                   the resident loop: reconcile, then the dev and review lanes and the
//!                                         merge watcher, for ever; a lane with nothing to do blocks on the bell
//!   bead-supervisor tick [REPO...]        one pass to idle: reconcile, both lanes side by side until both queues
//!                                         drain and both lanes idle, reconcile again, exit
//!   bead-supervisor work REPO [BEAD_ID]   one bead through dev and review now (top of the dev queue, or the id given)
//!   bead-supervisor lane dev|review|claude   one lane by itself, until its queue is empty (claude: the lane a
//!                                         claude/* stage gets, so a bead on it never waits behind the GPU)
//!   bead-supervisor pause dev|review|claude  the lane starts no new round until `resume` (the others go on)
//!   bead-supervisor resume dev|review|claude
//!   bead-supervisor priority REPO|none    the repo the lanes look at first on every pass (else round-robin)
//!   bead-supervisor wake                  ring the bell: every lane looks at its queue now
//!   bead-supervisor escalate REPO ID      put the bead on the last stage (Claude, usually) and back in the dev
//!                                         queue now, ahead of its failure count
//!   bead-supervisor answer REPO ID TEXT   your answer to a bead in the human queue: noted on the bead, back in
//!                                         the dev queue at the stage it stopped on
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
//!
//!   --dry-run    pick the bead, print the prompt, change nothing
//!   --once       tick: one pass of each lane, in turn, whether or not more is queued
//!   --serial     tick: the lanes one after the other instead of side by side
//!   --json       status as one JSON object per repo, stats as one object (what the web UI reads)
//!   --local      implement, gate and review; keep the branch here, no push, no PR
//!   --model M    opencode provider/model for the worker this run
mod config;
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
use round::Opts;
use std::path::PathBuf;
use util::{die, log};

fn usage() -> ! {
    let src = include_str!("main.rs");
    for line in src.lines().skip(1).take_while(|l| l.starts_with("//!")) {
        println!("{}", line.trim_start_matches("//!").trim_start_matches(' '));
    }
    std::process::exit(0)
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
        "status" | "stats" | "log" | "watch" | "lane" | "pause" | "resume" | "escalate" | "answer" | "open" | "priority" | "wake" => None,
        _ => match lanes::try_lock(&state_dir.join("lock")) {
            Some(l) => Some(l),
            None => {
                log(&format!("another bead-supervisor holds {}/lock; skipping this tick", state_dir.display()));
                std::process::exit(0)
            }
        },
    };
    // The lanes: [[lanes]] in the global config, else dev + review (+ claude when a stage
    // names claude/*). Only the commands that run lanes need to know whether one does.
    let has_claude = matches!(cmd.as_str(), "tick" | "run" | "lane") && lanes::has_claude_stage(&repos, opts.model_flag.as_deref());
    let lane_specs = global.lanes(has_claude);
    let ctx = lanes::Ctx {
        repos: repos.clone(),
        opts: opts.clone(),
        once,
        serial,
        state_dir: state_dir.clone(),
        until_idle: true,
        lanes: lane_specs.clone(),
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
        other => die(&format!("unknown command {other}")),
    }
}

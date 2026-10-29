use std::env;
use std::process::Command;

fn git_path(manifest_dir: &str, arg: &str) -> Option<String> {
    let output = Command::new("git").args(["rev-parse", "--git-path", arg]).current_dir(manifest_dir).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(path)
    }
}

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

    // Get the git SHA
    let sha = match Command::new("git").args(["rev-parse", "HEAD"]).current_dir(&manifest_dir).output() {
        Ok(output) if output.status.success() => {
            let sha = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if sha.len() == 40 {
                sha
            } else {
                "unknown".to_string()
            }
        }
        _ => "unknown".to_string(),
    };

    // Get the dirty status
    let dirty = match Command::new("git").args(["status", "--porcelain"]).current_dir(&manifest_dir).output() {
        Ok(output) if output.status.success() => {
            if output.stdout.is_empty() {
                "0".to_string()
            } else {
                "1".to_string()
            }
        }
        _ => "0".to_string(),
    };

    println!("cargo:rustc-env=BEAD_LOOP_SHA={}", sha);
    println!("cargo:rustc-env=BEAD_LOOP_DIRTY={}", dirty);

    // Add rerun-if-changed directives for the build dependencies
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=agents");
    println!("cargo:rerun-if-changed=skills");

    // Add git-related paths, resolved through `git rev-parse --git-path` so a
    // worktree (where .git is a file, not a directory) resolves correctly.
    let manifest_dir_path = std::path::Path::new(&manifest_dir);
    for arg in ["HEAD", "index", "packed-refs"] {
        if let Some(path) = git_path(&manifest_dir, arg) {
            if manifest_dir_path.join(&path).exists() {
                println!("cargo:rerun-if-changed={}", path);
            }
        }
    }

    let branch_ref = match Command::new("git").args(["symbolic-ref", "-q", "HEAD"]).current_dir(&manifest_dir).output() {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout).trim().to_string(),
        _ => String::new(),
    };
    if !branch_ref.is_empty() {
        if let Some(path) = git_path(&manifest_dir, &branch_ref) {
            if manifest_dir_path.join(&path).exists() {
                println!("cargo:rerun-if-changed={}", path);
            }
        }
    }
}

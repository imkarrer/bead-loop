use std::env;
use std::process::Command;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let manifest_dir_path = std::path::Path::new(&manifest_dir);

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

    // Add git-related paths
    let git_path = manifest_dir_path.join(".git");
    if git_path.exists() {
        // Check for HEAD file
        let head_path = git_path.join("HEAD");
        if head_path.exists() {
            println!("cargo:rerun-if-changed={}", head_path.display());
        }

        // Check for index file
        let index_path = git_path.join("index");
        if index_path.exists() {
            println!("cargo:rerun-if-changed={}", index_path.display());
        }

        // Check for packed-refs file
        let packed_refs_path = git_path.join("packed-refs");
        if packed_refs_path.exists() {
            println!("cargo:rerun-if-changed={}", packed_refs_path.display());
        }

        // Check for current branch ref
        let branch_ref = match Command::new("git").args(["symbolic-ref", "-q", "HEAD"]).current_dir(&manifest_dir).output() {
            Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout).trim().to_string(),
            _ => String::new(),
        };

        if !branch_ref.is_empty() {
            let ref_path = git_path.join(&branch_ref);
            if ref_path.exists() {
                println!("cargo:rerun-if-changed={}", ref_path.display());
            }
        }
    }
}

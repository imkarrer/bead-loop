//! Probes for the doctor command

use std::process::Command;
use std::env;
use std::path::PathBuf;

/// A probe that checks one dependency
pub trait Probe {
    #[allow(dead_code)]
    fn name(&self) -> &str;
    fn check(&self) -> ProbeResult;
}

/// The result of a probe
#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

impl ProbeResult {
    pub fn ok(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            ok: true,
            detail: detail.into(),
        }
    }

    pub fn fail(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            ok: false,
            detail: detail.into(),
        }
    }

    pub fn to_line(&self) -> String {
        if self.ok {
            format!("[green]{}: {}", self.name, self.detail)
        } else {
            format!("[red]{}: {}", self.name, self.detail)
        }
    }
}

/// Check version of bead-supervisor
pub struct Version;

impl Probe for Version {
    fn name(&self) -> &str {
        "version"
    }

    fn check(&self) -> ProbeResult {
        let version = env!("CARGO_PKG_VERSION");
        ProbeResult::ok("version", format!("bead-supervisor v{}", version))
    }
}

/// Check git is available and configured
pub struct Git;

impl Probe for Git {
    fn name(&self) -> &str {
        "git"
    }

    fn check(&self) -> ProbeResult {
        match Command::new("git").arg("--version").output() {
            Ok(output) if output.status.success() => {
                let version = String::from_utf8_lossy(&output.stdout);
                ProbeResult::ok("git", version.trim().to_string())
            }
            _ => ProbeResult::fail("git", "git command not found or failed"),
        }
    }
}

/// Check gh auth status
pub struct GhAuth;

impl Probe for GhAuth {
    fn name(&self) -> &str {
        "gh auth"
    }

    fn check(&self) -> ProbeResult {
        match Command::new("gh").arg("auth").arg("status").output() {
            Ok(output) if output.status.success() => {
                let output_str = String::from_utf8_lossy(&output.stdout);
                if output_str.contains("logged in") {
                    ProbeResult::ok("gh auth", "logged in")
                } else {
                    ProbeResult::fail("gh auth", "not logged in")
                }
            }
            _ => ProbeResult::fail("gh auth", "gh command failed"),
        }
    }
}

/// Check claude auth status
pub struct ClaudeAuth;

impl Probe for ClaudeAuth {
    fn name(&self) -> &str {
        "claude auth"
    }

    fn check(&self) -> ProbeResult {
        match Command::new("claude").arg("auth").arg("status").output() {
            Ok(output) if output.status.success() => {
                let output_str = String::from_utf8_lossy(&output.stdout);
                if output_str.contains("\"loggedIn\":true") {
                    ProbeResult::ok("claude auth", "logged in")
                } else {
                    ProbeResult::fail("claude auth", "not logged in")
                }
            }
            _ => ProbeResult::fail("claude auth", "claude command failed or not logged in"),
        }
    }
}

/// Check opencode provider is reachable
pub struct OpencodeProvider;

impl Probe for OpencodeProvider {
    fn name(&self) -> &str {
        "opencode provider"
    }

    fn check(&self) -> ProbeResult {
        // Try to read config and check provider
        let config_dir = match env::var("BEAD_LOOP_CONFIG_DIR") {
            Ok(d) => PathBuf::from(d),
            Err(_) => {
                let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                PathBuf::from(&home).join(".config").join("bead-loop")
            }
        };

        let config_path = config_dir.join("config.toml");
        
        if !config_path.exists() {
            return ProbeResult::fail("opencode provider", "config.toml not found");
        }

        // Read config and extract providers
        let config_content = match std::fs::read_to_string(&config_path) {
            Ok(c) => c,
            Err(_) => return ProbeResult::fail("opencode provider", "cannot read config.toml"),
        };

        // Simple check: look for [providers] section
        if !config_content.contains("[providers]") {
            return ProbeResult::fail("opencode provider", "no providers configured");
        }

        // Try to hit the first provider's models endpoint
        for line in config_content.lines() {
            if line.starts_with("baseURL = ") {
                let url = line.trim_start_matches("baseURL = ").trim_matches('"');
                match Command::new("curl")
                    .arg("-s")
                    .arg("-m")
                    .arg("5")
                    .arg(format!("{}/models", url))
                    .output()
                {
                    Ok(output) if output.status.success() => {
                        return ProbeResult::ok("opencode provider", format!("reachable at {}", url));
                    }
                    _ => return ProbeResult::fail("opencode provider", format!("cannot reach {}", url)),
                }
            }
        }

        ProbeResult::fail("opencode provider", "no baseURL configured")
    }
}

/// Check attach server connectivity
pub struct AttachServer;

impl Probe for AttachServer {
    fn name(&self) -> &str {
        "attach server"
    }

    fn check(&self) -> ProbeResult {
        // Check for ATTACH_SERVER_URL or default
        let url = env::var("ATTACH_SERVER_URL").unwrap_or_else(|_| "http://localhost:8300".to_string());

        match Command::new("curl")
            .arg("-s")
            .arg("-m")
            .arg("5")
            .arg(format!("{}/health", url))
            .output()
        {
            Ok(output) if output.status.success() => {
                ProbeResult::ok("attach server", format!("reachable at {}", url))
            }
            _ => ProbeResult::fail("attach server", format!("cannot reach {}", url)),
        }
    }
}

/// Check disk free space
pub struct DiskFree;

impl Probe for DiskFree {
    fn name(&self) -> &str {
        "disk free"
    }

    fn check(&self) -> ProbeResult {
        // Use df -h . to get current directory's disk info
        match Command::new("df").arg("-h").arg(".").output() {
            Ok(output) if output.status.success() => {
                let output_str = String::from_utf8_lossy(&output.stdout);
                let lines: Vec<&str> = output_str.lines().collect();
                if lines.len() >= 2 {
                    let disk_info = lines[1];
                    ProbeResult::ok("disk free", disk_info.trim().to_string())
                } else {
                    ProbeResult::ok("disk free", "unable to parse disk info")
                }
            }
            _ => ProbeResult::fail("disk free", "df command failed"),
        }
    }
}

/// Check systemctl units (if systemctl exists)
pub struct SystemctlUnits;

impl Probe for SystemctlUnits {
    fn name(&self) -> &str {
        "systemctl units"
    }

    fn check(&self) -> ProbeResult {
        // Check if systemctl exists
        match Command::new("systemctl").arg("--version").output() {
            Ok(output) => {
                if output.status.success() {
                    // systemctl exists, check bead-loop service
                    let output_str = String::from_utf8_lossy(&output.stdout);
                    let version = output_str.lines().next().unwrap_or("unknown");
                    
                    // Try to check bead-loop status
                    match Command::new("systemctl")
                        .arg("is-active")
                        .arg("bead-loop.service")
                        .output()
                    {
                        Ok(out) => {
                            let status = String::from_utf8_lossy(&out.stdout).trim().to_string();
                            if status == "active" {
                                ProbeResult::ok("systemctl units", format!("{}: active", version))
                            } else {
                                ProbeResult::ok("systemctl units", format!("{}: bead-loop not active", version))
                            }
                        }
                        Err(_) => ProbeResult::ok("systemctl units", format!("{}: cannot check service", version)),
                    }
                } else {
                    ProbeResult::fail("systemctl units", "systemctl --version failed")
                }
            }
            Err(_) => {
                // systemctl doesn't exist, skip this probe
                ProbeResult::ok("systemctl units", "not available (no systemctl)")
            }
        }
    }
}

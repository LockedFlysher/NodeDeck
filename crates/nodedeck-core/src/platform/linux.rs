use std::path::PathBuf;
use std::process::Command;

use super::PlatformPaths;

pub fn default_paths() -> PlatformPaths {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    PlatformPaths {
        state_dir: home.join(".config").join("nodedeck"),
        easytier_core_candidates: vec![
            PathBuf::from("/opt/nodedeck/easytier/easytier-core"),
            home.join(".local/share/nodedeck/easytier/easytier-core"),
            PathBuf::from("/usr/local/bin/easytier-core"),
            PathBuf::from("/usr/bin/easytier-core"),
        ],
        easytier_cli_candidates: vec![
            PathBuf::from("/opt/nodedeck/easytier/easytier-cli"),
            home.join(".local/share/nodedeck/easytier/easytier-cli"),
            PathBuf::from("/usr/local/bin/easytier-cli"),
            PathBuf::from("/usr/bin/easytier-cli"),
        ],
    }
}

pub fn reload_user_sunshine(start_if_stopped: bool) -> bool {
    let active = Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", "nodedeck-host.service"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if active {
        return Command::new("systemctl")
            .args(["--user", "restart", "nodedeck-host.service"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
    }
    if start_if_stopped {
        return Command::new("systemctl")
            .args(["--user", "start", "nodedeck-host.service"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
    }
    false
}

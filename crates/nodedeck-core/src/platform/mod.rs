//! Platform Adapter Layer (RustDesk-style `#[cfg(target_os)]` isolation)
//!
//! All OS-specific paths, service orchestration, privilege elevation, and binary
//! discovery live behind this clean boundary so `nodedeck-core` business logic
//! stays 100% portable across macOS, Linux, Android, and future Windows/iOS builds.

use std::path::PathBuf;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "android")]
pub mod android;

#[derive(Debug, Clone)]
pub struct PlatformPaths {
    pub state_dir: PathBuf,
    pub easytier_core_candidates: Vec<PathBuf>,
    pub easytier_cli_candidates: Vec<PathBuf>,
}

pub fn current_platform_name() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "macos"
    }
    #[cfg(target_os = "linux")]
    {
        "linux"
    }
    #[cfg(target_os = "android")]
    {
        "android"
    }
    #[cfg(target_os = "windows")]
    {
        "windows"
    }
    #[cfg(not(any(
        target_os = "macos",
        target_os = "linux",
        target_os = "android",
        target_os = "windows"
    )))]
    {
        "unknown"
    }
}

pub fn default_platform_paths() -> PlatformPaths {
    #[cfg(target_os = "linux")]
    {
        linux::default_paths()
    }
    #[cfg(target_os = "macos")]
    {
        macos::default_paths()
    }
    #[cfg(target_os = "android")]
    {
        android::default_paths()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "android")))]
    {
        PlatformPaths {
            state_dir: dirs::config_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join("nodedeck"),
            easytier_core_candidates: Vec::new(),
            easytier_cli_candidates: Vec::new(),
        }
    }
}

pub fn resolve_first_executable(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find(|p| p.is_file()).cloned()
}

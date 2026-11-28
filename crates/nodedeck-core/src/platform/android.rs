use std::path::PathBuf;

use super::PlatformPaths;

pub fn default_paths() -> PlatformPaths {
    PlatformPaths {
        state_dir: PathBuf::from("/data/local/tmp/nodedeck"),
        easytier_core_candidates: Vec::new(),
        easytier_cli_candidates: Vec::new(),
    }
}

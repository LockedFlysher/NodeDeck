use std::path::PathBuf;

use super::PlatformPaths;

pub fn default_paths() -> PlatformPaths {
    let app_support = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("NodeDeck");
    PlatformPaths {
        state_dir: app_support,
        easytier_core_candidates: vec![
            PathBuf::from("/Applications/NodeDeck.app/Contents/Helpers/easytier-core"),
            PathBuf::from("/usr/local/bin/easytier-core"),
            PathBuf::from("/opt/homebrew/bin/easytier-core"),
        ],
        easytier_cli_candidates: vec![
            PathBuf::from("/Applications/NodeDeck.app/Contents/Helpers/easytier-cli"),
            PathBuf::from("/usr/local/bin/easytier-cli"),
            PathBuf::from("/opt/homebrew/bin/easytier-cli"),
        ],
    }
}

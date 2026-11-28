//! `nodedeck-bridge` — Stable async UI bridge facade for Flutter (`flutter_rust_bridge`).
//!
//! Every function here uses plain serializable DTOs and hides OS-specific adapters behind
//! `nodedeck-core`, so macOS, Linux, Android, and Windows UIs share 100% identical state logic.

use nodedeck_core::platform::{default_platform_paths, resolve_first_executable};
use nodedeck_core::{
    discover_lan_ips, expand_seed_uris, fetch_live_peer_transports, recommended_bitrate_kbps,
    AccountSession, ControlPlaneClient, MeshPeerTransport,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgePeerDto {
    pub ipv4: String,
    pub hostname: String,
    pub badge: String,
    pub detailed_badge: String,
    pub is_p2p: bool,
    pub is_tcp_relay: bool,
    pub latency_ms: Option<f64>,
    pub loss_rate_pct: Option<f64>,
}

impl From<MeshPeerTransport> for BridgePeerDto {
    fn from(p: MeshPeerTransport) -> Self {
        Self {
            badge: p.short_badge(),
            detailed_badge: p.detailed_badge(),
            is_tcp_relay: p.is_tcp_relay(),
            is_p2p: p.is_p2p,
            ipv4: p.ipv4,
            hostname: p.hostname,
            latency_ms: p.latency_ms,
            loss_rate_pct: p.loss_rate_pct,
        }
    }
}

pub fn bridge_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

pub fn bridge_expand_seed_uris(raw: String) -> Vec<String> {
    expand_seed_uris(&raw)
}

pub fn bridge_recommended_bitrate_kbps(width: u32, height: u32, fps: u32) -> u32 {
    recommended_bitrate_kbps(width, height, fps)
}

pub fn bridge_fetch_live_peers() -> Vec<BridgePeerDto> {
    let paths = default_platform_paths();
    let Some(cli) = resolve_first_executable(&paths.easytier_cli_candidates) else {
        return Vec::new();
    };
    fetch_live_peer_transports(&cli)
        .into_iter()
        .map(BridgePeerDto::from)
        .collect()
}

pub async fn bridge_login(
    server_url: String,
    username: String,
    password: String,
    device_id: String,
    device_name: String,
    platform: String,
    ssh_user: String,
) -> Result<AccountSession, String> {
    let cp = ControlPlaneClient::new();
    let lan_ips = discover_lan_ips("");
    let resp = cp
        .login(
            &server_url,
            &username,
            &password,
            &device_id,
            &device_name,
            &platform,
            "both",
            &ssh_user,
            &lan_ips,
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(AccountSession::from_response(&server_url, "", &ssh_user, resp))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_exposes_version_and_seed_expansion() {
        assert!(!bridge_core_version().is_empty());
        assert_eq!(
            bridge_expand_seed_uris("udp://a:25565,tcp://a:11010".to_string()),
            vec!["udp://a:25565", "tcp://a:11010"]
        );
        assert_eq!(bridge_recommended_bitrate_kbps(1920, 1080, 60), 20_000);
    }
}

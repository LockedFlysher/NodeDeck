//! NodeDeck Shared Core (`nodedeck-core`)
//!
//! Single source of truth for all cross-platform business logic across macOS, Linux,
//! Android, and future Windows/iOS clients. Uses pure Rust + `rustls` with zero
//! system OpenSSL/Python/GTK ABI dependencies.

pub mod control_plane;
pub mod mesh;
pub mod models;
pub mod platform;
pub mod ssh;
pub mod stream_math;
pub mod sunshine;

pub use control_plane::{ControlPlaneClient, ControlPlaneError};
pub use mesh::{
    build_easytier_runtime_toml, discover_lan_ips, expand_seed_uris, fetch_live_peer_transports,
    match_peer_transport, parse_easytier_transports, MeshPeerTransport, TransportKind,
};
pub use models::*;
pub use ssh::{parse_remote_metrics, parse_ssh_config, upsert_ssh_host, RemoteMetrics, SshHost};
pub use stream_math::{recommended_bitrate_kbps, StreamRefreshRate, StreamResolutionPreset};
pub use sunshine::{
    parse_host_conf, parse_server_info_xml, resolve_state_file_path, sync_client_certs_to_state,
    write_host_conf, HostConfPatch, SunshineServerInfo,
};

//! `nodedeck-mesh-daemon` — Pure-Rust drop-in replacement for `linux/nodedeck_mesh_agent.py`.
//!
//! Zero Python, zero system OpenSSL (`rustls` static TLS), compatible with existing
//! `~/.config/nodedeck/account.json` sessions, automatic reload on `seed_uri` or LAN IP
//! changes, SSH pubkey & Moonlight cert sync, and live EasyTier P2P/Relay transport inspection.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nodedeck_core::platform::{current_platform_name, default_platform_paths, resolve_first_executable};
use nodedeck_core::{
    build_easytier_runtime_toml_with_mode, discover_lan_ips, fetch_live_peer_transports,
    load_routing_mode, parse_host_conf, resolve_state_file_path, sync_client_certs_to_state,
    AccountSession, ControlPlaneClient, ControlPlaneSshKey, DEFAULT_CONTROL_PLANE_URL,
};
use serde_json::json;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;
use std::time::Duration;
use tokio::process::Command;

#[derive(Parser)]
#[command(name = "nodedeck-mesh", version, about = "NodeDeck Pure-Rust Mesh Agent & CLI")]
struct Cli {
    #[arg(long)]
    state_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Register a new NodeDeck account with an invite code and join the private mesh
    Register {
        #[arg(long, default_value = DEFAULT_CONTROL_PLANE_URL)]
        server: String,
        #[arg(long)]
        username: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        invite: String,
        #[arg(long)]
        device_name: Option<String>,
        #[arg(long, default_value = "both")]
        role: String,
    },
    /// Sign in to an existing NodeDeck account and join the private mesh
    Login {
        #[arg(long, default_value = DEFAULT_CONTROL_PLANE_URL)]
        server: String,
        #[arg(long)]
        username: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        device_name: Option<String>,
        #[arg(long, default_value = "both")]
        role: String,
    },
    /// Sign out and clear the saved account token
    Logout,
    /// Print current session and live EasyTier peer transports (P2P UDP / UDP Relay / TCP Relay)
    Status,
    /// Run persistent mesh daemon supervising easytier-core + control plane heartbeats
    Daemon,
}

fn session_file(state_dir: &Path) -> PathBuf {
    state_dir.join("account.json")
}

fn runtime_toml_file(state_dir: &Path) -> PathBuf {
    state_dir.join("easytier-runtime.toml")
}

fn load_session(state_dir: &Path) -> Option<AccountSession> {
    let path = session_file(state_dir);
    let raw = fs::read_to_string(&path).ok()?;
    match AccountSession::parse_compat_json(&raw) {
        Ok(s) => Some(s),
        Err(err) => {
            eprintln!(
                "[nodedeck-mesh-daemon] failed to parse {}: {err}",
                path.display()
            );
            None
        }
    }
}

fn platform_dev_name() -> Option<&'static str> {
    #[cfg(target_os = "linux")]
    {
        Some("et-nodedeck")
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

fn save_session(state_dir: &Path, session: &AccountSession) -> Result<()> {
    fs::create_dir_all(state_dir)?;
    let path = session_file(state_dir);
    let data = serde_json::to_string_pretty(session)?;
    fs::write(&path, data)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn default_device_name() -> String {
    hostname::get()
        .ok()
        .and_then(|s| s.into_string().ok())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "nodedeck-node".to_string())
}

fn current_ssh_user() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| "user".to_string())
}

fn get_or_create_device_id(state_dir: &Path, device_name: &str) -> String {
    let id_file = state_dir.join("device_id");
    if let Ok(existing) = fs::read_to_string(&id_file) {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    let clean: String = device_name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c.to_ascii_lowercase() } else { '-' })
        .collect();
    let suffix = format!(
        "{:08x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0x12345678)
    );
    let id = format!("{}-{clean}-{suffix}", current_platform_name());
    let _ = fs::create_dir_all(state_dir);
    let _ = fs::write(id_file, &id);
    id
}

fn detect_local_sunshine(state_dir: &Path) -> (bool, u16, u16) {
    let mut http_port: u16 = 47989;
    for cand in [state_dir.join("host.conf"), state_dir.join("host").join("host.conf")] {
        if let Ok(txt) = fs::read_to_string(&cand) {
            let cfg = parse_host_conf(&txt);
            if let Some(p) = cfg.get("port").and_then(|s| s.parse::<u16>().ok()) {
                http_port = p;
                break;
            }
        }
    }
    let https_port = http_port.saturating_sub(5).max(1);
    let running = std::net::TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], http_port)),
        Duration::from_millis(250),
    )
    .is_ok();
    (running, http_port, https_port)
}

fn ensure_local_ssh_pubkey() -> Option<String> {
    let home = dirs::home_dir()?;
    let ssh_dir = home.join(".ssh");
    let pub_path = ssh_dir.join("id_ed25519.pub");
    let key_path = ssh_dir.join("id_ed25519");
    if !pub_path.exists() {
        let _ = fs::create_dir_all(&ssh_dir);
        let _ = StdCommand::new("ssh-keygen")
            .args(["-t", "ed25519", "-N", "", "-f"])
            .arg(&key_path)
            .status();
    }
    fs::read_to_string(&pub_path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| s.starts_with("ssh-"))
}

fn sync_ssh_authorized_keys(keys: &[ControlPlaneSshKey]) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let ssh_dir = home.join(".ssh");
    let auth_path = ssh_dir.join("authorized_keys");
    let _ = fs::create_dir_all(&ssh_dir);
    let existing = fs::read_to_string(&auth_path).unwrap_or_default();
    let mut lines: Vec<String> = existing.lines().map(ToString::to_string).collect();
    let mut blobs: HashSet<String> = lines
        .iter()
        .filter_map(|ln| {
            let mut it = ln.split_whitespace();
            Some(format!("{} {}", it.next()?, it.next()?))
        })
        .collect();

    let mut added = 0usize;
    for k in keys {
        let pub_key = k.public_key.trim();
        if pub_key.is_empty() || pub_key.contains('\n') || pub_key.contains('\r') {
            continue;
        }
        let mut it = pub_key.split_whitespace();
        let (Some(algo), Some(b64)) = (it.next(), it.next()) else {
            continue;
        };
        if !(algo.starts_with("ssh-ed25519") || algo.starts_with("ssh-rsa") || algo.starts_with("ecdsa-sha2-")) {
            continue;
        }
        let blob = format!("{algo} {b64}");
        if blobs.insert(blob.clone()) {
            let safe_name = k.device_name.replace(' ', "_");
            lines.push(format!("{blob} nodedeck-{safe_name}"));
            added += 1;
        }
    }
    if added > 0 {
        let mut out = lines.join("\n");
        out.push('\n');
        if fs::write(&auth_path, out).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&ssh_dir, fs::Permissions::from_mode(0o700));
                let _ = fs::set_permissions(&auth_path, fs::Permissions::from_mode(0o600));
            }
        }
    }
}

fn restart_user_mesh_service_if_linux() {
    #[cfg(target_os = "linux")]
    {
        let sys_active = StdCommand::new("systemctl")
            .args(["is-active", "--quiet", "nodedeck-mesh.service"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if sys_active {
            return;
        }
        let _ = StdCommand::new("systemctl")
            .args(["--user", "enable", "--now", "nodedeck-mesh.service"])
            .status();
        let _ = StdCommand::new("systemctl")
            .args(["--user", "restart", "nodedeck-mesh.service"])
            .status();
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let paths = default_platform_paths();
    let state_dir = cli.state_dir.unwrap_or_else(|| paths.state_dir.clone());
    let cp = ControlPlaneClient::new();

    match cli.command {
        Commands::Register {
            server,
            username,
            password,
            invite,
            device_name,
            role,
        } => {
            let dev_name = device_name.unwrap_or_else(default_device_name);
            let ssh_user = current_ssh_user();
            let device_id = get_or_create_device_id(&state_dir, &dev_name);
            let lan_ips = discover_lan_ips("");
            let resp = cp
                .register(
                    &server,
                    &username,
                    &password,
                    &invite,
                    &device_id,
                    &dev_name,
                    current_platform_name(),
                    &role,
                    &ssh_user,
                    &lan_ips,
                )
                .await?;
            finish_auth(&cp, &state_dir, &server, &ssh_user, resp).await?;
        }

        Commands::Login {
            server,
            username,
            password,
            device_name,
            role,
        } => {
            let dev_name = device_name.unwrap_or_else(default_device_name);
            let ssh_user = current_ssh_user();
            let device_id = get_or_create_device_id(&state_dir, &dev_name);
            let lan_ips = discover_lan_ips("");
            let resp = cp
                .login(
                    &server,
                    &username,
                    &password,
                    &device_id,
                    &dev_name,
                    current_platform_name(),
                    &role,
                    &ssh_user,
                    &lan_ips,
                )
                .await?;
            finish_auth(&cp, &state_dir, &server, &ssh_user, resp).await?;
        }

        Commands::Logout => {
            let _ = fs::remove_file(session_file(&state_dir));
            #[cfg(target_os = "linux")]
            {
                let _ = StdCommand::new("systemctl")
                    .args(["--user", "stop", "nodedeck-mesh.service"])
                    .status();
            }
            println!("Signed out.");
        }

        Commands::Status => {
            if let Some(sess) = load_session(&state_dir) {
                println!(
                    "Account: {} | Device: {} ({}) | Seed: {}",
                    sess.user.username,
                    sess.device.device_name,
                    sess.device.virtual_cidr,
                    sess.mesh.seed_uri
                );
            } else {
                println!("Account: not signed in (state_dir={})", state_dir.display());
            }
            if let Some(et_cli) = resolve_first_executable(&paths.easytier_cli_candidates) {
                let peers = fetch_live_peer_transports(&et_cli);
                println!("Live EasyTier peers ({}):", peers.len());
                for p in peers {
                    println!(
                        "  - {:<24} {:<15} {}",
                        p.hostname,
                        if p.ipv4.is_empty() { "-" } else { &p.ipv4 },
                        p.detailed_badge()
                    );
                }
            } else {
                println!("easytier-cli not found");
            }
        }

        Commands::Daemon => {
            let et_bin = resolve_first_executable(&paths.easytier_core_candidates)
                .context("easytier-core binary not found")?;
            let toml_path = runtime_toml_file(&state_dir);

            loop {
                let Some(mut sess) = load_session(&state_dir) else {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                };
                if sess.token.is_empty() {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }

                let active_ips = discover_lan_ips(&sess.device.virtual_cidr);
                let (sun_on, sun_http, sun_https) = detect_local_sunshine(&state_dir);
                if let Ok(resp) = cp
                    .heartbeat(
                        &sess.server_url,
                        &sess.token,
                        &sess.device.device_name,
                        current_platform_name(),
                        if sun_on { "both" } else { &sess.device.role },
                        &sess.ssh_user,
                        sess.device.ssh_port,
                        sun_http,
                        sun_https,
                        sun_on,
                        &active_ips,
                    )
                    .await
                {
                    let pending = resp.pending_commands.clone();
                    sess = AccountSession::from_response(
                        &sess.server_url,
                        &sess.token,
                        &sess.ssh_user,
                        resp,
                    );
                    let _ = save_session(&state_dir, &sess);
                    handle_certs_keys_and_commands(&cp, &state_dir, &sess, &pending).await;
                }

                let active_key = sess.mesh_identity_key();
                let active_mode = load_routing_mode(&state_dir);
                let toml = build_easytier_runtime_toml_with_mode(
                    &sess,
                    &active_ips,
                    platform_dev_name(),
                    active_mode,
                );
                fs::create_dir_all(&state_dir)?;
                fs::write(&toml_path, &toml)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = fs::set_permissions(&toml_path, fs::Permissions::from_mode(0o600));
                }

                println!(
                    "[nodedeck-mesh-daemon] starting easytier-core for {} ({}) mode={} seed={}",
                    sess.device.device_name,
                    sess.device.virtual_cidr,
                    active_mode.as_str(),
                    sess.mesh.seed_uri
                );
                let mut child = Command::new(&et_bin)
                    .args(["-c", &toml_path.to_string_lossy()])
                    .spawn()
                    .context("failed to spawn easytier-core")?;

                let mut hb_ticks: u32 = 0;
                loop {
                    tokio::select! {
                        status = child.wait() => {
                            eprintln!("[nodedeck-mesh-daemon] easytier-core exited ({status:?}), restarting in 2s");
                            tokio::time::sleep(Duration::from_secs(2)).await;
                            break;
                        }
                        _ = tokio::time::sleep(Duration::from_secs(2)) => {
                            hb_ticks += 1;
                            // Instant (<2s) hot-reload when the user switches Latency vs Quality mode in the GUI.
                            let now_mode = load_routing_mode(&state_dir);
                            if now_mode != active_mode {
                                println!(
                                    "[nodedeck-mesh-daemon] routing mode changed ({} -> {}) -> reloading easytier-core",
                                    active_mode.as_str(),
                                    now_mode.as_str()
                                );
                                let _ = child.kill().await;
                                break;
                            }
                            if hb_ticks % 5 != 0 {
                                continue;
                            }
                            let Some(disk_sess) = load_session(&state_dir) else {
                                println!("[nodedeck-mesh-daemon] signed out, stopping easytier-core");
                                let _ = child.kill().await;
                                break;
                            };
                            if disk_sess.token.is_empty() {
                                let _ = child.kill().await;
                                break;
                            }
                            let now_ips = discover_lan_ips(&sess.device.virtual_cidr);
                            if now_ips != active_ips {
                                println!("[nodedeck-mesh-daemon] LAN IPs changed -> reloading easytier-core");
                                let _ = child.kill().await;
                                break;
                            }
                            let (sun_on, sun_http, sun_https) = detect_local_sunshine(&state_dir);
                            if let Ok(resp) = cp.heartbeat(
                                &sess.server_url,
                                &sess.token,
                                &sess.device.device_name,
                                current_platform_name(),
                                if sun_on { "both" } else { &sess.device.role },
                                &sess.ssh_user,
                                sess.device.ssh_port,
                                sun_http,
                                sun_https,
                                sun_on,
                                &now_ips,
                            ).await {
                                let pending = resp.pending_commands.clone();
                                sess = AccountSession::from_response(&sess.server_url, &sess.token, &sess.ssh_user, resp);
                                let _ = save_session(&state_dir, &sess);
                                handle_certs_keys_and_commands(&cp, &state_dir, &sess, &pending).await;
                                if sess.mesh_identity_key() != active_key {
                                    println!("[nodedeck-mesh-daemon] mesh identity or seed_uri changed -> reloading easytier-core");
                                    let _ = child.kill().await;
                                    break;
                                }
                            }
                        }
                        _ = tokio::signal::ctrl_c() => {
                            let _ = child.kill().await;
                            return Ok(());
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

async fn finish_auth(
    cp: &ControlPlaneClient,
    state_dir: &Path,
    server: &str,
    ssh_user: &str,
    resp: nodedeck_core::ControlPlaneStateResponse,
) -> Result<()> {
    let pending = resp.pending_commands.clone();
    let sess = AccountSession::from_response(server, "", ssh_user, resp);
    save_session(state_dir, &sess)?;
    let toml = build_easytier_runtime_toml_with_mode(
        &sess,
        &discover_lan_ips(&sess.device.virtual_cidr),
        platform_dev_name(),
        load_routing_mode(state_dir),
    );
    fs::write(runtime_toml_file(state_dir), toml)?;
    handle_certs_keys_and_commands(cp, state_dir, &sess, &pending).await;
    restart_user_mesh_service_if_linux();
    println!(
        "Signed in as {} -> {} ({})",
        sess.user.username, sess.device.device_name, sess.device.virtual_cidr
    );
    Ok(())
}

async fn handle_certs_keys_and_commands(
    cp: &ControlPlaneClient,
    state_dir: &Path,
    sess: &AccountSession,
    pending: &[nodedeck_core::ControlPlanePendingCommand],
) {
    if !sess.token.is_empty() {
        if let Some(pub_key) = ensure_local_ssh_pubkey() {
            let _ = cp
                .register_ssh_public_key(
                    &sess.server_url,
                    &sess.token,
                    &sess.device.device_name,
                    &pub_key,
                )
                .await;
        }
    }
    if !sess.ssh_public_keys.is_empty() {
        sync_ssh_authorized_keys(&sess.ssh_public_keys);
    }
    if !sess.client_certs.is_empty() {
        let state_file = resolve_state_file_path(state_dir);
        if let Ok(true) = sync_client_certs_to_state(&state_file, &sess.client_certs) {
            #[cfg(target_os = "linux")]
            let _ = nodedeck_core::platform::linux::reload_user_sunshine(false);
        }
    }
    let (_, sun_http, sun_https) = detect_local_sunshine(state_dir);
    for cmd in pending {
        if cmd.action == "activate_host" || cmd.action == "sync_certs" {
            #[cfg(target_os = "linux")]
            let _ = nodedeck_core::platform::linux::reload_user_sunshine(cmd.action == "activate_host");
            let _ = cp
                .ack_command(
                    &sess.server_url,
                    &sess.token,
                    cmd.id,
                    "done",
                    json!({
                        "sunshine_enabled": true,
                        "sunshine_http_port": sun_http,
                        "sunshine_https_port": sun_https,
                    }),
                )
                .await;
        }
    }
}

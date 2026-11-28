//! `nodedeck-mesh-daemon` — Pure-Rust replacement for `linux/nodedeck_mesh_agent.py`.
//!
//! Zero Python, zero system OpenSSL (`rustls` static TLS), automatic reload on
//! `seed_uri` or LAN IP changes, and live EasyTier P2P/Relay transport inspection.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nodedeck_core::platform::{current_platform_name, default_platform_paths, resolve_first_executable};
use nodedeck_core::{
    build_easytier_runtime_toml, discover_lan_ips, fetch_live_peer_transports,
    resolve_state_file_path, sync_client_certs_to_state, AccountSession, ControlPlaneClient,
    DEFAULT_CONTROL_PLANE_URL,
};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;

#[derive(Parser)]
#[command(name = "nodedeck-mesh-daemon", version, about = "NodeDeck Pure-Rust Mesh Agent & CLI")]
struct Cli {
    #[arg(long)]
    state_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Sign in and save local account session + EasyTier runtime TOML
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
    /// Print current session and live EasyTier peer transports (P2P UDP / UDP Relay / TCP Relay)
    Status,
    /// Run persistent mesh daemon supervising easytier-core + control plane heartbeats
    Daemon,
}

fn session_file(state_dir: &Path) -> PathBuf {
    state_dir.join("account-session.json")
}

fn runtime_toml_file(state_dir: &Path) -> PathBuf {
    state_dir.join("easytier-runtime.toml")
}

fn load_session(state_dir: &Path) -> Option<AccountSession> {
    let raw = fs::read_to_string(session_file(state_dir)).ok()?;
    serde_json::from_str(&raw).ok()
}

fn save_session(state_dir: &Path, session: &AccountSession) -> Result<()> {
    fs::create_dir_all(state_dir)?;
    let data = serde_json::to_string_pretty(session)?;
    fs::write(session_file(state_dir), data)?;
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let paths = default_platform_paths();
    let state_dir = cli.state_dir.unwrap_or_else(|| paths.state_dir.clone());
    let cp = ControlPlaneClient::new();

    match cli.command {
        Commands::Login {
            server,
            username,
            password,
            device_name,
            role,
        } => {
            let dev_name = device_name.unwrap_or_else(default_device_name);
            let ssh_user = current_ssh_user();
            let device_id = format!("{}-{dev_name}", current_platform_name());
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
            let sess = AccountSession::from_response(&server, "", &ssh_user, resp);
            save_session(&state_dir, &sess)?;
            let toml = build_easytier_runtime_toml(
                &sess,
                &discover_lan_ips(&sess.device.virtual_cidr),
                Some("et-nodedeck"),
            );
            fs::write(runtime_toml_file(&state_dir), toml)?;
            println!(
                "Signed in as {} -> {} ({})",
                sess.user.username, sess.device.device_name, sess.device.virtual_cidr
            );
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

                // Initial heartbeat before launching easytier-core
                let active_ips = discover_lan_ips(&sess.device.virtual_cidr);
                if let Ok(resp) = cp
                    .heartbeat(
                        &sess.server_url,
                        &sess.token,
                        &sess.device.device_name,
                        current_platform_name(),
                        &sess.device.role,
                        &sess.ssh_user,
                        sess.device.ssh_port,
                        sess.device.sunshine_http_port,
                        sess.device.sunshine_https_port,
                        sess.device.sunshine_enabled,
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
                    handle_certs_and_commands(&cp, &state_dir, &sess, &pending).await;
                }

                let active_key = sess.mesh_identity_key();
                let toml = build_easytier_runtime_toml(&sess, &active_ips, Some("et-nodedeck"));
                fs::create_dir_all(&state_dir)?;
                fs::write(&toml_path, toml)?;

                println!(
                    "[nodedeck-mesh-daemon] starting easytier-core for {} ({}) seed={}",
                    sess.device.device_name, sess.device.virtual_cidr, sess.mesh.seed_uri
                );
                let mut child = Command::new(&et_bin)
                    .args(["-c", &toml_path.to_string_lossy()])
                    .spawn()
                    .context("failed to spawn easytier-core")?;

                loop {
                    tokio::select! {
                        status = child.wait() => {
                            eprintln!("[nodedeck-mesh-daemon] easytier-core exited ({status:?}), restarting in 2s");
                            tokio::time::sleep(Duration::from_secs(2)).await;
                            break;
                        }
                        _ = tokio::time::sleep(Duration::from_secs(10)) => {
                            let now_ips = discover_lan_ips(&sess.device.virtual_cidr);
                            if now_ips != active_ips {
                                println!("[nodedeck-mesh-daemon] LAN IPs changed -> reloading easytier-core");
                                let _ = child.kill().await;
                                break;
                            }
                            if let Ok(resp) = cp.heartbeat(
                                &sess.server_url,
                                &sess.token,
                                &sess.device.device_name,
                                current_platform_name(),
                                &sess.device.role,
                                &sess.ssh_user,
                                sess.device.ssh_port,
                                sess.device.sunshine_http_port,
                                sess.device.sunshine_https_port,
                                sess.device.sunshine_enabled,
                                &now_ips,
                            ).await {
                                let pending = resp.pending_commands.clone();
                                sess = AccountSession::from_response(&sess.server_url, &sess.token, &sess.ssh_user, resp);
                                let _ = save_session(&state_dir, &sess);
                                handle_certs_and_commands(&cp, &state_dir, &sess, &pending).await;
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

async fn handle_certs_and_commands(
    cp: &ControlPlaneClient,
    state_dir: &Path,
    sess: &AccountSession,
    pending: &[nodedeck_core::ControlPlanePendingCommand],
) {
    if !sess.client_certs.is_empty() {
        let state_file = resolve_state_file_path(state_dir);
        if let Ok(true) = sync_client_certs_to_state(&state_file, &sess.client_certs) {
            #[cfg(target_os = "linux")]
            let _ = nodedeck_core::platform::linux::reload_user_sunshine(false);
        }
    }
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
                        "sunshine_http_port": sess.device.sunshine_http_port,
                        "sunshine_https_port": sess.device.sunshine_https_port,
                    }),
                )
                .await;
        }
    }
}

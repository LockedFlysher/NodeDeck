use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SshHost {
    pub alias: String,
    pub alternate_aliases: Vec<String>,
    pub hostname: String,
    pub user: String,
    pub port: u16,
    pub identity_file: String,
    pub proxy_jump: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct GpuMetric {
    pub name: String,
    pub utilization_pct: f64,
    pub memory_used_mb: f64,
    pub memory_total_mb: f64,
    pub temperature_c: f64,
    pub power_watts: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct RemoteMetrics {
    pub os: String,
    pub kernel: String,
    pub cpu_cores: u32,
    pub cpu_pct: f64,
    pub mem_used_mb: f64,
    pub mem_total_mb: f64,
    pub disk_pct: f64,
    pub rtt_ms: Option<u32>,
    pub gpus: Vec<GpuMetric>,
}

/// Parses OpenSSH `~/.ssh/config` into structured `SshHost` entries, skipping wildcard patterns.
pub fn parse_ssh_config(text: &str) -> Vec<SshHost> {
    let mut hosts: Vec<SshHost> = Vec::new();
    let mut current: Option<SshHost> = None;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.splitn(2, |c: char| c.is_whitespace() || c == '=');
        let key = parts.next().unwrap_or("").trim().to_lowercase();
        let val = parts.next().unwrap_or("").trim().trim_start_matches('=').trim();
        if val.is_empty() {
            continue;
        }
        if key == "host" {
            if let Some(h) = current.take() {
                hosts.push(h);
            }
            let aliases: Vec<String> = val
                .split_whitespace()
                .filter(|a| !a.contains('*') && !a.contains('?') && !a.starts_with('!'))
                .map(ToString::to_string)
                .collect();
            if let Some((first, rest)) = aliases.split_first() {
                current = Some(SshHost {
                    alias: first.clone(),
                    alternate_aliases: rest.to_vec(),
                    hostname: first.clone(),
                    user: String::new(),
                    port: 22,
                    identity_file: String::new(),
                    proxy_jump: String::new(),
                });
            }
        } else if let Some(ref mut h) = current {
            match key.as_str() {
                "hostname" => h.hostname = val.to_string(),
                "user" => h.user = val.to_string(),
                "port" => {
                    if let Ok(p) = val.parse::<u16>() {
                        h.port = p;
                    }
                }
                "identityfile" => h.identity_file = val.to_string(),
                "proxyjump" => h.proxy_jump = val.to_string(),
                _ => {}
            }
        }
    }
    if let Some(h) = current {
        hosts.push(h);
    }
    hosts
}

/// Upserts a host block into `~/.ssh/config` if neither alias nor hostname exists yet.
/// Returns `true` if a new entry was appended.
pub fn upsert_ssh_host(config_path: &Path, host: &SshHost) -> std::io::Result<bool> {
    let existing = fs::read_to_string(config_path).unwrap_or_default();
    let parsed = parse_ssh_config(&existing);
    let exists = parsed.iter().any(|h| {
        h.alias.eq_ignore_ascii_case(&host.alias)
            || h.alternate_aliases
                .iter()
                .any(|a| a.eq_ignore_ascii_case(&host.alias))
            || h.hostname.eq_ignore_ascii_case(&host.hostname)
    });
    if exists {
        return Ok(false);
    }
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut block = String::new();
    if !existing.is_empty() && !existing.ends_with('\n') {
        block.push('\n');
    }
    if !existing.is_empty() {
        block.push('\n');
    }
    block.push_str(&format!("Host {}\n", host.alias));
    block.push_str(&format!("  HostName {}\n", host.hostname));
    if !host.user.is_empty() {
        block.push_str(&format!("  User {}\n", host.user));
    }
    if host.port != 22 && host.port > 0 {
        block.push_str(&format!("  Port {}\n", host.port));
    }
    if !host.identity_file.is_empty() {
        block.push_str(&format!("  IdentityFile {}\n", host.identity_file));
    }
    if !host.proxy_jump.is_empty() {
        block.push_str(&format!("  ProxyJump {}\n", host.proxy_jump));
    }
    let mut full = existing;
    full.push_str(&block);
    fs::write(config_path, full)?;
    Ok(true)
}

/// Parses NodeDeck's canonical key-value remote probe output into `RemoteMetrics`.
pub fn parse_remote_metrics(raw: &str) -> RemoteMetrics {
    let mut kv: HashMap<String, String> = HashMap::new();
    let mut gpus: Vec<GpuMetric> = Vec::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("GPU=") {
            let cols: Vec<&str> = rest.split(',').map(str::trim).collect();
            if cols.len() >= 5 {
                gpus.push(GpuMetric {
                    name: cols[0].to_string(),
                    utilization_pct: cols[1].parse().unwrap_or(0.0),
                    memory_used_mb: cols[2].parse().unwrap_or(0.0),
                    memory_total_mb: cols[3].parse().unwrap_or(0.0),
                    temperature_c: cols[4].parse().unwrap_or(0.0),
                    power_watts: cols.get(5).and_then(|s| s.parse().ok()).unwrap_or(0.0),
                });
            }
        } else if let Some((k, v)) = trimmed.split_once('=') {
            kv.insert(k.trim().to_uppercase(), v.trim().to_string());
        }
    }
    RemoteMetrics {
        os: kv.get("OS").cloned().unwrap_or_default(),
        kernel: kv.get("KERNEL").cloned().unwrap_or_default(),
        cpu_cores: kv.get("CORES").and_then(|s| s.parse().ok()).unwrap_or(0),
        cpu_pct: kv.get("CPU_PCT").and_then(|s| s.parse().ok()).unwrap_or(0.0),
        mem_used_mb: kv.get("MEM_USED_MB").and_then(|s| s.parse().ok()).unwrap_or(0.0),
        mem_total_mb: kv.get("MEM_TOTAL_MB").and_then(|s| s.parse().ok()).unwrap_or(0.0),
        disk_pct: kv.get("DISK_PCT").and_then(|s| s.parse().ok()).unwrap_or(0.0),
        rtt_ms: kv.get("RTT_MS").and_then(|s| s.parse().ok()),
        gpus,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ssh_config_and_ignores_wildcards() {
        let cfg = "\
Host *\n  ServerAliveInterval 30\n\n\
Host 5090 workstation-5090\n  HostName 10.99.0.1\n  User sunnypea\n  Port 22\n";
        let hosts = parse_ssh_config(cfg);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].alias, "5090");
        assert_eq!(hosts[0].alternate_aliases, vec!["workstation-5090"]);
        assert_eq!(hosts[0].hostname, "10.99.0.1");
        assert_eq!(hosts[0].user, "sunnypea");
    }

    #[test]
    fn parses_multi_gpu_metrics() {
        let raw = "\
OS=Ubuntu 26.04\nKERNEL=7.0.0\nCORES=20\nCPU_PCT=12.5\nMEM_USED_MB=4096\nMEM_TOTAL_MB=16384\n\
GPU=NVIDIA GeForce RTX 3080 Ti Laptop GPU, 42, 2048, 16384, 61, 85.2\n";
        let m = parse_remote_metrics(raw);
        assert_eq!(m.cpu_cores, 20);
        assert_eq!(m.gpus.len(), 1);
        assert_eq!(m.gpus[0].temperature_c, 61.0);
    }
}

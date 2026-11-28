use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::net::UdpSocket;
use std::path::Path;
use std::process::Command;

use crate::models::AccountSession;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum TransportKind {
    P2pUdp,
    P2pTcp,
    UdpRelay,
    TcpRelay,
    Direct,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MeshPeerTransport {
    pub ipv4: String,
    pub hostname: String,
    pub is_p2p: bool,
    pub hop_count: u8,
    pub tunnel_proto: String,
    pub relay_via: String,
    pub latency_ms: Option<f64>,
    pub loss_rate_pct: Option<f64>,
}

impl MeshPeerTransport {
    pub fn kind(&self) -> TransportKind {
        let p = self.tunnel_proto.to_lowercase();
        if self.is_p2p {
            if p.contains("tcp") && !p.contains("udp") {
                TransportKind::P2pTcp
            } else {
                TransportKind::P2pUdp
            }
        } else if p.contains("udp") {
            TransportKind::UdpRelay
        } else if p.contains("tcp") {
            TransportKind::TcpRelay
        } else {
            TransportKind::UdpRelay
        }
    }

    pub fn is_tcp_relay(&self) -> bool {
        self.kind() == TransportKind::TcpRelay
    }

    pub fn is_udp_relay(&self) -> bool {
        self.kind() == TransportKind::UdpRelay
    }

    pub fn short_badge(&self) -> String {
        let p = self.tunnel_proto.to_lowercase();
        if self.is_p2p {
            if p.contains("udp") {
                "P2P · UDP".to_string()
            } else if p.contains("tcp") {
                "P2P · TCP".to_string()
            } else if !p.is_empty() {
                format!("P2P · {}", p.to_uppercase())
            } else {
                "P2P".to_string()
            }
        } else if p.contains("udp") {
            "UDP Relay".to_string()
        } else if p.contains("tcp") {
            "TCP Relay".to_string()
        } else {
            format!("Relay({})", self.hop_count)
        }
    }

    pub fn detailed_badge(&self) -> String {
        let mut parts = vec![self.short_badge()];
        if let Some(lat) = self.latency_ms {
            if lat > 0.0 {
                parts.push(format!("{}ms", lat.round() as i64));
            }
        }
        if let Some(loss) = self.loss_rate_pct {
            if loss >= 5.0 {
                parts.push(format!("loss {}%", loss.round() as i64));
            }
        }
        parts.join(" · ")
    }
}

/// Expands seed URI(s) so UDP relay is always preferred before TCP fallback.
/// When multiple explicit URIs are configured (e.g. `udp://host:25565,tcp://host:11010`),
/// preserves them verbatim with UDP ordered first and never fabricates mismatched port pairs.
pub fn expand_seed_uris(raw: &str) -> Vec<String> {
    let tokens: Vec<String> = raw
        .split(|c: char| c == ',' || c.is_whitespace())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if tokens.len() > 1 {
        let mut ordered = Vec::with_capacity(tokens.len());
        for uri in tokens.iter().filter(|u| u.starts_with("udp://")) {
            if !ordered.contains(uri) {
                ordered.push(uri.clone());
            }
        }
        for uri in tokens.iter().filter(|u| !u.starts_with("udp://")) {
            if !ordered.contains(uri) {
                ordered.push(uri.clone());
            }
        }
        return ordered;
    }

    let mut ordered = Vec::new();
    for uri in tokens {
        if let Some(rest) = uri.strip_prefix("tcp://") {
            let udp = format!("udp://{rest}");
            if !ordered.contains(&udp) {
                ordered.push(udp);
            }
            if !ordered.contains(&uri) {
                ordered.push(uri);
            }
        } else if let Some(rest) = uri.strip_prefix("udp://") {
            if !ordered.contains(&uri) {
                ordered.push(uri.clone());
            }
            let tcp = format!("tcp://{rest}");
            if !ordered.contains(&tcp) {
                ordered.push(tcp);
            }
        } else if !ordered.contains(&uri) {
            ordered.push(uri);
        }
    }
    ordered
}

/// Discovers primary LAN IPv4 addresses while excluding loopback, link-local,
/// and the EasyTier virtual mesh subnet.
pub fn discover_lan_ips(virtual_cidr: &str) -> Vec<String> {
    let mesh_prefix3 = {
        let ip_only = virtual_cidr.split('/').next().unwrap_or("");
        let octets: Vec<&str> = ip_only.split('.').collect();
        if octets.len() == 4 {
            format!("{}.{}.{}.", octets[0], octets[1], octets[2])
        } else {
            String::new()
        }
    };

    let mut ips = Vec::new();
    for probe in ["119.29.29.29:53", "8.8.8.8:53", "1.1.1.1:53"] {
        if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
            if sock.connect(probe).is_ok() {
                if let Ok(local) = sock.local_addr() {
                    let ip = local.ip().to_string();
                    if is_usable_lan_ip(&ip, &mesh_prefix3) && !ips.contains(&ip) {
                        ips.push(ip);
                    }
                }
            }
        }
    }
    ips.sort();
    ips
}

fn is_usable_lan_ip(ip: &str, mesh_prefix3: &str) -> bool {
    if ip.is_empty()
        || ip.starts_with("127.")
        || ip.starts_with("169.254.")
        || ip.contains(':')
    {
        return false;
    }
    if !mesh_prefix3.is_empty() && ip.starts_with(mesh_prefix3) {
        return false;
    }
    true
}

/// Generates a uniform EasyTier runtime TOML across macOS, Linux, and Android.
pub fn build_easytier_runtime_toml(
    session: &AccountSession,
    lan_ips: &[String],
    dev_name: Option<&str>,
) -> String {
    let port = if session.mesh.listen_port >= 1024 {
        session.mesh.listen_port
    } else {
        28443
    };
    let mapped: Vec<String> = lan_ips
        .iter()
        .map(|ip| format!("\"udp://{ip}:{port}\""))
        .collect();
    let peer_blocks: Vec<String> = expand_seed_uris(&session.mesh.seed_uri)
        .into_iter()
        .map(|uri| format!("[[peer]]\nuri = \"{uri}\""))
        .collect();

    let mut out = format!(
        "hostname = \"{}\"\n\
         ipv4 = \"{}\"\n\
         listeners = [\"udp://0.0.0.0:{port}\", \"tcp://0.0.0.0:{port}\"]\n\
         mapped_listeners = [{}]\n\n\
         [network_identity]\n\
         network_name = \"{}\"\n\
         network_secret = \"{}\"\n\n\
         {}\n\n\
         [flags]\n\
         default_protocol = \"udp\"\n\
         multi_thread = true\n\
         latency_first = true\n",
        session.device.device_name,
        session.device.virtual_cidr,
        mapped.join(", "),
        session.mesh.network_name,
        session.mesh.network_secret,
        peer_blocks.join("\n\n"),
    );
    if let Some(dev) = dev_name {
        if !dev.is_empty() {
            out.push_str(&format!("dev_name = \"{dev}\"\n"));
        }
    }
    out
}

/// Parses `easytier-cli -o json peer` and optional `easytier-cli -o json route` JSON outputs
/// into canonical `MeshPeerTransport` records, resolving relayed hops' true protocol (`udp` vs `tcp`).
pub fn parse_easytier_transports(
    peer_json: &str,
    route_json: Option<&str>,
) -> Vec<MeshPeerTransport> {
    let peers: Vec<Value> = serde_json::from_str(peer_json).unwrap_or_default();
    let mut proto_by_host: HashMap<String, String> = HashMap::new();
    let mut loss_by_host: HashMap<String, f64> = HashMap::new();

    for item in &peers {
        let host = item
            .get("hostname")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_lowercase();
        let tp = item
            .get("tunnel_proto")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_lowercase();
        if !host.is_empty() && !tp.is_empty() && tp != "-" {
            proto_by_host.insert(host.clone(), tp);
        }
        if !host.is_empty() {
            if let Some(loss) = parse_pct_value(item.get("loss_rate")) {
                loss_by_host.insert(host, loss);
            }
        }
    }

    let mut next_hop_by_ip: HashMap<String, String> = HashMap::new();
    let mut next_hop_by_host: HashMap<String, String> = HashMap::new();
    if let Some(rjson) = route_json {
        if let Ok(routes) = serde_json::from_str::<Vec<Value>>(rjson) {
            for r in routes {
                let ip = r
                    .get("ipv4")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .split('/')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string();
                let h = r
                    .get("hostname")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_lowercase();
                let nh = r
                    .get("next_hop_hostname")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                if !nh.is_empty() && nh != "DIRECT" && nh != "Local" {
                    if !ip.is_empty() {
                        next_hop_by_ip.insert(ip, nh.clone());
                    }
                    if !h.is_empty() {
                        next_hop_by_host.insert(h, nh);
                    }
                }
            }
        }
    }

    let mut out = Vec::new();
    for item in peers {
        let cost_raw = item
            .get("cost")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if cost_raw.eq_ignore_ascii_case("Local") {
            continue;
        }
        let ipv4 = item
            .get("ipv4")
            .and_then(Value::as_str)
            .unwrap_or("")
            .split('/')
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        let hostname = item
            .get("hostname")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if ipv4.is_empty() && hostname.is_empty() {
            continue;
        }

        let is_p2p = cost_raw.eq_ignore_ascii_case("p2p");
        let hop_count = if is_p2p {
            1
        } else {
            parse_relay_hops(cost_raw).unwrap_or(2)
        };

        let mut proto = item
            .get("tunnel_proto")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_lowercase();
        if proto == "-" {
            proto.clear();
        }
        let relay_via = next_hop_by_ip
            .get(&ipv4)
            .or_else(|| next_hop_by_host.get(&hostname.to_lowercase()))
            .cloned()
            .unwrap_or_default();

        if !is_p2p && proto.is_empty() {
            if !relay_via.is_empty() {
                if let Some(hp) = proto_by_host.get(&relay_via.to_lowercase()) {
                    proto = hp.clone();
                }
            }
            if proto.is_empty() {
                if let Some((_, sp)) = proto_by_host
                    .iter()
                    .find(|(k, _)| k.contains("seed") || k.contains("public"))
                {
                    proto = sp.clone();
                }
            }
        }

        let latency_ms = parse_float_value(item.get("lat_ms"));
        let mut loss_rate_pct = parse_pct_value(item.get("loss_rate"));
        if !is_p2p && loss_rate_pct.unwrap_or(0.0) == 0.0 && !relay_via.is_empty() {
            if let Some(&hop_loss) = loss_by_host.get(&relay_via.to_lowercase()) {
                if hop_loss > 0.0 {
                    loss_rate_pct = Some(hop_loss);
                }
            }
        }

        out.push(MeshPeerTransport {
            ipv4,
            hostname,
            is_p2p,
            hop_count,
            tunnel_proto: proto,
            relay_via,
            latency_ms,
            loss_rate_pct,
        });
    }
    out
}

pub fn match_peer_transport<'a>(
    peers: &'a [MeshPeerTransport],
    address: &str,
    alias: Option<&str>,
) -> Option<&'a MeshPeerTransport> {
    let addr = address.trim().to_lowercase();
    if !addr.is_empty() {
        if let Some(p) = peers
            .iter()
            .find(|p| !p.ipv4.is_empty() && p.ipv4.to_lowercase() == addr)
        {
            return Some(p);
        }
    }
    if let Some(a) = alias.map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()) {
        if let Some(p) = peers.iter().find(|p| p.hostname.to_lowercase() == a) {
            return Some(p);
        }
    }
    None
}

pub fn fetch_live_peer_transports(cli_path: &Path) -> Vec<MeshPeerTransport> {
    let Ok(peer_out) = Command::new(cli_path)
        .args(["-o", "json", "peer"])
        .output()
    else {
        return Vec::new();
    };
    if !peer_out.status.success() {
        return Vec::new();
    }
    let peer_json = String::from_utf8_lossy(&peer_out.stdout);
    let route_json = Command::new(cli_path)
        .args(["-o", "json", "route"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
    parse_easytier_transports(&peer_json, route_json.as_deref())
}

fn parse_relay_hops(cost: &str) -> Option<u8> {
    let start = cost.find('(')?;
    let end = cost.find(')')?;
    if start + 1 < end {
        cost[start + 1..end].parse::<u8>().ok()
    } else {
        None
    }
}

fn parse_float_value(v: Option<&Value>) -> Option<f64> {
    let v = v?;
    if let Some(n) = v.as_f64() {
        return Some(n);
    }
    let s = v.as_str()?.trim();
    if s.is_empty() || s == "-" {
        None
    } else {
        s.parse::<f64>().ok()
    }
}

fn parse_pct_value(v: Option<&Value>) -> Option<f64> {
    let v = v?;
    if let Some(n) = v.as_f64() {
        return Some(n);
    }
    let s = v.as_str()?.replace('%', "").trim().to_string();
    if s.is_empty() || s == "-" {
        None
    } else {
        s.parse::<f64>().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_seed_uris_preserves_distinct_udp_and_tcp_ports() {
        let uris = expand_seed_uris(
            "tcp://lockedflysher.duckdns.org:11010,udp://lockedflysher.duckdns.org:25565",
        );
        assert_eq!(
            uris,
            vec![
                "udp://lockedflysher.duckdns.org:25565",
                "tcp://lockedflysher.duckdns.org:11010",
            ]
        );
    }

    #[test]
    fn expand_seed_uris_expands_single_legacy_tcp_uri() {
        let uris = expand_seed_uris("tcp://seed.example.com:11010");
        assert_eq!(
            uris,
            vec![
                "udp://seed.example.com:11010",
                "tcp://seed.example.com:11010",
            ]
        );
    }

    #[test]
    fn parse_transports_resolves_udp_relay_for_dual_tcp_udp_seed() {
        let peer_json = r#"[
            {"ipv4": "10.99.0.5/24", "hostname": "mechrevo", "cost": "Local", "lat_ms": "-", "loss_rate": "-", "tunnel_proto": "-"},
            {"ipv4": "", "hostname": "PublicServer_cloud-seed", "cost": "p2p", "lat_ms": "34.5", "loss_rate": "0.0%", "tunnel_proto": "tcp,udp"},
            {"ipv4": "10.99.0.10/24", "hostname": "mac", "cost": "relay(2)", "lat_ms": "86.0", "loss_rate": "0.0%", "tunnel_proto": ""}
        ]"#;
        let route_json = r#"[
            {"ipv4": "10.99.0.10/24", "hostname": "mac", "next_hop_hostname": "PublicServer_cloud-seed"}
        ]"#;
        let peers = parse_easytier_transports(peer_json, Some(route_json));
        let mac = match_peer_transport(&peers, "10.99.0.10", Some("mac")).expect("mac peer");
        assert!(!mac.is_p2p);
        assert_eq!(mac.kind(), TransportKind::UdpRelay);
        assert!(!mac.is_tcp_relay());
        assert_eq!(mac.short_badge(), "UDP Relay");
        assert_eq!(mac.detailed_badge(), "UDP Relay · 86ms");
    }

    #[test]
    fn parse_transports_flags_pure_tcp_relay_and_inherits_hop_loss() {
        let peer_json = r#"[
            {"ipv4": "", "hostname": "PublicServer_cloud-seed", "cost": "p2p", "lat_ms": "165.4", "loss_rate": "48.0%", "tunnel_proto": "tcp"},
            {"ipv4": "10.99.0.5/24", "hostname": "mechrevo", "cost": "relay(2)", "lat_ms": "229.0", "loss_rate": "0.0%", "tunnel_proto": ""}
        ]"#;
        let route_json = r#"[
            {"ipv4": "10.99.0.5/24", "hostname": "mechrevo", "next_hop_hostname": "PublicServer_cloud-seed"}
        ]"#;
        let peers = parse_easytier_transports(peer_json, Some(route_json));
        let mech = match_peer_transport(&peers, "10.99.0.5", None).expect("mechrevo peer");
        assert!(mech.is_tcp_relay());
        assert_eq!(mech.short_badge(), "TCP Relay");
        assert_eq!(mech.detailed_badge(), "TCP Relay · 229ms · loss 48%");
    }
}

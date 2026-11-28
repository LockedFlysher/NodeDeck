use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::models::ControlPlaneClientCert;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostConfPatch {
    pub encoder: Option<String>,
    pub capture: Option<String>,
    pub adapter_name: Option<String>,
    pub port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SunshineServerInfo {
    pub hostname: String,
    pub app_version: String,
    pub gfe_version: String,
    pub https_port: u16,
    pub external_port: u16,
    pub codec_support: String,
    pub current_game: String,
    pub state: String,
}

/// Parses Sunshine/nodedeck-host `key = value` configuration files.
pub fn parse_host_conf(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            map.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    map
}

fn is_corrupted_shell_path(val: &str) -> bool {
    val.starts_with("/bin/bash/")
        || val.starts_with("/bin/sh/")
        || val.starts_with("/bin/zsh/")
        || val.starts_with("/bin/dash/")
}

/// Writes/updates `host.conf` while preserving existing certificate/state paths,
/// auto-repairing legacy `/bin/bash/.config/...` systemd `%s` corruption, and
/// preserving Wayland-compatible capture settings unless explicitly overridden.
pub fn write_host_conf(conf_dir: &Path, conf_path: &Path, patch: &HostConfPatch) -> std::io::Result<()> {
    fs::create_dir_all(conf_dir)?;
    let apps_path = conf_dir.join("apps.json");
    if !apps_path.exists() {
        fs::write(
            &apps_path,
            "{\n  \"env\": {},\n  \"apps\": [{ \"name\": \"Desktop\", \"image-path\": \"desktop.png\" }]\n}\n",
        )?;
    }

    let existing = fs::read_to_string(conf_path).unwrap_or_default();
    let mut cfg = parse_host_conf(&existing);

    let defaults = [
        ("file_apps", conf_dir.join("apps.json")),
        ("file_state", conf_dir.join("host_state.json")),
        ("credentials_file", conf_dir.join("credentials.json")),
        ("pkey", conf_dir.join("host.key")),
        ("cert", conf_dir.join("host.cert")),
    ];
    for (k, default_path) in defaults {
        let needs_repair = match cfg.get(k) {
            None => true,
            Some(v) => v.is_empty() || is_corrupted_shell_path(v),
        };
        if needs_repair {
            cfg.insert(k.to_string(), default_path.to_string_lossy().into_owned());
        }
    }
    cfg.entry("port".to_string()).or_insert_with(|| "47989".to_string());

    if let Some(enc) = &patch.encoder {
        if enc.is_empty() || enc.eq_ignore_ascii_case("auto") {
            cfg.remove("encoder");
        } else {
            cfg.insert("encoder".to_string(), enc.clone());
        }
    }
    if let Some(cap) = &patch.capture {
        if cap.is_empty() || cap.eq_ignore_ascii_case("auto") {
            cfg.remove("capture");
        } else {
            cfg.insert("capture".to_string(), cap.clone());
        }
    }
    if let Some(adapter) = &patch.adapter_name {
        if adapter.is_empty() || adapter.eq_ignore_ascii_case("auto") {
            cfg.remove("adapter_name");
        } else {
            cfg.insert("adapter_name".to_string(), adapter.clone());
        }
    }
    if let Some(port) = patch.port {
        cfg.insert("port".to_string(), port.to_string());
    }

    let rendered: String = cfg
        .iter()
        .map(|(k, v)| format!("{k} = {v}\n"))
        .collect();
    if let Some(parent) = conf_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(conf_path, rendered)
}

/// Resolves the active `file_state` JSON path from `host.conf` (checking `~/.config/nodedeck/host.conf`
/// first, then `~/.config/nodedeck/host/host.conf`).
pub fn resolve_state_file_path(conf_dir: &Path) -> PathBuf {
    for cand in [conf_dir.join("host.conf"), conf_dir.join("host").join("host.conf")] {
        if cand.exists() {
            if let Ok(txt) = fs::read_to_string(&cand) {
                let cfg = parse_host_conf(&txt);
                if let Some(state_str) = cfg.get("file_state") {
                    if !state_str.is_empty() && !is_corrupted_shell_path(state_str) {
                        return PathBuf::from(state_str);
                    }
                }
            }
        }
    }
    conf_dir.join("host_state.json")
}

/// Injects same-account Moonlight client certificates into Sunshine's `host_state.json`.
/// Returns `true` if any certificate was added or updated.
pub fn sync_client_certs_to_state(
    state_path: &Path,
    certs: &[ControlPlaneClientCert],
) -> std::io::Result<bool> {
    let mut doc: Value = fs::read_to_string(state_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({ "root": { "uniqueid": "0123456789ABCDEF", "named_devices": [] } }));

    if doc.get("root").is_none() {
        doc = json!({ "root": { "uniqueid": "0123456789ABCDEF", "named_devices": [] } });
    }
    let root = doc.get_mut("root").and_then(Value::as_object_mut).unwrap();
    if !root.get("named_devices").map(Value::is_array).unwrap_or(false) {
        root.insert("named_devices".to_string(), json!([]));
    }
    let devices = root
        .get_mut("named_devices")
        .and_then(Value::as_array_mut)
        .unwrap();

    let mut changed = false;
    for c in certs {
        let pem = c.cert_pem.trim();
        if pem.is_empty() || !pem.contains("BEGIN CERTIFICATE") {
            continue;
        }
        let name = if c.device_name.is_empty() {
            "NodeDeck".to_string()
        } else {
            format!("NodeDeck-{}", c.device_name)
        };
        let exists = devices.iter().any(|d| {
            d.get("cert")
                .and_then(Value::as_str)
                .map(|x| x.trim() == pem)
                .unwrap_or(false)
        });
        if !exists {
            devices.push(json!({
                "name": name,
                "cert": format!("{pem}\n"),
                "uuid": c.unique_id,
            }));
            changed = true;
        }
    }

    if changed {
        if let Some(parent) = state_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(state_path, serde_json::to_string_pretty(&doc).unwrap())?;
    }
    Ok(changed)
}

/// Lightweight tag extractor for Sunshine `/serverinfo` XML responses (avoids heavy XML deps).
pub fn parse_server_info_xml(xml: &str) -> SunshineServerInfo {
    SunshineServerInfo {
        hostname: extract_xml_tag(xml, "hostname").unwrap_or_default(),
        app_version: extract_xml_tag(xml, "appversion").unwrap_or_else(|| "7.1.431.0".to_string()),
        gfe_version: extract_xml_tag(xml, "GfeVersion").unwrap_or_else(|| "3.23.0.74".to_string()),
        https_port: extract_xml_tag(xml, "HttpsPort")
            .and_then(|s| s.parse().ok())
            .unwrap_or(47984),
        external_port: extract_xml_tag(xml, "ExternalPort")
            .and_then(|s| s.parse().ok())
            .unwrap_or(47989),
        codec_support: extract_xml_tag(xml, "ServerCodecModeSupport")
            .unwrap_or_else(|| "0".to_string()),
        current_game: extract_xml_tag(xml, "currentgame").unwrap_or_else(|| "0".to_string()),
        state: extract_xml_tag(xml, "state").unwrap_or_default(),
    }
}

fn extract_xml_tag(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&close)? + start;
    Some(xml[start..end].trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_host_conf_repairs_corrupted_bash_paths_and_preserves_wayland() {
        let tmp = std::env::temp_dir().join(format!("nd-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let conf = tmp.join("host.conf");
        fs::write(
            &conf,
            "port = 47989\nfile_state = /bin/bash/.config/nodedeck/host_state.json\npkey = /bin/bash/.config/nodedeck/host.key\n",
        )
        .unwrap();

        write_host_conf(
            &tmp,
            &conf,
            &HostConfPatch {
                encoder: Some("software".to_string()),
                capture: Some("auto".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        let parsed = parse_host_conf(&fs::read_to_string(&conf).unwrap());
        assert_eq!(parsed.get("encoder").map(String::as_str), Some("software"));
        assert!(!parsed.contains_key("capture"));
        assert!(!parsed["file_state"].starts_with("/bin/bash/"));
        assert!(parsed["file_state"].ends_with("host_state.json"));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn parses_sunshine_serverinfo_xml() {
        let xml = r#"<root status_code="200"><hostname>mechrevo</hostname><appversion>7.1.431.-1</appversion><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><currentgame>0</currentgame></root>"#;
        let info = parse_server_info_xml(xml);
        assert_eq!(info.hostname, "mechrevo");
        assert_eq!(info.https_port, 47984);
        assert_eq!(info.external_port, 47989);
    }
}

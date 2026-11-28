use serde::{Deserialize, Deserializer, Serialize};

pub const DEFAULT_CONTROL_PLANE_URL: &str = "https://lockedflysher.duckdns.org:8443/nodedeck-api";

fn deserialize_null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    T: Default + Deserialize<'de>,
    D: Deserializer<'de>,
{
    let opt = Option::deserialize(deserializer)?;
    Ok(opt.unwrap_or_default())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneUser {
    #[serde(default)]
    pub id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneMeshInfo {
    pub network_name: String,
    pub network_secret: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub subnet: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub seed_uri: String,
    #[serde(default = "default_listen_port")]
    pub listen_port: u16,
}

fn default_listen_port() -> u16 {
    28443
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneDevice {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub device_id: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub device_name: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub platform: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub role: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub virtual_ip: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub virtual_cidr: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub ssh_user: String,
    #[serde(default = "default_ssh_port")]
    pub ssh_port: u16,
    #[serde(default = "default_sunshine_http")]
    pub sunshine_http_port: u16,
    #[serde(default = "default_sunshine_https")]
    pub sunshine_https_port: u16,
    #[serde(default)]
    pub sunshine_enabled: bool,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub last_seen: i64,
}

fn default_ssh_port() -> u16 {
    22
}
fn default_sunshine_http() -> u16 {
    47989
}
fn default_sunshine_https() -> u16 {
    47984
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneClientCert {
    pub device_id: String,
    pub device_name: String,
    pub unique_id: String,
    pub cert_pem: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneSshKey {
    pub device_id: String,
    pub device_name: String,
    pub public_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlanePendingCommand {
    pub id: i64,
    pub action: String,
    #[serde(default)]
    pub requester_device_name: String,
    #[serde(default)]
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneStateResponse {
    pub token: Option<String>,
    pub user: ControlPlaneUser,
    pub device: ControlPlaneDevice,
    pub mesh: ControlPlaneMeshInfo,
    #[serde(default)]
    pub devices: Vec<ControlPlaneDevice>,
    #[serde(default)]
    pub client_certs: Vec<ControlPlaneClientCert>,
    #[serde(default)]
    pub ssh_public_keys: Vec<ControlPlaneSshKey>,
    #[serde(default)]
    pub pending_commands: Vec<ControlPlanePendingCommand>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneActivateResponse {
    pub command_id: i64,
    pub status: String,
    pub target_device: Option<ControlPlaneDevice>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlPlaneCommandStatus {
    pub id: i64,
    pub status: String,
    pub error: Option<String>,
    pub sunshine_http_port: Option<u16>,
    pub sunshine_https_port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccountSession {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub server_url: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub token: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub ssh_user: String,
    pub user: ControlPlaneUser,
    pub device: ControlPlaneDevice,
    pub mesh: ControlPlaneMeshInfo,
    #[serde(default)]
    pub devices: Vec<ControlPlaneDevice>,
    #[serde(default)]
    pub client_certs: Vec<ControlPlaneClientCert>,
    #[serde(default)]
    pub ssh_public_keys: Vec<ControlPlaneSshKey>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_real_python_account_json_without_user_id_and_with_null_ssh_user() {
        let raw = r#"{
            "server_url": "https://lockedflysher.duckdns.org:8443/nodedeck-api",
            "token": "tok123",
            "user": {"username": "sunnypea"},
            "device": {
                "device_id": "linux-mechrevo-123bf499",
                "device_name": "mechrevo",
                "platform": "linux",
                "role": "both",
                "virtual_ip": "10.99.0.5",
                "virtual_cidr": "10.99.0.5/24",
                "ssh_user": "sunnypea",
                "ssh_port": 22,
                "sunshine_http_port": 47989,
                "sunshine_https_port": 47984,
                "sunshine_enabled": true,
                "last_seen": 1795840000,
                "online": true
            },
            "mesh": {
                "network_name": "nd-sunnypea-14702d35",
                "network_secret": "sec",
                "subnet": "10.99.0.0/24",
                "seed_uri": "udp://lockedflysher.duckdns.org:25565,tcp://lockedflysher.duckdns.org:11010",
                "listen_port": 28443
            },
            "devices": [
                {
                    "device_id": "android-1",
                    "device_name": "android-v2405a",
                    "platform": "android",
                    "role": "controller",
                    "virtual_ip": "10.99.0.3",
                    "virtual_cidr": "10.99.0.3/24",
                    "ssh_user": null,
                    "ssh_port": 22,
                    "sunshine_http_port": 47989,
                    "sunshine_https_port": 47984,
                    "sunshine_enabled": false,
                    "last_seen": 1795840000,
                    "online": false
                }
            ]
        }"#;
        let sess: AccountSession = serde_json::from_str(raw).expect("must deserialize real account.json");
        assert_eq!(sess.user.username, "sunnypea");
        assert_eq!(sess.device.device_name, "mechrevo");
        assert_eq!(sess.devices[0].ssh_user, "");
    }
}

impl AccountSession {
    /// Parses both canonical Linux/Rust `account.json` and legacy macOS Swift camelCase `account.json`.
    pub fn parse_compat_json(raw: &str) -> Result<Self, serde_json::Error> {
        if let Ok(sess) = serde_json::from_str::<AccountSession>(raw) {
            return Ok(sess);
        }
        #[derive(Deserialize)]
        struct MacSwiftAccountJson {
            #[serde(rename = "serverUrl", default)]
            server_url: String,
            #[serde(default)]
            username: String,
            #[serde(default)]
            token: String,
            #[serde(rename = "deviceId", default)]
            device_id: String,
            #[serde(rename = "deviceName", default)]
            device_name: String,
            #[serde(rename = "virtualIp", default)]
            virtual_ip: String,
            #[serde(rename = "virtualCidr", default)]
            virtual_cidr: String,
            mesh: ControlPlaneMeshInfo,
        }
        let mac: MacSwiftAccountJson = serde_json::from_str(raw)?;
        let cidr = if mac.virtual_cidr.is_empty() && !mac.virtual_ip.is_empty() {
            format!("{}/24", mac.virtual_ip)
        } else {
            mac.virtual_cidr
        };
        Ok(AccountSession {
            server_url: mac.server_url,
            token: mac.token,
            ssh_user: std::env::var("USER").unwrap_or_else(|_| "mac".to_string()),
            user: ControlPlaneUser {
                id: 0,
                username: mac.username,
            },
            device: ControlPlaneDevice {
                device_id: mac.device_id,
                device_name: mac.device_name,
                platform: crate::platform::current_platform_name().to_string(),
                role: "both".to_string(),
                virtual_ip: mac.virtual_ip,
                virtual_cidr: cidr,
                ssh_user: std::env::var("USER").unwrap_or_else(|_| "mac".to_string()),
                ssh_port: 22,
                sunshine_http_port: 47989,
                sunshine_https_port: 47984,
                sunshine_enabled: true,
                online: true,
                last_seen: 0,
            },
            mesh: mac.mesh,
            devices: Vec::new(),
            client_certs: Vec::new(),
            ssh_public_keys: Vec::new(),
        })
    }

    pub fn from_response(
        server_url: &str,
        fallback_token: &str,
        ssh_user: &str,
        resp: ControlPlaneStateResponse,
    ) -> Self {
        Self {
            server_url: server_url.trim_end_matches('/').to_string(),
            token: resp
                .token
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| fallback_token.to_string()),
            ssh_user: ssh_user.to_string(),
            user: resp.user,
            device: resp.device,
            mesh: resp.mesh,
            devices: resp.devices,
            client_certs: resp.client_certs,
            ssh_public_keys: resp.ssh_public_keys,
        }
    }

    pub fn mesh_identity_key(&self) -> (String, String, String, String) {
        (
            self.mesh.network_name.clone(),
            self.mesh.network_secret.clone(),
            self.device.virtual_cidr.clone(),
            self.mesh.seed_uri.clone(),
        )
    }
}

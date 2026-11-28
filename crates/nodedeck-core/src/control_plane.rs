use reqwest::Client;
use serde_json::{json, Value};
use std::time::Duration;
use thiserror::Error;

use crate::models::{
    ControlPlaneActivateResponse, ControlPlaneCommandStatus, ControlPlaneStateResponse,
};

#[derive(Debug, Error)]
pub enum ControlPlaneError {
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("server error (HTTP {status}): {message}")]
    Server { status: u16, message: String },
}

/// Pure-Rust (`rustls`) Control Plane API client shared across macOS, Linux, and Android.
/// Zero dependency on host OpenSSL / LibreSSL libraries.
#[derive(Debug, Clone)]
pub struct ControlPlaneClient {
    http: Client,
}

impl Default for ControlPlaneClient {
    fn default() -> Self {
        Self::new()
    }
}

impl ControlPlaneClient {
    pub fn new() -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(15))
            .user_agent("NodeDeckCore/3.0")
            .build()
            .expect("failed to build rustls reqwest client");
        Self { http }
    }

    pub async fn register(
        &self,
        server_url: &str,
        username: &str,
        password: &str,
        invite_code: &str,
        device_id: &str,
        device_name: &str,
        platform: &str,
        role: &str,
        ssh_user: &str,
        lan_ips: &[String],
    ) -> Result<ControlPlaneStateResponse, ControlPlaneError> {
        let payload = json!({
            "username": username,
            "password": password,
            "invite_code": invite_code,
            "device_id": device_id,
            "device_name": device_name,
            "platform": platform,
            "role": role,
            "ssh_user": ssh_user,
            "ssh_port": 22,
            "lan_ips": lan_ips,
        });
        self.post_json(server_url, "/api/v1/auth/register", &payload, None)
            .await
    }

    pub async fn login(
        &self,
        server_url: &str,
        username: &str,
        password: &str,
        device_id: &str,
        device_name: &str,
        platform: &str,
        role: &str,
        ssh_user: &str,
        lan_ips: &[String],
    ) -> Result<ControlPlaneStateResponse, ControlPlaneError> {
        let payload = json!({
            "username": username,
            "password": password,
            "device_id": device_id,
            "device_name": device_name,
            "platform": platform,
            "role": role,
            "ssh_user": ssh_user,
            "ssh_port": 22,
            "lan_ips": lan_ips,
        });
        self.post_json(server_url, "/api/v1/auth/login", &payload, None)
            .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn heartbeat(
        &self,
        server_url: &str,
        token: &str,
        device_name: &str,
        platform: &str,
        role: &str,
        ssh_user: &str,
        ssh_port: u16,
        sunshine_http_port: u16,
        sunshine_https_port: u16,
        sunshine_enabled: bool,
        lan_ips: &[String],
    ) -> Result<ControlPlaneStateResponse, ControlPlaneError> {
        let payload = json!({
            "device_name": device_name,
            "platform": platform,
            "role": role,
            "ssh_user": ssh_user,
            "ssh_port": ssh_port,
            "sunshine_http_port": sunshine_http_port,
            "sunshine_https_port": sunshine_https_port,
            "sunshine_enabled": sunshine_enabled,
            "lan_ips": lan_ips,
        });
        self.post_json(server_url, "/api/v1/devices/heartbeat", &payload, Some(token))
            .await
    }

    pub async fn register_client_cert(
        &self,
        server_url: &str,
        token: &str,
        device_name: &str,
        unique_id: &str,
        cert_pem: &str,
    ) -> Result<(), ControlPlaneError> {
        let payload = json!({
            "device_name": device_name,
            "unique_id": unique_id,
            "cert_pem": cert_pem,
        });
        let _: Value = self
            .post_json(server_url, "/api/v1/certs/register", &payload, Some(token))
            .await?;
        Ok(())
    }

    pub async fn register_ssh_public_key(
        &self,
        server_url: &str,
        token: &str,
        device_name: &str,
        public_key: &str,
    ) -> Result<(), ControlPlaneError> {
        let payload = json!({
            "device_name": device_name,
            "public_key": public_key,
        });
        let _: Value = self
            .post_json(server_url, "/api/v1/ssh-keys/register", &payload, Some(token))
            .await?;
        Ok(())
    }

    pub async fn activate_device(
        &self,
        server_url: &str,
        token: &str,
        target_name: &str,
        target_ip: &str,
        action: &str,
    ) -> Result<ControlPlaneActivateResponse, ControlPlaneError> {
        let payload = json!({
            "target_device_id": "",
            "target_name": target_name,
            "target_ip": target_ip,
            "action": action,
        });
        self.post_json(server_url, "/api/v1/devices/activate", &payload, Some(token))
            .await
    }

    pub async fn get_command_status(
        &self,
        server_url: &str,
        token: &str,
        command_id: i64,
    ) -> Result<ControlPlaneCommandStatus, ControlPlaneError> {
        let base = server_url.trim_end_matches('/');
        let url = format!("{base}/api/v1/commands/{command_id}");
        let resp = self
            .http
            .get(url)
            .bearer_auth(token)
            .send()
            .await?;
        decode_response(resp).await
    }

    pub async fn ack_command(
        &self,
        server_url: &str,
        token: &str,
        command_id: i64,
        status: &str,
        result: Value,
    ) -> Result<(), ControlPlaneError> {
        let payload = json!({
            "status": status,
            "result": result,
        });
        let _: Value = self
            .post_json(
                server_url,
                &format!("/api/v1/commands/{command_id}/ack"),
                &payload,
                Some(token),
            )
            .await?;
        Ok(())
    }

    async fn post_json<T: serde::de::DeserializeOwned>(
        &self,
        server_url: &str,
        path: &str,
        payload: &Value,
        token: Option<&str>,
    ) -> Result<T, ControlPlaneError> {
        let base = server_url.trim_end_matches('/');
        let url = format!("{base}{path}");
        let mut req = self.http.post(url).json(payload);
        if let Some(tok) = token {
            if !tok.is_empty() {
                req = req.bearer_auth(tok);
            }
        }
        let resp = req.send().await?;
        decode_response(resp).await
    }
}

async fn decode_response<T: serde::de::DeserializeOwned>(
    resp: reqwest::Response,
) -> Result<T, ControlPlaneError> {
    let status = resp.status();
    let bytes = resp.bytes().await?;
    if !status.is_success() {
        let msg = serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|v| v.get("error").and_then(Value::as_str).map(ToString::to_string))
            .unwrap_or_else(|| String::from_utf8_lossy(&bytes).into_owned());
        return Err(ControlPlaneError::Server {
            status: status.as_u16(),
            message: msg,
        });
    }
    serde_json::from_slice(&bytes).map_err(|e| ControlPlaneError::Server {
        status: status.as_u16(),
        message: format!("invalid JSON response: {e}"),
    })
}

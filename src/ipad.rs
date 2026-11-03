//! iPad backend: bridge to the local `ipad-remote` server (Frida over USB).
//!
//! The Go bridge owns the Frida sessions on the iPad and exposes:
//!   - HTTP  :8765  status / input / wake / unlock
//!   - TCP   :8767  length-prefixed JPEG frames (one per capture)
//! The UU host treats the iPad as its desktop: video comes from :8767, input goes
//! back over HTTP, and the lock screen password is unlocked through the bridge.

use std::time::Duration;

pub fn base_url() -> String {
    std::env::var("UU_IPAD_URL").unwrap_or_else(|_| "http://127.0.0.1:8765".into())
}

pub fn raw_addr() -> String {
    std::env::var("UU_IPAD_RAW").unwrap_or_else(|_| "127.0.0.1:8767".into())
}

#[derive(Clone, Copy, Debug)]
pub struct Info {
    pub width: u32,
    pub height: u32,
    pub locked: bool,
}

fn blocking_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(4))
        .build()
        .map_err(|e| e.to_string())
}

fn parse_status(text: &str) -> Result<Info, String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let screen = value.get("screen").ok_or("iPad status has no screen")?;
    let width = screen.get("width").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    let height = screen.get("height").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    if width == 0 || height == 0 {
        return Err("iPad screen size unavailable".into());
    }
    let locked = value
        .get("error")
        .and_then(|v| v.as_str())
        .is_some_and(|e| e.contains("locked"));
    Ok(Info { width, height, locked })
}

pub fn info_blocking() -> Result<Info, String> {
    let text = blocking_client()?
        .get(format!("{}/api/status", base_url()))
        .send()
        .map_err(|e| e.to_string())?
        .text()
        .map_err(|e| e.to_string())?;
    parse_status(&text)
}

pub fn locked_blocking() -> Option<bool> {
    info_blocking().ok().map(|info| info.locked)
}

pub fn post_blocking(path: &str, body: serde_json::Value) -> Result<(), String> {
    let response = blocking_client()?
        .post(format!("{}{}", base_url(), path))
        .json(&body)
        .send()
        .map_err(|e| e.to_string())?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(format!("iPad bridge {path}: HTTP {}", response.status()))
    }
}

pub fn wake_blocking() -> Result<(), String> {
    post_blocking("/api/wake", serde_json::json!({}))
}

/// Unlocks with the passcode and confirms the lock screen actually went away.
pub fn unlock_blocking(password: &str) -> Result<bool, String> {
    post_blocking("/api/unlock", serde_json::json!({ "passcode": password }))?;
    for _ in 0..30 {
        if locked_blocking() == Some(false) {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(false)
}

/// Fire-and-forget input from the sync injector; never blocks the caller.
pub fn input(path: &'static str, body: serde_json::Value) {
    let url = format!("{}{}", base_url(), path);
    tokio::spawn(async move {
        let _ = reqwest::Client::new().post(url).json(&body).send().await;
    });
}

pub fn tap(x: f64, y: f64) { input("/api/tap", serde_json::json!({ "x": x, "y": y })); }
pub fn down(x: f64, y: f64) { input("/api/down", serde_json::json!({ "x": x, "y": y })); }
pub fn up(x: f64, y: f64) { input("/api/up", serde_json::json!({ "x": x, "y": y })); }
pub fn movement(x: f64, y: f64) { input("/api/move", serde_json::json!({ "x": x, "y": y })); }

pub struct FrameStream {
    stream: tokio::net::TcpStream,
}

impl FrameStream {
    pub async fn connect() -> Result<Self, String> {
        let addr = raw_addr();
        for _ in 0..50 {
            match tokio::net::TcpStream::connect(&addr).await {
                Ok(stream) => {
                    let _ = stream.set_nodelay(true);
                    return Ok(Self { stream });
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
        Err(format!("iPad frame stream {addr} unavailable"))
    }

    pub async fn next_frame(&mut self) -> Result<Vec<u8>, String> {
        use tokio::io::AsyncReadExt;
        let mut header = [0u8; 4];
        self.stream.read_exact(&mut header).await.map_err(|e| e.to_string())?;
        let size = u32::from_be_bytes(header) as usize;
        if size == 0 || size > 32 * 1024 * 1024 {
            return Err("iPad frame size invalid".into());
        }
        let mut frame = vec![0u8; size];
        self.stream.read_exact(&mut frame).await.map_err(|e| e.to_string())?;
        Ok(frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_parses_size_and_lock() {
        let info = parse_status(r#"{"connected":true,"error":"Error: locked","screen":{"width":1024,"height":1366}}"#).unwrap();
        assert_eq!((info.width, info.height, info.locked), (1024, 1366, true));
        let info = parse_status(r#"{"connected":true,"error":"","screen":{"width":1024,"height":1366}}"#).unwrap();
        assert!(!info.locked);
    }
}

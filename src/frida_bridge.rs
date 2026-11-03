//! FFI + RPC client for the frida-core bridge (iOS host only).

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

extern "C" {
    fn uu_frida_start(
        address: *const c_char,
        process: *const c_char,
        source: *const c_char,
        cb: extern "C" fn(*const c_char, *const c_void, usize, *mut c_void),
        user: *mut c_void,
        timeout_ms: i32,
    ) -> *mut c_void;
    fn uu_frida_post(handle: *mut c_void, json: *const c_char);
    fn uu_frida_stop(handle: *mut c_void);
}

#[derive(Default)]
struct Shared {
    rpc: HashMap<String, String>,
    frames: Vec<Vec<u8>>,
}

static SHARED: OnceLock<(Mutex<Shared>, Condvar)> = OnceLock::new();
fn shared() -> &'static (Mutex<Shared>, Condvar) {
    SHARED.get_or_init(|| (Mutex::new(Shared::default()), Condvar::new()))
}

extern "C" fn on_message(message: *const c_char, data: *const c_void, len: usize, _user: *mut c_void) {
    if message.is_null() { return; }
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
    let value: serde_json::Value = match serde_json::from_str(&text) { Ok(v) => v, Err(_) => return };
    if let Some(payload) = value.get("payload").and_then(|p| p.as_array()) {
    if payload.first().and_then(|v| v.as_str()) == Some("frida:rpc") {
        let id = payload.get(1).and_then(|v| v.as_str()).unwrap_or("").to_string();
        let status = payload.get(2).and_then(|v| v.as_str()).unwrap_or("error");
        let result = payload.get(3).cloned().unwrap_or(serde_json::Value::Null);
        let encoded = if status == "error" {
            format!("{{\"__error\":{}}}", serde_json::to_string(&result).unwrap_or_else(|_| "null".into()))
        } else {
            serde_json::to_string(&result).unwrap_or_else(|_| "null".into())
        };
        let (lock, cond) = shared();
        lock.lock().unwrap().rpc.insert(id, encoded);
        cond.notify_all();
    }
    return;
    }
    if value.get("type").and_then(|v| v.as_str()) == Some("send")
        && value.get("payload").and_then(|p| p.get("type")).and_then(|v| v.as_str()) == Some("frame")
        && !data.is_null() && len > 0
    {
        let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, len) }.to_vec();
        let (lock, cond) = shared();
        lock.lock().unwrap().frames.push(bytes);
        cond.notify_all();
    }
}

pub struct Script { handle: *mut c_void, seq: u64 }

// The frida handle is used from one task at a time behind the platform mutex.
unsafe impl Send for Script {}

impl Script {
    pub fn load(address: &str, process: &str, source: &str) -> Result<Self, String> {
        let address = CString::new(address).unwrap();
        let process = CString::new(process).unwrap();
        let source = CString::new(source).unwrap();
        let handle = unsafe { uu_frida_start(address.as_ptr(), process.as_ptr(), source.as_ptr(), on_message, std::ptr::null_mut(), 15000) };
        if handle.is_null() { Err(format!("frida: attach {process:?} failed")) } else { Ok(Self { handle, seq: 0 }) }
    }

    pub fn call(&mut self, function: &str, args_json: &str) -> Result<String, String> {
        // Two scripts (screen, HID) talk over the same message channel; ids must be unique across them.
        static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        self.seq += 1;
        let id = format!("{:016x}", NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        let msg = format!("[\"frida:rpc\",\"{}\",\"call\",\"{}\",{}]", id, function, args_json);
        let cmsg = CString::new(msg).map_err(|e| e.to_string())?;
        unsafe { uu_frida_post(self.handle, cmsg.as_ptr()) };
        let (lock, cond) = shared();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut guard = lock.lock().unwrap();
        loop {
            if let Some(value) = guard.rpc.remove(&id) {
                if value.starts_with("{\"__error\":") { return Err(value); }
                return Ok(value);
            }
            let now = Instant::now();
            if now >= deadline { return Err("frida rpc timeout".into()); }
            let (next, _) = cond.wait_timeout(guard, deadline - now).unwrap();
            guard = next;
        }
    }

    pub fn take_frame(timeout: Duration) -> Option<Vec<u8>> {
        let (lock, cond) = shared();
        let deadline = Instant::now() + timeout;
        let mut guard = lock.lock().unwrap();
        loop {
            if !guard.frames.is_empty() {
                // Newest frame wins; anything older is stale for a live stream.
                let frame = guard.frames.pop();
                guard.frames.clear();
                return frame;
            }
            let now = Instant::now();
            if now >= deadline { return None; }
            let (next, _) = cond.wait_timeout(guard, deadline - now).unwrap();
            guard = next;
        }
    }
}

impl Drop for Script {
    fn drop(&mut self) {
        unsafe { uu_frida_stop(self.handle) };
    }
}

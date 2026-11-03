//! iPad platform layer for the host: frida-core agents on SpringBoard/backboardd.

use crate::frida_bridge::Script;
use std::sync::{Mutex, OnceLock};
use std::io::Read as _;
use std::time::Duration;

fn agent(js: &str) -> String {
    format!("{}\nvar ObjC = bridge;\n{}", include_str!("../ios/agent/objc.js"), js)
}

struct Links {
    screen: Mutex<Option<Script>>,
    hid: Mutex<Option<Script>>,
}

static LINKS: OnceLock<Links> = OnceLock::new();
fn links() -> &'static Links {
    LINKS.get_or_init(|| Links { screen: Mutex::new(None), hid: Mutex::new(None) })
}

fn address() -> String {
    std::env::var("UU_FRIDA_ADDR").unwrap_or_else(|_| "127.0.0.1:27042".into())
}

/// A respring or backboardd restart kills the injected script; drop it on timeout so the next call re-attaches.
fn call_link<T>(slot: &Mutex<Option<Script>>, process: &str, source: &str, f: impl FnOnce(&mut Script) -> Result<T, String>) -> Result<T, String> {
    let mut guard = slot.lock().map_err(|_| "frida link lock poisoned")?;
    if guard.is_none() {
        *guard = Some(Script::load(&address(), process, &agent(source))?);
    }
    let result = f(guard.as_mut().unwrap());
    if matches!(&result, Err(e) if e == "frida rpc timeout") {
        log::warn!("frida {process} script stopped answering; re-attaching on the next call");
        *guard = None;
    }
    result
}

fn with_screen<T>(f: impl FnOnce(&mut Script) -> Result<T, String>) -> Result<T, String> {
    call_link(&links().screen, "SpringBoard", include_str!("../ios/agent/screen.js"), f)
}

fn with_hid<T>(f: impl FnOnce(&mut Script) -> Result<T, String>) -> Result<T, String> {
    call_link(&links().hid, "backboardd", include_str!("../ios/agent/hid.js"), f)
}

/// Last pointer position, normalized 0..1. The iPad has no cursor: taps and drags use this.
static POSITION: Mutex<(f64, f64)> = Mutex::new((0.5, 0.5));

pub fn set_position(x: f64, y: f64) {
    if let Ok(mut position) = POSITION.lock() { *position = (x, y); }
}

pub fn position() -> (f64, f64) {
    POSITION.lock().map(|p| *p).unwrap_or((0.5, 0.5))
}

extern "C" {
    fn memorystatus_control(command: u32, pid: i32, flags: u32, buffer: *mut std::ffi::c_void, size: usize) -> i32;
}

#[repr(C)]
struct MemlimitProperties { active: i32, active_attr: u32, inactive: i32, inactive_attr: u32 }

/// launchd daemons get an 18 MB jetsam limit (fatal); one desktop stream needs far more, so the
/// kernel SIGKILLs the host as soon as a viewer connects. Root may lift its own limit.
pub fn lift_memory_limit() {
    const SET_JETSAM_HIGH_WATER_MARK: u32 = 5;
    const SET_MEMLIMIT_PROPERTIES: u32 = 7;
    const LIMIT_MB: i32 = 1024;
    let pid = std::process::id() as i32;
    let mut props = MemlimitProperties { active: LIMIT_MB, active_attr: 0, inactive: LIMIT_MB, inactive_attr: 0 };
    let set = unsafe { memorystatus_control(SET_MEMLIMIT_PROPERTIES, pid, 0, (&mut props as *mut MemlimitProperties).cast(), std::mem::size_of::<MemlimitProperties>()) };
    let mark = unsafe { memorystatus_control(SET_JETSAM_HIGH_WATER_MARK, pid, LIMIT_MB as u32, std::ptr::null_mut(), 0) };
    log::info!("iPad memory limit: limit_mb={LIMIT_MB} properties_ok={} high_water_ok={}", set == 0, mark == 0);
}

#[derive(Clone, Copy, Debug)]
pub struct Info { pub width: u32, pub height: u32 }

pub fn info() -> Result<Info, String> {
    let value = with_screen(|s| s.call("info", "[]"))?;
    let json: serde_json::Value = serde_json::from_str(&value).map_err(|e| e.to_string())?;
    // UIScreen reports points; the captured IOSurface is in pixels.
    let scale = json.get("scale").and_then(|v| v.as_f64()).unwrap_or(1.0).max(1.0);
    let points_w = json.get("width").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let points_h = json.get("height").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let width = (points_w * scale).round() as u32;
    let height = (points_h * scale).round() as u32;
    if width == 0 || height == 0 { return Err("iPad screen size unavailable".into()); }
    Ok(Info { width, height })
}

pub fn screen_on() -> Option<bool> {
    let value = with_screen(|s| s.call("screenon", "[]")).ok()?;
    Some(value.contains("true"))
}

pub fn locked() -> Option<bool> {
    let value = with_screen(|s| s.call("locked", "[]")).ok()?;
    Some(value.contains("true"))
}

pub fn wake() -> Result<(), String> {
    with_screen(|s| s.call("wake", "[]")).map(|_| ())
}

extern "C" {
    fn notify_register_check(name: *const std::ffi::c_char, token: *mut i32) -> u32;
    fn notify_get_state(token: i32, state: *mut u64) -> u32;
}

/// SpringBoard publishes 1 while the panel is dark. `SBBacklightController.screenIsOn` and
/// `backlightState` stay true/1 on iPadOS 16+ even when the display is asleep.
pub fn screen_blanked() -> Option<bool> {
    static TOKEN: OnceLock<Option<i32>> = OnceLock::new();
    let token = (*TOKEN.get_or_init(|| {
        let mut token = 0;
        let ok = unsafe { notify_register_check(c"com.apple.springboard.hasBlankedScreen".as_ptr(), &mut token) } == 0;
        ok.then_some(token)
    }))?;
    let mut state = 0u64;
    (unsafe { notify_get_state(token, &mut state) } == 0).then_some(state != 0)
}

static LAST_INPUT: Mutex<Option<std::time::Instant>> = Mutex::new(None);
fn note_input() { if let Ok(mut last) = LAST_INPUT.lock() { *last = Some(std::time::Instant::now()); } }
fn input_within(window: Duration) -> bool {
    LAST_INPUT.lock().ok().and_then(|l| *l).is_some_and(|at| at.elapsed() < window)
}

/// Wakes the panel for a viewer when it is dark or the picture is frozen (`stale`: the capture has
/// returned the same frame for seconds). SpringBoard's undim is tried first; then an upward swipe,
/// which on the lock screen lights the panel and opens the passcode pad. The swipe is only used while
/// locked (unlocked, it would leave the foreground app), never right after viewer input, and at most
/// once a minute so a static passcode pad is not dismissed again.
/// `hasBlankedScreen` alone is not enough: on this iPad it stayed 0 while the panel was dark.
pub fn wake_display(stale: bool) -> bool {
    static LAST_SWIPE: Mutex<Option<std::time::Instant>> = Mutex::new(None);
    let blank = screen_blanked() == Some(true);
    if !blank && !stale { return false; }
    let _ = wake();
    if blank {
        for _ in 0..10 {
            std::thread::sleep(Duration::from_millis(100));
            if screen_blanked() == Some(false) { log::info!("iPad display woken (SpringBoard)"); return true; }
        }
    }
    if locked() != Some(true) || input_within(Duration::from_secs(8)) { return false; }
    let Ok(mut last) = LAST_SWIPE.lock() else { return false };
    if last.is_some_and(|at| at.elapsed() < Duration::from_secs(60)) { return false; }
    *last = Some(std::time::Instant::now());
    drop(last);
    let swiped = home().is_ok();
    log::info!("iPad display wake by swipe: blank={blank} stale={stale} injected={swiped}");
    swiped
}

pub fn unlock(passcode: &str) -> Result<bool, String> {
    let args = serde_json::to_string(&[passcode]).map_err(|e| e.to_string())?;
    with_screen(|s| s.call("unlock", &args))?;
    for _ in 0..30 {
        if locked() == Some(false) { return Ok(true); }
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(false)
}

/// Lock-screen passcode saved by the panel app (owner mobile, 0600). Read only to unlock.
const PASSCODE_PATH: &str = "/var/mobile/Library/UURemote/unlock.key";
/// Last auto-unlock outcome, shown by the panel app.
const UNLOCK_STATUS_PATH: &str = "/private/var/tmp/uu-unlock.txt";

/// Unlocks a locked iPad with the passcode saved in the panel app. Returns None when nothing was
/// attempted. A rejected passcode is not tried again until the panel saves a new one: repeated
/// wrong attempts make iPadOS disable the device for growing intervals.
pub fn auto_unlock() -> Option<bool> {
    use std::os::unix::fs::MetadataExt;
    static REJECTED: Mutex<Option<std::time::SystemTime>> = Mutex::new(None);
    if locked() != Some(true) { return None; }
    let meta = std::fs::metadata(PASSCODE_PATH).ok()?;
    // Another user being able to read or replace it means it was not written by the panel.
    if meta.mode() & 0o077 != 0 || (meta.uid() != 0 && meta.uid() != 501) { return None; }
    let stamp = meta.modified().ok()?;
    if *REJECTED.lock().ok()? == Some(stamp) { return None; }
    let mut passcode = std::fs::read_to_string(PASSCODE_PATH).ok()?;
    let length = passcode.trim_end_matches(['\r', '\n']).len();
    passcode.truncate(length);
    if passcode.is_empty() { return None; }
    let _ = wake();
    let result = unlock(&passcode);
    unsafe { passcode.as_bytes_mut().fill(0); }
    let outcome = match result {
        Ok(true) => { log::info!("iPad auto unlock: unlocked with the saved passcode"); Some(true) }
        Ok(false) => {
            log::warn!("iPad auto unlock: saved passcode not accepted; not retrying until it is saved again");
            *REJECTED.lock().ok()? = Some(stamp);
            Some(false)
        }
        Err(error) => { log::warn!("iPad auto unlock failed: {error}"); None }
    };
    if let Some(ok) = outcome {
        let _ = std::fs::write(UNLOCK_STATUS_PATH, format!("{} {}\n", if ok { "ok" } else { "rejected" },
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)));
    }
    outcome
}

/// Path the SpringBoard agent writes each JPEG to (real path, not roothide's jbroot view).
const FRAME_PATH: &str = "/var/mobile/Library/Caches/uu-frame.jpg";

pub fn capture_jpeg(quality: f64) -> Result<Vec<u8>, String> {
    let args = format!("[{quality}]");
    let length: usize = with_screen(|s| s.call("capture", &args))?.parse().unwrap_or(0);
    let frame = std::fs::read(FRAME_PATH).map_err(|e| format!("read {FRAME_PATH}: {e}"))?;
    if frame.is_empty() { return Err("SpringBoard wrote an empty frame".into()); }
    if length != 0 && frame.len() != length { log::debug!("iPad frame size {} vs reported {}", frame.len(), length); }
    Ok(frame)
}

pub fn tap(x: f64, y: f64) -> Result<(), String> { note_input(); with_hid(|s| s.call("tap", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn down(x: f64, y: f64) -> Result<(), String> { note_input(); with_hid(|s| s.call("down", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn move_to(x: f64, y: f64) -> Result<(), String> { note_input(); with_hid(|s| s.call("move", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn up(x: f64, y: f64) -> Result<(), String> { note_input(); with_hid(|s| s.call("up", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn swipe(x1: f64, y1: f64, x2: f64, y2: f64, ms: u32) -> Result<(), String> {
    note_input();
    with_hid(|s| s.call("swipe", &format!("[{x1},{y1},{x2},{y2},{ms}]"))).map(|_| ())
}
pub fn home() -> Result<(), String> { with_hid(|s| s.call("home", "[]")).map(|_| ()) }

/// The keyboard Home button (consumer page Menu). Unlocked, iPadOS ignores a synthesized
/// home-indicator swipe, and Cmd+H is not a system shortcut since iPadOS 15 (it is Globe+H).
pub fn home_button() -> Result<(), String> { note_input(); with_hid(|s| s.call("button", "[64]")).map(|_| ()) }

/// A press in the bottom band of the panel is held back: dragged upward it presses Home (what the
/// home-indicator swipe does on the iPad itself); released in place it is a plain tap where it was.
const BOTTOM_BAND: f64 = 0.96;
const HOME_DRAG: f64 = 0.04;
#[derive(Clone, Copy)]
enum BottomPress { Pending(f64, f64), Fired }
static BOTTOM_PRESS: Mutex<Option<BottomPress>> = Mutex::new(None);

pub fn pointer_down(x: f64, y: f64) -> Result<(), String> {
    if y >= BOTTOM_BAND {
        note_input();
        if let Ok(mut press) = BOTTOM_PRESS.lock() { *press = Some(BottomPress::Pending(x, y)); }
        return Ok(());
    }
    down(x, y)
}

pub fn pointer_move(x: f64, y: f64) -> Result<(), String> {
    let press = BOTTOM_PRESS.lock().ok().and_then(|p| *p);
    match press {
        Some(BottomPress::Pending(_, sy)) if sy - y >= HOME_DRAG => {
            if let Ok(mut press) = BOTTOM_PRESS.lock() { *press = Some(BottomPress::Fired); }
            log::info!("iPad home gesture: bottom-edge drag");
            home_button()
        }
        Some(_) => Ok(()), // waiting for the drag, or Home already pressed for this drag
        None => move_to(x, y),
    }
}

pub fn pointer_up(x: f64, y: f64) -> Result<(), String> {
    let press = BOTTOM_PRESS.lock().ok().and_then(|mut p| p.take());
    match press {
        Some(BottomPress::Pending(sx, sy)) => tap(sx, sy),
        Some(BottomPress::Fired) => Ok(()),
        None => up(x, y),
    }
}

/// USB HID keyboard usage (page 0x07) for an X11 keysym.
pub fn keysym_usage(symbol: u64) -> Option<u32> {
    let usage = match symbol {
        0x20 => 0x2c,
        0x30 => 0x27, // 0
        0x31..=0x39 => 0x1e + (symbol as u32 - 0x31),
        0x61..=0x7a => 0x04 + (symbol as u32 - 0x61),
        0x2d => 0x2d, 0x3d => 0x2e, 0x5b => 0x2f, 0x5d => 0x30, 0x5c => 0x31,
        0x3b => 0x33, 0x27 => 0x34, 0x60 => 0x35, 0x2c => 0x36, 0x2e => 0x37, 0x2f => 0x38,
        0xff0d => 0x28, 0xff08 => 0x2a, 0xff09 => 0x2b, 0xff1b => 0x29, 0xffff => 0x4c,
        0xff63 => 0x49, 0xff50 => 0x4a, 0xff57 => 0x4d, 0xff55 => 0x4b, 0xff56 => 0x4e,
        0xff51 => 0x50, 0xff52 => 0x52, 0xff53 => 0x4f, 0xff54 => 0x51,
        0xffe1 => 0xe1, 0xffe2 => 0xe5, 0xffe3 => 0xe0, 0xffe4 => 0xe4,
        0xffe9 => 0xe2, 0xffea => 0xe6, 0xffeb => 0xe3, 0xffec => 0xe7, 0xffe5 => 0x39,
        0xffbe..=0xffc9 => 0x3a + (symbol as u32 - 0xffbe),
        // Numpad digits as top-row digits: iPadOS has no NumLock and the passcode pad takes these.
        0xffb0 => 0x27,
        0xffb1..=0xffb9 => 0x1e + (symbol as u32 - 0xffb1),
        0xff8d => 0x28, 0xffae => 0x37, 0xffac => 0x36, // KP_Enter, KP_Decimal, KP_Separator
        0xffaa => 0x55, 0xffab => 0x57, 0xffad => 0x56, 0xffaf => 0x54, // KP * + - /
        0xff7f => 0x53, 0xff14 => 0x47, 0xff13 => 0x48, 0xff61 => 0x46, 0xff67 => 0x65, // Num/Scroll Lock, Pause, Print, Menu
        _ => return None,
    };
    Some(usage)
}

pub fn kbinfo() -> Result<String, String> { with_hid(|s| s.call("kbinfo", "[]")) }
pub fn senders() -> Result<String, String> { with_hid(|s| s.call("senders", "[]")) }

pub fn key(usage: u32, down: bool) -> Result<(), String> {
    // UU_KSENDER pins the HID sender id while bringing up keyboard injection.
    note_input();
    let sender = std::env::var("UU_KSENDER").unwrap_or_else(|_| "0".into());
    with_hid(|s| s.call("key", &format!("[{usage},{},\"{sender}\"]", u8::from(down)))).map(|_| ())
}

/// US-layout character: HID usage plus whether Shift must be held.
fn char_key(c: char) -> Option<(u32, bool)> {
    let key = match c {
        'a'..='z' => (0x04 + (c as u32 - 'a' as u32), false),
        'A'..='Z' => (0x04 + (c as u32 - 'A' as u32), true),
        '1'..='9' => (0x1e + (c as u32 - '1' as u32), false),
        '0' => (0x27, false),
        ' ' => (0x2c, false),
        '-' => (0x2d, false), '_' => (0x2d, true),
        '=' => (0x2e, false), '+' => (0x2e, true),
        '[' => (0x2f, false), '{' => (0x2f, true),
        ']' => (0x30, false), '}' => (0x30, true),
        '\\' => (0x31, false), '|' => (0x31, true),
        ';' => (0x33, false), ':' => (0x33, true),
        '\'' => (0x34, false), '"' => (0x34, true),
        '`' => (0x35, false), '~' => (0x35, true),
        ',' => (0x36, false), '<' => (0x36, true),
        '.' => (0x37, false), '>' => (0x37, true),
        '/' => (0x38, false), '?' => (0x38, true),
        '!' => (0x1e, true), '@' => (0x1f, true), '#' => (0x20, true), '$' => (0x21, true),
        '%' => (0x22, true), '^' => (0x23, true), '&' => (0x24, true), '*' => (0x25, true),
        '(' => (0x26, true), ')' => (0x27, true),
        '\n' | '\r' => (0x28, false), '\t' => (0x2b, false),
        _ => return None,
    };
    Some(key)
}

const HID_SHIFT: u32 = 0xe1;

/// Types a string as US-layout key events (mobile IME text).
pub fn type_text(text: &str) -> Result<(), String> {
    for c in text.chars() {
        let Some((usage, shift)) = char_key(c) else { continue };
        if shift { key(HID_SHIFT, true)?; }
        key(usage, true)?;
        key(usage, false)?;
        if shift { key(HID_SHIFT, false)?; }
    }
    Ok(())
}

pub fn fire_input(path: &'static str, body: serde_json::Value) {
    let _ = (path, body);
}

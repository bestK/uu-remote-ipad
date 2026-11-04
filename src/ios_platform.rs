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

static ORIENTATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Interface orientation of the captured content (UIInterfaceOrientation, 1..=4).
pub fn orientation() -> u64 { ORIENTATION.load(std::sync::atomic::Ordering::Relaxed) }

/// Diagnostics: every orientation source SpringBoard exposes (enum values only).
pub fn orientation_debug() -> Result<String, String> { with_screen(|s| s.call("orientationdebug", "[]")) }

/// Live screen size and orientation. A connection can start long after the host did, with the
/// iPad rotated since: never announce the startup geometry.
pub fn refresh_size(fallback: (u32, u32)) -> (u32, u32) {
    info().map(|info| (info.width, info.height)).unwrap_or(fallback)
}

#[derive(Clone, Copy, Debug)]
pub struct Info { pub width: u32, pub height: u32 }

pub fn info() -> Result<Info, String> {
    let value = with_screen(|s| s.call("info", "[]"))?;
    let json: serde_json::Value = serde_json::from_str(&value).map_err(|e| e.to_string())?;
    // UIInterfaceOrientation of the captured content; the surface itself stays in portrait pixels.
    if let Some(orientation) = json.get("status_orientation").and_then(|v| v.as_u64()).filter(|v| (1..=4).contains(v)) {
        ORIENTATION.store(orientation, std::sync::atomic::Ordering::Relaxed);
    }
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

/// Cycles the iPad's input sources, what the Globe key does with a hardware keyboard.
pub fn next_input_mode() -> Result<String, String> { with_screen(|s| s.call("nextinputmode", "[]")) }

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

/// Files the panel app reads: the live status and the last sessions. Timestamps and counts only,
/// never anything typed, copied or shown on the iPad.
const STATUS_JSON: &str = "/private/var/tmp/uu-status.json";
const HISTORY_JSONL: &str = "/private/var/tmp/uu-history.jsonl";
const HISTORY_KEEP: usize = 20;

static VIEWERS: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
static SESSION_START: Mutex<Option<std::time::Instant>> = Mutex::new(None);
static LAST_END: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn epoch() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn signed_in() -> bool {
    crate::config::read_fresh().ok().flatten()
        .and_then(|c| c.get("token").and_then(|t| t.as_str()).map(|t| !t.is_empty())).unwrap_or(false)
}

fn write_status() {
    let status = serde_json::json!({
        "signed_in": signed_in(),
        "viewers": VIEWERS.load(std::sync::atomic::Ordering::Relaxed),
        "last_session_end": LAST_END.load(std::sync::atomic::Ordering::Relaxed),
        "updated": epoch(),
    });
    let _ = std::fs::write(STATUS_JSON, status.to_string());
}

/// A desktop session came up: count it and note when it started.
pub fn note_session_started() {
    VIEWERS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    if let Ok(mut start) = SESSION_START.lock() { *start = Some(std::time::Instant::now()); }
    write_status();
}

/// A desktop session ended: record its length for the panel's history.
pub fn note_session_ended() {
    VIEWERS.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    let seconds = SESSION_START.lock().ok().and_then(|mut s| s.take()).map(|at| at.elapsed().as_secs()).unwrap_or(0);
    let now = epoch();
    LAST_END.store(now, std::sync::atomic::Ordering::Relaxed);
    let line = serde_json::json!({ "at": now, "duration_s": seconds }).to_string();
    let mut lines: Vec<String> = std::fs::read_to_string(HISTORY_JSONL).unwrap_or_default()
        .lines().filter(|l| !l.trim().is_empty()).map(str::to_owned).collect();
    lines.push(line);
    if lines.len() > HISTORY_KEEP { lines.drain(..lines.len() - HISTORY_KEEP); }
    let _ = std::fs::write(HISTORY_JSONL, lines.join("\n") + "\n");
    write_status();
}

/// Keeps the status file fresh so the panel can tell a running host from a stopped one.
pub fn start_status_writer() {
    std::thread::Builder::new().name("uu-ios-status".into()).spawn(|| loop {
        write_status();
        std::thread::sleep(Duration::from_secs(3));
    }).ok();
}

/// Panel app settings, owned by the person holding the iPad.
const SETTINGS_PATH: &str = "/var/mobile/Library/UURemote/settings.json";

/// `lock_after_session` from the panel app: the owner's local switch, which wins over whatever a
/// viewer last sent with SimpleAction 19.
pub fn panel_lock_after_session() -> Option<bool> {
    let text = std::fs::read_to_string(SETTINGS_PATH).ok()?;
    serde_json::from_str::<serde_json::Value>(&text).ok()?.get("lock_after_session")?.as_bool()
}

/// Locks the iPad: the lock screen appears and the panel goes dark.
pub fn lock_screen() -> Result<(), String> { note_input(); with_screen(|s| s.call("lock", "[]")).map(|_| ()) }

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

fn native_point(x: f64, y: f64) -> (f64, f64) {
    crate::input_mapping::ios_native_pointer(x, y, ORIENTATION.load(std::sync::atomic::Ordering::Relaxed))
}
pub fn tap(x: f64, y: f64) -> Result<(), String> { note_input(); let (x,y) = native_point(x,y); with_hid(|s| s.call("tap", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn down(x: f64, y: f64) -> Result<(), String> { note_input(); let (x,y) = native_point(x,y); with_hid(|s| s.call("down", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn move_to(x: f64, y: f64) -> Result<(), String> { note_input(); let (x,y) = native_point(x,y); with_hid(|s| s.call("move", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn up(x: f64, y: f64) -> Result<(), String> { note_input(); let (x,y) = native_point(x,y); with_hid(|s| s.call("up", &format!("[{x},{y}]"))).map(|_| ()) }
pub fn swipe(x1: f64, y1: f64, x2: f64, y2: f64, ms: u32) -> Result<(), String> {
    note_input();
    let orientation = ORIENTATION.load(std::sync::atomic::Ordering::Relaxed);
    let (x1,y1) = crate::input_mapping::ios_native_pointer(x1,y1,orientation);
    let (x2,y2) = crate::input_mapping::ios_native_pointer(x2,y2,orientation);
    with_hid(|s| s.call("swipe", &format!("[{x1},{y1},{x2},{y2},{ms}]"))).map(|_| ())
}
pub fn home() -> Result<(), String> { with_hid(|s| s.call("home", "[]")).map(|_| ()) }

/// The keyboard Home button (consumer page Menu). Unlocked, iPadOS ignores a synthesized
/// home-indicator swipe, and Cmd+H is not a system shortcut since iPadOS 15 (it is Globe+H).
pub fn home_button() -> Result<(), String> { note_input(); with_hid(|s| s.call("button", "[64,1]")).map(|_| ()) }
/// Home pressed twice opens the app switcher.
pub fn app_switcher() -> Result<(), String> { note_input(); with_hid(|s| s.call("button", "[64,2]")).map(|_| ()) }

/// Switches to the app used before this one, what a sideways swipe along the home indicator does.
/// iPadOS ignores a synthesized home-indicator swipe and Cmd+Tab from a synthesized keyboard, so
/// this opens the switcher and taps its first card: the grid keeps the current app in the top-right
/// cell and the previous one top-left (measured on iPadOS 16).
pub fn previous_app() -> Result<(), String> {
    note_input();
    app_switcher()?;
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_millis(1200));
        if let Err(error) = tap(0.44, 0.22) { log::warn!("iPad previous-app tap failed: {error}"); }
    });
    Ok(())
}

/// A press in the bottom band of the panel is held back and mirrors the home-indicator swipe on the
/// iPad itself: dragged upward and released goes home; dragged, held still and released opens the
/// app switcher; released without a drag it is a plain tap where it was pressed.
const BOTTOM_BAND: f64 = 0.96;
const HOME_DRAG: f64 = 0.04;
const SWITCHER_PAUSE: Duration = Duration::from_millis(300);
const SWITCH_DRAG: f64 = 0.06;
#[derive(Clone, Copy)]
enum BottomPress { Pending(f64, f64), Dragging { last_move: std::time::Instant }, Switched }
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
    let Ok(mut press) = BOTTOM_PRESS.lock() else { return move_to(x, y) };
    match *press {
        Some(BottomPress::Pending(sx, sy)) => {
            let (across, up) = ((x - sx).abs(), sy - y);
            if across >= SWITCH_DRAG && across > up {
                *press = Some(BottomPress::Switched);
                drop(press);
                log::info!("iPad gesture: bottom-edge sideways drag -> previous app");
                return previous_app();
            }
            if up >= HOME_DRAG { *press = Some(BottomPress::Dragging { last_move: std::time::Instant::now() }); }
            Ok(())
        }
        Some(BottomPress::Dragging { .. }) => { *press = Some(BottomPress::Dragging { last_move: std::time::Instant::now() }); Ok(()) }
        Some(BottomPress::Switched) => Ok(()),
        None => { drop(press); move_to(x, y) }
    }
}

pub fn pointer_up(x: f64, y: f64) -> Result<(), String> {
    let press = BOTTOM_PRESS.lock().ok().and_then(|mut p| p.take());
    match press {
        Some(BottomPress::Pending(sx, sy)) => tap(sx, sy),
        Some(BottomPress::Dragging { last_move }) if last_move.elapsed() >= SWITCHER_PAUSE => {
            log::info!("iPad gesture: bottom-edge drag and hold -> app switcher");
            app_switcher()
        }
        Some(BottomPress::Dragging { .. }) => { log::info!("iPad gesture: bottom-edge drag -> home"); home_button() }
        Some(BottomPress::Switched) => Ok(()),
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
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    if !down {
        if let Ok(mut held) = HELD_KEYS.lock() { held.get_or_insert_with(Default::default).remove(&usage); }
        return send_key(usage, false);
    }
    // iPadOS does not repeat a synthesized key by itself, and a repeated key-down alone is ignored
    // (measured: 13 downs typed two characters). Hold is simulated with down/up pairs instead.
    let token = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let already = match HELD_KEYS.lock() {
        Ok(mut held) => held.get_or_insert_with(Default::default).insert(usage, token).is_some(),
        Err(_) => true,
    };
    send_key(usage, true)?;
    if !already && repeats(usage) { spawn_repeat(usage, token); }
    Ok(())
}

/// Modifiers and locks stay single-shot; everything else repeats while held.
fn repeats(usage: u32) -> bool { !matches!(usage, 0x39 | 0xe0..=0xe7) }

/// Keys the controller is holding: usage -> the token of the repeat thread that serves it.
static HELD_KEYS: Mutex<Option<std::collections::BTreeMap<u32, u64>>> = Mutex::new(None);

fn spawn_repeat(usage: u32, token: u64) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(450));
        loop {
            let active = HELD_KEYS.lock().ok().and_then(|h| h.as_ref().and_then(|h| h.get(&usage).copied())) == Some(token);
            if !active { return; }
            let _ = send_key(usage, true);
            let _ = send_key(usage, false);
            std::thread::sleep(Duration::from_millis(60));
        }
    });
}

fn send_key(usage: u32, down: bool) -> Result<(), String> {
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

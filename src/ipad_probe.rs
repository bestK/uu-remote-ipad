//! On-device probe: load the iPad agents through frida-core and exercise them.
#[path = "frida_bridge.rs"]
mod frida_bridge;

use frida_bridge::Script;
use std::time::Duration;

fn agent(js: &str) -> String {
    format!("{}\nvar ObjC = bridge;\n{}", include_str!("../ios/agent/objc.js"), js)
}

fn main() {
    let addr = std::env::var("UU_FRIDA_ADDR").unwrap_or_else(|_| "127.0.0.1:27042".into());
    println!("frida: {addr}");

    let mut screen = match Script::load(&addr, "SpringBoard", &agent(include_str!("../ios/agent/screen.js"))) {
        Ok(s) => s,
        Err(e) => { println!("screen agent failed: {e}"); return; }
    };
    println!("screen info: {:?}", screen.call("info", "[]"));
    println!("wake: {:?}", screen.call("wake", "[]"));
    let passcode = std::env::var("UU_PASSCODE").unwrap_or_default();
    if !passcode.is_empty() {
        println!("unlock: {:?}", screen.call("unlock", &format!("[\"{}\"]", passcode)));
    }
    std::thread::sleep(Duration::from_millis(1500));
    match screen.call("capture", "[0.45]") {
        Ok(n) => println!("capture rpc: {n}"),
        Err(e) => println!("capture failed: {e}"),
    }
    if let Some(frame) = Script::take_frame(Duration::from_secs(5)) {
        let _ = std::fs::write("/var/mobile/uu_probe.jpg", &frame);
        println!("frame saved: {} bytes", frame.len());
    } else {
        println!("no frame received");
    }

    let mut hid = match Script::load(&addr, "backboardd", &agent(include_str!("../ios/agent/hid.js"))) {
        Ok(s) => s,
        Err(e) => { println!("hid agent failed: {e}"); return; }
    };
    println!("hid probe: {:?}", hid.call("probe", "[]"));
    println!("tap: {:?}", hid.call("tap", "[0.02,0.02]"));
}

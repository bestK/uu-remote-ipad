//! Private QR handoff and account cleanup for the iPad panel.
use std::path::Path;
use std::io::Write;
use std::os::unix::{fs::OpenOptionsExt, io::AsRawFd};

pub const QR_PATH: &str = "/private/var/tmp/uu-qr.png";

pub fn clear_qr(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

pub fn write_qr(path: &Path, png: &[u8], uid: u32) -> std::io::Result<()> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let tmp = path.with_extension(format!("png.{}.{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        if unsafe { libc::fchown(file.as_raw_fd(), uid, !0) } != 0 { return Err(std::io::Error::last_os_error()); }
        file.write_all(png)?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() { let _ = std::fs::remove_file(&tmp); }
    result
}

pub fn clear_account(cfg: &mut serde_json::Value) -> Result<(), &'static str> {
    let fields = cfg.as_object_mut().ok_or("config is not an object")?;
    for key in ["token", "csrf", "user_id", "account_name"] { fields.remove(key); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    #[test]
    fn private_qr_replaces_old_file_and_can_be_removed() {
        let dir = std::env::temp_dir().join(format!("uu-ios-login-test-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("qr.png");
        std::fs::write(&path, b"old").unwrap();
        write_qr(&path, b"new", unsafe { libc::geteuid() }).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        let meta = std::fs::metadata(&path).unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        assert_eq!(meta.uid(), unsafe { libc::geteuid() });
        clear_qr(&path).unwrap();
        clear_qr(&path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn account_cleanup_keeps_device_identity() {
        let mut cfg = serde_json::json!({"token":"t", "csrf":"c", "user_id":"u", "account_name":"n", "device_id":"d"});
        clear_account(&mut cfg).unwrap();
        assert_eq!(cfg, serde_json::json!({"device_id":"d"}));
        assert!(clear_account(&mut serde_json::json!([])).is_err());
    }
}

//! Ordered, atomic iOS status snapshots shared with the local panel and experimental HUD.
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Copy)]
pub enum Event { Heartbeat, Started, Ended }

struct State { viewers: u32, last_end: u64, revision: u64 }

pub struct Publisher {
    path: PathBuf,
    version: String,
    instance: String,
    state: Mutex<State>,
}

impl Publisher {
    pub fn new(path: impl Into<PathBuf>, version: &str) -> Self {
        Self { path: path.into(), version: version.to_owned(), instance: format!("{:016x}", rand::random::<u64>()),
            state: Mutex::new(State { viewers: 0, last_end: 0, revision: 0 }) }
    }

    // Hold the same lock while applying an event, reading the count and replacing the file.
    pub fn publish(&self, event: Event, signed_in: bool, now: u64) -> io::Result<()> {
        let mut state = self.state.lock().map_err(|_| io::Error::other("status lock poisoned"))?;
        match event {
            Event::Heartbeat => {}
            Event::Started => state.viewers = state.viewers.saturating_add(1),
            Event::Ended => { state.viewers = state.viewers.saturating_sub(1); state.last_end = now; }
        }
        state.revision = state.revision.checked_add(1).ok_or_else(|| io::Error::other("status revision exhausted"))?;
        let status = serde_json::json!({
            "version": self.version,
            "signed_in": signed_in,
            "viewers": state.viewers,
            "last_session_end": state.last_end,
            "updated": now,
            "status_instance": self.instance,
            "status_revision": state.revision,
        });
        let bytes = serde_json::to_vec(&status).map_err(io::Error::other)?;
        let name = format!(".uu-status-{}-{}.tmp", self.instance, state.revision);
        let temp = self.path.with_file_name(name);
        atomic_replace(&self.path, &temp, &bytes)
    }
}

fn atomic_replace(path: &Path, temp: &Path, bytes: &[u8]) -> io::Result<()> {
    // create_new refuses an existing file or symlink in the shared temporary directory.
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o644).open(temp)?;
    let result = file.write_all(bytes).and_then(|_| std::fs::rename(temp, path));
    if result.is_err() { let _ = std::fs::remove_file(temp); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{atomic::{AtomicBool, Ordering}, Arc};

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!("uu-ios-status-test-{:016x}", rand::random::<u64>()));
            std::fs::create_dir(&p).unwrap();
            Self(p)
        }
        fn path(&self) -> PathBuf { self.0.join("status.json") }
    }
    impl Drop for Temp { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

    fn read(path: &Path) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn same_second_transitions_have_ordered_revisions() {
        let temp = Temp::new();
        let publisher = Publisher::new(temp.path(), "test");
        publisher.publish(Event::Heartbeat, true, 100).unwrap();
        let before = read(&temp.path());
        publisher.publish(Event::Started, true, 100).unwrap();
        let active = read(&temp.path());
        publisher.publish(Event::Ended, true, 100).unwrap();
        let idle = read(&temp.path());
        assert_eq!(before["viewers"], 0);
        assert_eq!(active["viewers"], 1);
        assert_eq!(idle["viewers"], 0);
        assert_eq!(idle["last_session_end"], 100);
        assert_eq!(before["status_revision"], 1);
        assert_eq!(active["status_revision"], 2);
        assert_eq!(idle["status_revision"], 3);
        assert_eq!(before["status_instance"], active["status_instance"]);
        assert_eq!(active["status_instance"], idle["status_instance"]);
    }

    #[test]
    fn concurrent_events_publish_valid_ordered_snapshots() {
        let temp = Temp::new();
        let path = temp.path();
        let publisher = Arc::new(Publisher::new(&path, "test"));
        publisher.publish(Event::Heartbeat, true, 100).unwrap();
        let done = Arc::new(AtomicBool::new(false));
        let reader_done = done.clone();
        let reader_path = path.clone();
        let reader = std::thread::spawn(move || {
            let mut last = 0;
            while !reader_done.load(Ordering::Acquire) {
                let status = read(&reader_path);
                let revision = status["status_revision"].as_u64().unwrap();
                assert!(revision >= last);
                last = revision;
            }
        });
        let workers: Vec<_> = (0..4).map(|_| {
            let publisher = publisher.clone();
            std::thread::spawn(move || for _ in 0..100 {
                publisher.publish(Event::Started, true, 100).unwrap();
                publisher.publish(Event::Heartbeat, true, 100).unwrap();
                publisher.publish(Event::Ended, true, 100).unwrap();
            })
        }).collect();
        for worker in workers { worker.join().unwrap(); }
        done.store(true, Ordering::Release);
        reader.join().unwrap();
        let status = read(&path);
        assert_eq!(status["viewers"], 0);
        assert_eq!(status["status_revision"], 1201);
    }

    #[test]
    fn failed_write_does_not_forget_the_session() {
        let temp = Temp::new();
        let path = temp.0.join("missing/status.json");
        let publisher = Publisher::new(&path, "test");
        assert!(publisher.publish(Event::Started, true, 100).is_err());
        std::fs::create_dir(path.parent().unwrap()).unwrap();
        publisher.publish(Event::Heartbeat, true, 101).unwrap();
        let status = read(&path);
        assert_eq!(status["viewers"], 1);
        assert_eq!(status["status_revision"], 2);
    }
}

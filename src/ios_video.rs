//! VideoToolbox encoder for the iPad host (see `c_engine/ios_video.m`).
//!
//! SpringBoard gives us JPEG frames; VideoToolbox turns them into Annex-B access units with an
//! AUD, which is what `video.rs` splits and what the RTP payloader expects.

use std::ffi::c_void;

/// One access unit: AUD + (parameter sets on keyframes) + the slice NALs.
pub struct Au {
    pub data: Vec<u8>,
    pub keyframe: bool,
}

type AuCallback = extern "C" fn(*const u8, usize, i32, *mut c_void);

extern "C" {
    fn uu_vt_create(width: i32, height: i32, fps: i32, gop: i32, max_kbps: i32, hevc: i32) -> *mut c_void;
    fn uu_vt_force_keyframe(handle: *mut c_void);
    fn uu_vt_encode(handle: *mut c_void, jpeg: *const u8, len: usize, cb: AuCallback, user: *mut c_void) -> i32;
    fn uu_vt_destroy(handle: *mut c_void);
    fn uu_vt_decode_jpeg(jpeg: *const u8, len: usize, bgra: *mut u8, cap: usize, w: *mut i32, h: *mut i32) -> i32;
}

pub struct Encoder {
    handle: *mut c_void,
    pub width: u32,
    pub height: u32,
}

// The handle is only used from the single encoder worker thread; VideoToolbox is thread-safe.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(width: u32, height: u32, fps: u32, gop: u32, max_kbps: u32, hevc: bool) -> Result<Self, String> {
        let handle = unsafe {
            uu_vt_create(width as i32, height as i32, fps.max(1) as i32, gop as i32,
                max_kbps.min(i32::MAX as u32) as i32, i32::from(hevc))
        };
        if handle.is_null() { return Err("VideoToolbox encoder unavailable".into()); }
        Ok(Self { handle, width, height })
    }

    pub fn force_keyframe(&self) {
        unsafe { uu_vt_force_keyframe(self.handle) };
    }

    /// Encodes one JPEG. Access units arrive through the callback before this returns.
    pub fn encode(&self, jpeg: &[u8]) -> Result<Vec<Au>, String> {
        let mut units: Vec<Au> = Vec::new();
        extern "C" fn collect(data: *const u8, len: usize, keyframe: i32, user: *mut c_void) {
            if data.is_null() || len == 0 { return; }
            // SAFETY: `user` points at the Vec on this stack frame for the duration of the call.
            let units = unsafe { &mut *(user as *mut Vec<Au>) };
            units.push(Au { data: unsafe { std::slice::from_raw_parts(data, len) }.to_vec(), keyframe: keyframe != 0 });
        }
        let status = unsafe {
            uu_vt_encode(self.handle, jpeg.as_ptr(), jpeg.len(), collect, &mut units as *mut _ as *mut c_void)
        };
        if status != 0 { return Err(format!("VideoToolbox encode failed with code {status}")); }
        Ok(units)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) { unsafe { uu_vt_destroy(self.handle) }; }
}

/// Decode a SpringBoard JPEG into the BGRA buffer `ScreenCapture::capture_frame` promises.
pub fn decode_jpeg(jpeg: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let mut buffer = vec![0u8; width as usize * height as usize * 4];
    let (mut w, mut h) = (0i32, 0i32);
    let status = unsafe {
        uu_vt_decode_jpeg(jpeg.as_ptr(), jpeg.len(), buffer.as_mut_ptr(), buffer.len(), &mut w, &mut h)
    };
    if status != 0 { return Err(format!("JPEG decode failed with code {status}")); }
    if w as u32 != width || h as u32 != height {
        return Err(format!("JPEG is {w}x{h}, expected {width}x{height}"));
    }
    Ok(buffer)
}

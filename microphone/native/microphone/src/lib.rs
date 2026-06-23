//! C ABI for the `microphone_dart` package's native capture.
//!
//! The Dart `FfiBackend` calls these functions. `microphone_start` opens a
//! platform capture and returns an opaque recording id; the Dart side then
//! polls `microphone_read` to drain captured S16LE PCM, and calls
//! `microphone_stop` / `microphone_recording_free` when done. The package
//! wraps the drained PCM in a WAV header on the Dart side.

// The exported functions take the opaque `*mut Recorder` returned by
// `microphone_recorder_new`; the caller is responsible for its validity. That
// makes the raw-pointer derefs expected here rather than a smell.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod coreaudio;

#[cfg(target_os = "ios")]
mod ios_session;

#[cfg(target_os = "android")]
mod aaudio;

#[cfg(target_os = "windows")]
mod winmm;

#[cfg(target_os = "linux")]
mod alsa;

/// A platform audio input that yields interleaved S16LE frames on demand.
pub(crate) trait PcmSource: Send + Sync {
    /// Drains and returns up to `max` of the samples captured since the last
    /// call, leaving any remainder buffered for the next call. Returns an empty
    /// vec when nothing new has arrived yet.
    fn read(&self, max: usize) -> Result<Vec<i16>, String>;
    /// The channel count of the captured audio.
    fn channels(&self) -> u32;
}

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

// Recording state codes, mirrored by the Dart side.
const STATE_RECORDING: u8 = 0;
const STATE_STOPPED: u8 = 1;
const STATE_ERROR: u8 = 2;
const STATE_PAUSED: u8 = 3;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_last_error(msg: impl Into<String>) {
    let msg_str = msg.into();
    let c_result = CString::new(msg_str.clone());
    let c = match c_result {
        Ok(s) => s,
        Err(_) => {
            // If the string contains null bytes, remove them and retry.
            let cleaned = msg_str.replace('\0', "");
            CString::new(cleaned).unwrap_or_default()
        }
    };
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

/// A single in-progress or finished capture.
struct Recording {
    source: Box<dyn PcmSource>,
    state: AtomicU8,
    // When set, microphone_read discards captured input instead of returning
    // it, so the paused interval is dropped from the recording.
    paused: AtomicBool,
    rate: u32,
    channels: u32,
    error: Mutex<Option<String>>,
}

/// Owns the audio backend and the table of live recordings.
pub struct Recorder {
    recordings: Mutex<HashMap<u64, Arc<Recording>>>,
    next_id: AtomicU64,
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    coreaudio: Arc<coreaudio::CoreAudio>,
    #[cfg(target_os = "android")]
    aaudio: Arc<aaudio::Aaudio>,
    #[cfg(target_os = "windows")]
    winmm: Arc<winmm::Winmm>,
    #[cfg(target_os = "linux")]
    alsa: Arc<alsa::Alsa>,
}

impl Recorder {
    fn new() -> Result<Recorder, String> {
        Ok(Recorder {
            recordings: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            coreaudio: Arc::new(coreaudio::CoreAudio::load()?),
            #[cfg(target_os = "android")]
            aaudio: Arc::new(aaudio::Aaudio::load()?),
            #[cfg(target_os = "windows")]
            winmm: Arc::new(winmm::Winmm::load()?),
            #[cfg(target_os = "linux")]
            alsa: Arc::new(alsa::Alsa::load()?),
        })
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn open_source(
        &self,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Box<dyn PcmSource>, String> {
        // iOS gates audio input behind an active AVAudioSession; macOS does not.
        #[cfg(target_os = "ios")]
        ios_session::activate()?;
        // device_id selects a specific input on macOS (the AudioQueue's current
        // device, by UID); iOS routes through AVAudioSession, so it is ignored.
        let cap = coreaudio::CoreAudioCapture::open(&self.coreaudio, channels, rate, device_id)?;
        Ok(Box::new(cap))
    }

    #[cfg(target_os = "android")]
    fn open_source(
        &self,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Box<dyn PcmSource>, String> {
        // AAudio input device selection (by id) is not wired yet; uses default.
        let _ = device_id;
        let cap = aaudio::AaudioCapture::open(&self.aaudio, channels, rate)?;
        Ok(Box::new(cap))
    }

    #[cfg(target_os = "windows")]
    fn open_source(
        &self,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Box<dyn PcmSource>, String> {
        // device_id, when set, is a waveIn device index (see
        // winmm::enumerate_input_devices); null selects the preferred input.
        let cap = winmm::WinmmCapture::open(&self.winmm, channels, rate, device_id)?;
        Ok(Box::new(cap))
    }

    #[cfg(target_os = "linux")]
    fn open_source(
        &self,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Box<dyn PcmSource>, String> {
        // Linux ALSA device selection is not wired yet; uses default.
        let _ = device_id;
        let cap = alsa::AlsaCapture::open(&self.alsa, channels, rate)?;
        Ok(Box::new(cap))
    }

    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "android",
        target_os = "windows",
        target_os = "linux"
    )))]
    fn open_source(
        &self,
        _channels: u32,
        _rate: u32,
        _device_id: Option<&str>,
    ) -> Result<Box<dyn PcmSource>, String> {
        Err("native capture is not implemented on this platform yet".into())
    }

    fn start(&self, rate: u32, channels: u32, device_id: Option<&str>) -> Result<u64, String> {
        let source = self.open_source(channels, rate, device_id)?;
        let actual_channels = source.channels();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let recording = Arc::new(Recording {
            source,
            state: AtomicU8::new(STATE_RECORDING),
            paused: AtomicBool::new(false),
            rate,
            channels: actual_channels,
            error: Mutex::new(None),
        });
        self.recordings.lock().unwrap().insert(id, recording);
        Ok(id)
    }

    fn get(&self, id: u64) -> Option<Arc<Recording>> {
        self.recordings.lock().unwrap().get(&id).cloned()
    }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// Returns the ABI version. Bumped when the C ABI changes.
#[no_mangle]
pub extern "C" fn microphone_abi_version() -> u32 {
    1
}

/// Creates a recorder. Returns null on failure; see [microphone_last_error].
#[no_mangle]
pub extern "C" fn microphone_recorder_new() -> *mut Recorder {
    match Recorder::new() {
        Ok(r) => Box::into_raw(Box::new(r)),
        Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Frees a recorder created by [microphone_recorder_new], stopping all
/// recordings.
#[no_mangle]
pub extern "C" fn microphone_recorder_free(recorder: *mut Recorder) {
    if recorder.is_null() {
        return;
    }
    let recorder = unsafe { Box::from_raw(recorder) };
    // Dropping the map drops each Recording, whose source's Drop stops the
    // platform capture.
    recorder.recordings.lock().unwrap().clear();
}

fn with_recorder<'a>(recorder: *mut Recorder) -> Option<&'a Recorder> {
    if recorder.is_null() {
        set_last_error("null recorder");
        None
    } else {
        Some(unsafe { &*recorder })
    }
}

/// Starts capturing at `rate` Hz with `channels` channels on the input device
/// identified by `device_id` (a NUL-terminated UID, or null for the system
/// default). Returns a recording id, or 0 on error (see [microphone_last_error]).
///
/// # Safety
/// `device_id`, if non-null, must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn microphone_start(
    recorder: *mut Recorder,
    rate: u32,
    channels: u32,
    device_id: *const c_char,
) -> u64 {
    let Some(recorder) = with_recorder(recorder) else {
        return 0;
    };
    let device = if device_id.is_null() {
        None
    } else {
        match std::ffi::CStr::from_ptr(device_id).to_str() {
            Ok(s) if !s.is_empty() => Some(s),
            Ok(_) => None,
            Err(_) => {
                set_last_error("device_id is not valid UTF-8");
                return 0;
            }
        }
    };
    match recorder.start(rate, channels, device) {
        Ok(id) => id,
        Err(e) => {
            set_last_error(e);
            0
        }
    }
}

/// Drains up to `cap` captured samples into `out` (interleaved S16). Returns the
/// number of samples written, or -1 if the id is unknown / on error.
///
/// # Safety
/// `out` must point to `cap` writable `i16` slots.
#[no_mangle]
pub unsafe extern "C" fn microphone_read(
    recorder: *mut Recorder,
    id: u64,
    out: *mut i16,
    cap: usize,
) -> isize {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    let Some(recording) = recorder.get(id) else {
        set_last_error("unknown recording id");
        return -1;
    };
    if out.is_null() || cap == 0 {
        return 0;
    }
    // While paused, drain and discard captured input so the paused interval is
    // dropped from the recording, and report that nothing was read.
    if recording.paused.load(Ordering::SeqCst) {
        let _ = recording.source.read(usize::MAX);
        return 0;
    }
    match recording.source.read(cap) {
        Ok(samples) => {
            let n = samples.len(); // read() already capped to `cap`
            if n > 0 {
                std::ptr::copy_nonoverlapping(samples.as_ptr(), out, n);
            }
            n as isize
        }
        Err(e) => {
            *recording.error.lock().unwrap() = Some(e.clone());
            recording.state.store(STATE_ERROR, Ordering::SeqCst);
            set_last_error(e);
            -1
        }
    }
}

/// Returns the recording state (0 recording, 1 stopped, 2 error), or -1 if the
/// id is unknown.
#[no_mangle]
pub extern "C" fn microphone_state(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => r.state.load(Ordering::SeqCst) as c_int,
        None => -1,
    }
}

/// Returns the capture sample rate in Hz, or -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_sample_rate(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => r.rate as c_int,
        None => -1,
    }
}

/// Returns the capture channel count, or -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_channels(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => r.channels as c_int,
        None => -1,
    }
}

/// Pauses a recording: captured input is discarded until resumed, so the paused
/// interval is dropped. Returns 0 on success, -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_pause(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => {
            r.paused.store(true, Ordering::SeqCst);
            r.state.store(STATE_PAUSED, Ordering::SeqCst);
            0
        }
        None => -1,
    }
}

/// Resumes a paused recording. Returns 0 on success, -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_resume(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => {
            // Discard whatever accumulated during the pause before resuming, so
            // no paused audio leaks into the next read.
            let _ = r.source.read(usize::MAX);
            r.paused.store(false, Ordering::SeqCst);
            r.state.store(STATE_RECORDING, Ordering::SeqCst);
            0
        }
        None => -1,
    }
}

/// Stops a recording. Returns 0 on success, -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_stop(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.get(id) {
        Some(r) => {
            r.state.store(STATE_STOPPED, Ordering::SeqCst);
            0
        }
        None => -1,
    }
}

/// Stops (if needed) and removes a recording, releasing the platform capture.
/// Returns 0 on success, -1 if the id is unknown.
#[no_mangle]
pub extern "C" fn microphone_recording_free(recorder: *mut Recorder, id: u64) -> c_int {
    let Some(recorder) = with_recorder(recorder) else {
        return -1;
    };
    match recorder.recordings.lock().unwrap().remove(&id) {
        Some(_) => 0,
        None => -1,
    }
}

/// Returns the most recent error message on the calling thread.
#[no_mangle]
pub extern "C" fn microphone_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

/// A selectable input device.
pub(crate) struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

/// Lists input devices for the current platform. macOS and Windows enumerate;
/// other platforms return an empty list and capture uses the system default.
fn enumerate_input_devices() -> Vec<DeviceInfo> {
    #[cfg(target_os = "macos")]
    {
        coreaudio::enumerate_input_devices()
    }
    #[cfg(target_os = "windows")]
    {
        winmm::enumerate_input_devices()
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        Vec::new()
    }
}

thread_local! {
    // The device list is snapshotted on microphone_device_count and read by the
    // id/name/default accessors, so a caller iterates a stable list.
    static DEVICE_CACHE: RefCell<Vec<DeviceInfo>> = const { RefCell::new(Vec::new()) };
}

/// Refreshes the device list and returns how many input devices there are.
#[no_mangle]
pub extern "C" fn microphone_device_count() -> c_int {
    let devices = enumerate_input_devices();
    let n = devices.len() as c_int;
    DEVICE_CACHE.with(|c| *c.borrow_mut() = devices);
    n
}

/// Copies device `index`'s UID into `out` (NUL-terminated). Returns the string
/// length written (excluding NUL), or -1 if the index is out of range / `out`
/// is too small. Call [microphone_device_count] first.
///
/// # Safety
/// `out` must point to `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn microphone_device_id(index: c_int, out: *mut c_char, cap: usize) -> c_int {
    DEVICE_CACHE.with(|c| copy_field(c.borrow().get(index as usize).map(|d| &d.id), out, cap))
}

/// Copies device `index`'s display name into `out`. See [microphone_device_id].
///
/// # Safety
/// `out` must point to `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn microphone_device_name(
    index: c_int,
    out: *mut c_char,
    cap: usize,
) -> c_int {
    DEVICE_CACHE.with(|c| copy_field(c.borrow().get(index as usize).map(|d| &d.name), out, cap))
}

/// Returns 1 if device `index` is the system default input, 0 if not, -1 if the
/// index is out of range.
#[no_mangle]
pub extern "C" fn microphone_device_is_default(index: c_int) -> c_int {
    DEVICE_CACHE.with(|c| match c.borrow().get(index as usize) {
        Some(d) => d.is_default as c_int,
        None => -1,
    })
}

/// Copies `field` as a NUL-terminated C string into `out`. Returns the byte
/// length (excluding NUL), or -1 if `field` is None or does not fit.
unsafe fn copy_field(field: Option<&String>, out: *mut c_char, cap: usize) -> c_int {
    let Some(s) = field else {
        return -1;
    };
    let bytes = s.as_bytes();
    if out.is_null() || bytes.len() + 1 > cap {
        return -1;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out, bytes.len());
    *out.add(bytes.len()) = 0;
    bytes.len() as c_int
}

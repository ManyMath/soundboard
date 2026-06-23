//! Minimal Windows audio input via `LoadLibrary`-ing `winmm.dll`.
//!
//! Same header-free, runtime-load pattern as the CoreAudio and AAudio paths:
//! declare the handful of `waveIn*` symbols we use and resolve them at runtime,
//! so the build needs no Windows SDK headers/libs and honors the
//! "no system dependencies" constraint. `winmm.dll` ships with every Windows
//! install (the legacy Multimedia / `waveIn` API), so consumers need nothing
//! extra.
//!
//! The `waveIn` API is callback-driven; `PcmSource` is pull-driven. We bridge
//! them exactly like the CoreAudio path: the input callback appends each full
//! buffer's S16 frames to a `Mutex<Vec<i16>>` and re-queues the buffer, and
//! `read` drains whatever has accumulated.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use libloading::Library;

use crate::{DeviceInfo, PcmSource};

// --- Win32 multimedia ABI constants ----------------------------------------

// MMRESULT success.
const MMSYSERR_NOERROR: u32 = 0;
// LPWAVEFORMATEX format tag for uncompressed PCM.
const WAVE_FORMAT_PCM: u16 = 1;
// waveInOpen: deliver completion notifications by calling our function pointer.
const CALLBACK_FUNCTION: u32 = 0x0003_0000;
// waveInOpen device id meaning "let the system pick the preferred input".
const WAVE_MAPPER: u32 = 0xFFFF_FFFF;
// waveInProc message: a buffer has been filled and returned to us.
const WIM_DATA: u32 = 0x03C0;
// Max device-name length (in WCHARs) in WAVEINCAPSW::szPname.
const MAXPNAMELEN: usize = 32;

type HWaveIn = *mut c_void;

// WAVEFORMATEX (we only ever describe integer PCM, so cbSize is 0).
#[repr(C)]
struct WaveFormatEx {
    format_tag: u16,
    channels: u16,
    samples_per_sec: u32,
    avg_bytes_per_sec: u32,
    block_align: u16,
    bits_per_sample: u16,
    cb_size: u16,
}

// WAVEHDR. dwUser/reserved are DWORD_PTR (pointer-sized); the rest are fixed
// width, so the layout matches the OS struct on both 32- and 64-bit.
#[repr(C)]
struct WaveHdr {
    data: *mut c_char,
    buffer_length: u32,
    bytes_recorded: u32,
    user: usize,
    flags: u32,
    loops: u32,
    next: *mut WaveHdr,
    reserved: usize,
}

// WAVEINCAPSW, used for device enumeration.
#[repr(C)]
struct WaveInCapsW {
    mid: u16,
    pid: u16,
    driver_version: u32,
    pname: [u16; MAXPNAMELEN],
    formats: u32,
    channels: u16,
    reserved1: u16,
}

// The waveIn completion callback. We only act on WIM_DATA.
type WaveInProc =
    unsafe extern "system" fn(HWaveIn, u32, dw_instance: usize, dw_param1: usize, dw_param2: usize);

type FnGetNumDevs = unsafe extern "system" fn() -> u32;
type FnGetDevCaps = unsafe extern "system" fn(usize, *mut WaveInCapsW, u32) -> u32;
type FnOpen = unsafe extern "system" fn(
    *mut HWaveIn,
    u32,
    *const WaveFormatEx,
    usize,
    usize,
    u32,
) -> u32;
type FnHdrOp = unsafe extern "system" fn(HWaveIn, *mut WaveHdr, u32) -> u32;
type FnStreamOp = unsafe extern "system" fn(HWaveIn) -> u32;
type FnGetErrorText = unsafe extern "system" fn(u32, *mut u16, u32) -> u32;

/// Resolved entry points into `winmm.dll`.
pub struct Winmm {
    _lib: Library,
    get_num_devs: FnGetNumDevs,
    get_dev_caps: FnGetDevCaps,
    open: FnOpen,
    prepare: FnHdrOp,
    unprepare: FnHdrOp,
    add_buffer: FnHdrOp,
    start: FnStreamOp,
    stop: FnStreamOp,
    reset: FnStreamOp,
    close: FnStreamOp,
    get_error_text: FnGetErrorText,
}

unsafe impl Send for Winmm {}
unsafe impl Sync for Winmm {}

impl Winmm {
    pub fn load() -> Result<Winmm, String> {
        unsafe {
            let lib =
                Library::new("winmm.dll").map_err(|e| format!("failed to load winmm.dll: {e}"))?;
            macro_rules! sym {
                ($name:literal) => {
                    *lib.get($name).map_err(|e| {
                        format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                    })?
                };
            }
            Ok(Winmm {
                get_num_devs: sym!(b"waveInGetNumDevs\0"),
                get_dev_caps: sym!(b"waveInGetDevCapsW\0"),
                open: sym!(b"waveInOpen\0"),
                prepare: sym!(b"waveInPrepareHeader\0"),
                unprepare: sym!(b"waveInUnprepareHeader\0"),
                add_buffer: sym!(b"waveInAddBuffer\0"),
                start: sym!(b"waveInStart\0"),
                stop: sym!(b"waveInStop\0"),
                reset: sym!(b"waveInReset\0"),
                close: sym!(b"waveInClose\0"),
                get_error_text: sym!(b"waveInGetErrorTextW\0"),
                _lib: lib,
            })
        }
    }

    /// Maps an MMRESULT to a human-readable message via waveInGetErrorTextW,
    /// falling back to the numeric code.
    fn error_text(&self, code: u32) -> String {
        unsafe {
            let mut buf = [0u16; 256];
            let rc = (self.get_error_text)(code, buf.as_mut_ptr(), buf.len() as u32);
            if rc == MMSYSERR_NOERROR {
                let s = utf16_to_string(&buf);
                if !s.is_empty() {
                    return format!("{s} (MMRESULT {code})");
                }
            }
            format!("MMRESULT {code}")
        }
    }
}

/// Converts a NUL-terminated (or full-length) UTF-16 slice to a String.
fn utf16_to_string(units: &[u16]) -> String {
    let len = units.iter().position(|&c| c == 0).unwrap_or(units.len());
    String::from_utf16_lossy(&units[..len])
}

/// Passed to waveInOpen as the callback instance. Holds the captured-sample
/// sink and the add-buffer entry point the callback needs to recycle buffers.
struct Sink {
    samples: Mutex<Vec<i16>>,
    add_buffer: FnHdrOp,
    // Once set, the callback drains a returned buffer but does not re-queue it,
    // so waveInReset/waveInClose during teardown can drain the queue.
    closing: AtomicBool,
}

unsafe impl Send for Sink {}
unsafe impl Sync for Sink {}

/// An open `waveIn` device feeding captured S16 frames into a shared buffer.
pub struct WinmmCapture {
    winmm: *const Winmm,
    hwi: HWaveIn,
    sink: Arc<Sink>,
    // Boxed so each WAVEHDR keeps a stable heap address: we hand the OS raw
    // pointers to them (waveInPrepareHeader/AddBuffer) and it retains those
    // across later pushes, which would reallocate and move a plain Vec's
    // elements. The backing audio buffers likewise stay alive here for the
    // headers' lpData pointers. (clippy's vec_box suggestion would reintroduce
    // exactly that dangling-pointer hazard.)
    #[allow(clippy::vec_box)]
    headers: Vec<Box<WaveHdr>>,
    _buffers: Vec<Vec<u8>>,
    channels: u32,
}

// The handle and headers are only touched from the owning capture thread and
// the waveIn callback thread (which the OS serializes per device); the shared
// sample buffer is behind a Mutex.
unsafe impl Send for WinmmCapture {}
unsafe impl Sync for WinmmCapture {}

const RING_BUFFERS: usize = 4;
const FRAMES_PER_BUFFER: usize = 2048;

impl WinmmCapture {
    pub fn open(
        winmm: &Winmm,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Self, String> {
        let channels = channels.max(1);
        let block_align = channels * 2; // 16-bit samples
        let format = WaveFormatEx {
            format_tag: WAVE_FORMAT_PCM,
            channels: channels as u16,
            samples_per_sec: rate,
            avg_bytes_per_sec: rate * block_align,
            block_align: block_align as u16,
            bits_per_sample: 16,
            cb_size: 0,
        };
        // device_id is the device index as a decimal string (see
        // enumerate_input_devices); null/empty selects the preferred input.
        let device = match device_id {
            Some(s) => s
                .parse::<u32>()
                .map_err(|_| format!("invalid Windows device id {s:?} (expected an index)"))?,
            None => WAVE_MAPPER,
        };

        let sink = Arc::new(Sink {
            samples: Mutex::new(Vec::new()),
            add_buffer: winmm.add_buffer,
            closing: AtomicBool::new(false),
        });

        unsafe {
            let mut hwi: HWaveIn = std::ptr::null_mut();
            let rc = (winmm.open)(
                &mut hwi,
                device,
                &format,
                input_cb as WaveInProc as usize,
                Arc::as_ptr(&sink) as usize,
                CALLBACK_FUNCTION,
            );
            if rc != MMSYSERR_NOERROR {
                return Err(format!("waveInOpen: {}", winmm.error_text(rc)));
            }

            let buffer_bytes = FRAMES_PER_BUFFER * block_align as usize;
            let mut headers: Vec<Box<WaveHdr>> = Vec::with_capacity(RING_BUFFERS);
            let mut buffers: Vec<Vec<u8>> = Vec::with_capacity(RING_BUFFERS);
            let hdr_size = std::mem::size_of::<WaveHdr>() as u32;
            for _ in 0..RING_BUFFERS {
                let mut buf = vec![0u8; buffer_bytes];
                let mut hdr = Box::new(WaveHdr {
                    data: buf.as_mut_ptr() as *mut c_char,
                    buffer_length: buffer_bytes as u32,
                    bytes_recorded: 0,
                    user: 0,
                    flags: 0,
                    loops: 0,
                    next: std::ptr::null_mut(),
                    reserved: 0,
                });
                let rc = (winmm.prepare)(hwi, &mut *hdr, hdr_size);
                if rc != MMSYSERR_NOERROR {
                    Self::teardown(winmm, hwi, &sink, &mut headers);
                    return Err(format!("waveInPrepareHeader: {}", winmm.error_text(rc)));
                }
                let rc = (winmm.add_buffer)(hwi, &mut *hdr, hdr_size);
                if rc != MMSYSERR_NOERROR {
                    (winmm.unprepare)(hwi, &mut *hdr, hdr_size);
                    Self::teardown(winmm, hwi, &sink, &mut headers);
                    return Err(format!("waveInAddBuffer: {}", winmm.error_text(rc)));
                }
                // Push only after the header is queued; the Vec move keeps the
                // heap WAVEHDR/buffer addresses we handed the OS valid.
                buffers.push(buf);
                headers.push(hdr);
            }

            let rc = (winmm.start)(hwi);
            if rc != MMSYSERR_NOERROR {
                Self::teardown(winmm, hwi, &sink, &mut headers);
                return Err(format!("waveInStart: {}", winmm.error_text(rc)));
            }

            Ok(WinmmCapture {
                winmm: winmm as *const Winmm,
                hwi,
                sink,
                headers,
                _buffers: buffers,
                channels,
            })
        }
    }

    /// Stops the device and releases every prepared header. Used both for the
    /// error path during open and from Drop. `closing` must already be set so
    /// the callback drains rather than re-queues the buffers waveInReset
    /// returns.
    #[allow(clippy::vec_box)] // see the `headers` field: stable WAVEHDR addresses.
    unsafe fn teardown(
        winmm: &Winmm,
        hwi: HWaveIn,
        sink: &Arc<Sink>,
        headers: &mut Vec<Box<WaveHdr>>,
    ) {
        sink.closing.store(true, Ordering::SeqCst);
        let hdr_size = std::mem::size_of::<WaveHdr>() as u32;
        (winmm.stop)(hwi);
        // Returns all queued buffers to the callback (which, now closing, just
        // drains them) so the headers can be unprepared.
        (winmm.reset)(hwi);
        for hdr in headers.iter_mut() {
            (winmm.unprepare)(hwi, &mut **hdr, hdr_size);
        }
        (winmm.close)(hwi);
        headers.clear();
    }
}

/// Called by winmm on its own thread when a buffer of input is ready (WIM_DATA)
/// or on open/close (which we ignore).
unsafe extern "system" fn input_cb(
    hwi: HWaveIn,
    msg: u32,
    dw_instance: usize,
    dw_param1: usize,
    _dw_param2: usize,
) {
    if msg != WIM_DATA {
        return;
    }
    let sink = &*(dw_instance as *const Sink);
    let hdr = dw_param1 as *mut WaveHdr;
    if hdr.is_null() {
        return;
    }
    let byte_size = (*hdr).bytes_recorded as usize;
    let data = (*hdr).data as *const i16;
    let n = byte_size / 2;
    if n > 0 && !data.is_null() {
        let slice = std::slice::from_raw_parts(data, n);
        if let Ok(mut samples) = sink.samples.lock() {
            samples.extend_from_slice(slice);
        }
    }
    // Recycle the buffer so the device keeps capturing -- unless we are tearing
    // down, in which case the queue must drain. waveInAddBuffer is one of the
    // few functions documented as safe to call from this callback.
    if !sink.closing.load(Ordering::SeqCst) {
        (sink.add_buffer)(hwi, hdr, std::mem::size_of::<WaveHdr>() as u32);
    }
}

impl PcmSource for WinmmCapture {
    fn read(&self, max: usize) -> Result<Vec<i16>, String> {
        let mut samples = self.sink.samples.lock().map_err(|e| e.to_string())?;
        if samples.is_empty() || max == 0 {
            return Ok(Vec::new());
        }
        if samples.len() <= max {
            return Ok(std::mem::take(&mut *samples));
        }
        // Take the first `max` and keep the remainder for the next call.
        let rest = samples.split_off(max);
        let out = std::mem::replace(&mut *samples, rest);
        Ok(out)
    }

    fn channels(&self) -> u32 {
        self.channels
    }
}

impl Drop for WinmmCapture {
    fn drop(&mut self) {
        unsafe {
            let winmm = &*self.winmm;
            Self::teardown(winmm, self.hwi, &self.sink, &mut self.headers);
        }
        // Keep the Sink alive until after the device is closed so the callback
        // cannot deref a freed pointer mid-stop.
        let _ = &self.sink;
    }
}

/// Enumerates every `waveIn` input device. Returns an empty Vec on any failure.
///
/// `waveIn` identifies devices by index, so the ids are decimal indices.
/// `waveIn` has no real "default device" query (capturing with no device
/// selected uses WAVE_MAPPER, the system-preferred input), so we flag the first
/// enumerated device as the default -- the conventional preferred input -- to
/// match the cross-platform contract that the device list exposes one default.
pub fn enumerate_input_devices() -> Vec<DeviceInfo> {
    let winmm = match Winmm::load() {
        Ok(w) => w,
        Err(_) => return Vec::new(),
    };
    unsafe {
        let count = (winmm.get_num_devs)();
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut caps: WaveInCapsW = std::mem::zeroed();
            let rc = (winmm.get_dev_caps)(
                i as usize,
                &mut caps,
                std::mem::size_of::<WaveInCapsW>() as u32,
            );
            if rc != MMSYSERR_NOERROR {
                continue;
            }
            let name = utf16_to_string(&caps.pname);
            out.push(DeviceInfo {
                id: i.to_string(),
                name: if name.is_empty() {
                    format!("Input {i}")
                } else {
                    name
                },
                // The first device we successfully enumerate stands in for the
                // system default (waveIn exposes no default-device query).
                is_default: out.is_empty(),
            });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_winmm() {
        Winmm::load().expect("winmm.dll loads on this host");
    }

    #[test]
    fn enumerates_without_panicking() {
        // CI hosts may have no input device; just assert the call is sound and
        // any returned entries are well-formed.
        let devices = enumerate_input_devices();
        for d in &devices {
            assert!(!d.id.is_empty(), "device id should be a non-empty index");
            assert!(!d.name.is_empty(), "device name should not be empty");
        }
        // At most one default, and when any device exists the first is default.
        let defaults = devices.iter().filter(|d| d.is_default).count();
        assert!(defaults <= 1, "at most one default, found {defaults}");
        if !devices.is_empty() {
            assert!(devices[0].is_default, "first device should be the default");
        }
    }
}

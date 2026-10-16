//! Minimal Windows audio input via `LoadLibrary`-ing `winmm.dll`.
//!
//! Same header-free, runtime-load pattern as the CoreAudio and AAudio paths:
//! declare the handful of `waveIn*` symbols we use and resolve them at runtime,
//! so the build needs no Windows SDK headers/libs and honors the
//! "no system dependencies" constraint. `winmm.dll` ships with every Windows
//! install (the legacy Multimedia / `waveIn` API), so consumers need nothing
//! extra.
//!
//! The device is opened with `CALLBACK_EVENT`: the driver signals an event as
//! it fills each buffer, and a capture thread appends the buffer's S16 frames
//! to a shared queue and hands the buffer back. `read` drains the queue.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use libloading::Library;

use crate::queue::SampleQueue;
use crate::{DeviceInfo, PcmSource};

// --- Win32 multimedia ABI constants ----------------------------------------

// MMRESULT success.
pub(crate) const MMSYSERR_NOERROR: u32 = 0;
// LPWAVEFORMATEX format tag for uncompressed PCM.
const WAVE_FORMAT_PCM: u16 = 1;
// waveInOpen: signal the event handle passed as dwCallback when a buffer is
// returned.
const CALLBACK_EVENT: u32 = 0x0005_0000;
// waveInOpen device id meaning "let the system pick the preferred input".
const WAVE_MAPPER: u32 = 0xFFFF_FFFF;
// WAVEHDR::dwFlags: the driver has finished with the buffer.
const WHDR_DONE: u32 = 0x0000_0001;
// waveInMessage: query the preferred (default) input device id.
const DRVM_MAPPER_PREFERRED_GET: u32 = 0x2015;
// Max device-name length (in WCHARs) in WAVEINCAPSW::szPname.
const MAXPNAMELEN: usize = 32;

pub(crate) type HWaveIn = *mut c_void;
type Handle = *mut c_void;

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

type FnGetNumDevs = unsafe extern "system" fn() -> u32;
type FnGetDevCaps = unsafe extern "system" fn(usize, *mut WaveInCapsW, u32) -> u32;
type FnOpen =
    unsafe extern "system" fn(*mut HWaveIn, u32, *const WaveFormatEx, usize, usize, u32) -> u32;
type FnHdrOp = unsafe extern "system" fn(HWaveIn, *mut WaveHdr, u32) -> u32;
type FnStreamOp = unsafe extern "system" fn(HWaveIn) -> u32;
type FnGetErrorText = unsafe extern "system" fn(u32, *mut u16, u32) -> u32;
type FnMessage = unsafe extern "system" fn(HWaveIn, u32, usize, usize) -> u32;
// kernel32, for the CALLBACK_EVENT handle.
type FnCreateEvent = unsafe extern "system" fn(*mut c_void, i32, i32, *const u16) -> Handle;
type FnHandleOp = unsafe extern "system" fn(Handle) -> i32;
type FnWait = unsafe extern "system" fn(Handle, u32) -> u32;

/// Resolved entry points into `winmm.dll` (and the few `kernel32.dll` event
/// calls capture needs).
pub struct Winmm {
    _lib: Library,
    _kernel32: Library,
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
    message: FnMessage,
    create_event: FnCreateEvent,
    set_event: FnHandleOp,
    close_handle: FnHandleOp,
    wait: FnWait,
}

unsafe impl Send for Winmm {}
unsafe impl Sync for Winmm {}

impl Winmm {
    pub fn load() -> Result<Winmm, String> {
        unsafe {
            let lib =
                Library::new("winmm.dll").map_err(|e| format!("failed to load winmm.dll: {e}"))?;
            let kernel32 = Library::new("kernel32.dll")
                .map_err(|e| format!("failed to load kernel32.dll: {e}"))?;
            macro_rules! sym {
                ($name:literal) => {
                    sym!(lib, $name)
                };
                ($lib:ident, $name:literal) => {
                    *$lib.get($name).map_err(|e| {
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
                message: sym!(b"waveInMessage\0"),
                create_event: sym!(kernel32, b"CreateEventW\0"),
                set_event: sym!(kernel32, b"SetEvent\0"),
                close_handle: sym!(kernel32, b"CloseHandle\0"),
                wait: sym!(kernel32, b"WaitForSingleObject\0"),
                _lib: lib,
                _kernel32: kernel32,
            })
        }
    }

    /// waveInGetNumDevs.
    #[cfg(test)]
    pub(crate) unsafe fn device_count(&self) -> u32 {
        (self.get_num_devs)()
    }

    /// waveInMessage, for driver queries.
    pub(crate) unsafe fn message(&self, device: HWaveIn, msg: u32, dw1: usize, dw2: usize) -> u32 {
        (self.message)(device, msg, dw1, dw2)
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

/// A raw WAVEHDR pointer for the capture thread. The headers are boxed in
/// [`WinmmCapture`], which outlives the thread (Drop joins it first).
struct HeaderPtr(*mut WaveHdr);
unsafe impl Send for HeaderPtr {}

/// The device handle, shared with the capture thread (waveIn calls on one
/// handle from different threads are allowed).
#[derive(Clone, Copy)]
struct DeviceHandle(HWaveIn);
unsafe impl Send for DeviceHandle {}

/// The event the driver signals whenever it returns a buffer.
#[derive(Clone, Copy)]
struct EventHandle(Handle);
unsafe impl Send for EventHandle {}

/// An open `waveIn` device feeding captured S16 frames into a shared buffer.
pub struct WinmmCapture {
    winmm: Arc<Winmm>,
    hwi: HWaveIn,
    event: Handle,
    samples: Arc<SampleQueue>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
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

// The handle and headers are touched by the owning thread only while the
// capture thread is not running (open, and Drop after joining it); the
// samples are behind SampleQueue's lock.
unsafe impl Send for WinmmCapture {}
unsafe impl Sync for WinmmCapture {}

const RING_BUFFERS: usize = 4;
const FRAMES_PER_BUFFER: usize = 2048;
// How long the capture thread waits for a buffer before rechecking its stop
// flag.
const WAIT_MS: u32 = 50;

impl WinmmCapture {
    pub fn open(
        winmm: &Arc<Winmm>,
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

        unsafe {
            // Auto-reset, initially unsignaled.
            let event = (winmm.create_event)(std::ptr::null_mut(), 0, 0, std::ptr::null());
            if event.is_null() {
                return Err("CreateEventW failed".into());
            }
            // With CALLBACK_EVENT the driver only signals the event; the
            // buffers are collected and re-queued on our own thread. (Calling
            // waveIn functions from a CALLBACK_FUNCTION callback is not
            // allowed, and re-queueing there raced with teardown.)
            let mut hwi: HWaveIn = std::ptr::null_mut();
            let rc = (winmm.open)(&mut hwi, device, &format, event as usize, 0, CALLBACK_EVENT);
            if rc != MMSYSERR_NOERROR {
                (winmm.close_handle)(event);
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
                    Self::teardown(winmm, hwi, event, &mut headers);
                    return Err(format!("waveInPrepareHeader: {}", winmm.error_text(rc)));
                }
                let rc = (winmm.add_buffer)(hwi, &mut *hdr, hdr_size);
                if rc != MMSYSERR_NOERROR {
                    (winmm.unprepare)(hwi, &mut *hdr, hdr_size);
                    Self::teardown(winmm, hwi, event, &mut headers);
                    return Err(format!("waveInAddBuffer: {}", winmm.error_text(rc)));
                }
                // Push only after the header is queued; the Vec move keeps the
                // heap WAVEHDR/buffer addresses we handed the OS valid.
                buffers.push(buf);
                headers.push(hdr);
            }

            let rc = (winmm.start)(hwi);
            if rc != MMSYSERR_NOERROR {
                Self::teardown(winmm, hwi, event, &mut headers);
                return Err(format!("waveInStart: {}", winmm.error_text(rc)));
            }

            let samples = Arc::new(SampleQueue::default());
            let stop = Arc::new(AtomicBool::new(false));
            let worker = Self::spawn_worker(
                winmm.clone(),
                DeviceHandle(hwi),
                EventHandle(event),
                headers.iter_mut().map(|h| HeaderPtr(&mut **h)).collect(),
                samples.clone(),
                stop.clone(),
            );
            Ok(WinmmCapture {
                winmm: winmm.clone(),
                hwi,
                event,
                samples,
                stop,
                worker: Some(worker),
                headers,
                _buffers: buffers,
                channels,
            })
        }
    }

    /// Collects each buffer the driver marks done, then hands it back to the
    /// driver, until `stop` is set.
    fn spawn_worker(
        winmm: Arc<Winmm>,
        hwi: DeviceHandle,
        event: EventHandle,
        headers: Vec<HeaderPtr>,
        samples: Arc<SampleQueue>,
        stop: Arc<AtomicBool>,
    ) -> JoinHandle<()> {
        std::thread::spawn(move || {
            let (hwi, event) = (hwi, event);
            let hdr_size = std::mem::size_of::<WaveHdr>() as u32;
            while !stop.load(Ordering::SeqCst) {
                unsafe { (winmm.wait)(event.0, WAIT_MS) };
                for hdr in &headers {
                    let hdr = hdr.0;
                    // The driver sets WHDR_DONE from its own thread.
                    let flags = unsafe { std::ptr::read_volatile(&(*hdr).flags) };
                    if flags & WHDR_DONE == 0 {
                        continue;
                    }
                    unsafe {
                        let n = (*hdr).bytes_recorded as usize / 2;
                        let data = (*hdr).data as *const i16;
                        if n > 0 && !data.is_null() {
                            samples.push(std::slice::from_raw_parts(data, n));
                        }
                        let rc = (winmm.add_buffer)(hwi.0, hdr, hdr_size);
                        if rc != MMSYSERR_NOERROR {
                            samples.fail(format!("waveInAddBuffer: {}", winmm.error_text(rc)));
                            return;
                        }
                    }
                }
            }
        })
    }

    /// Stops the device and releases every prepared header and the event.
    /// Used both for the error path during open and from Drop; the capture
    /// thread, if any, must have exited, so nothing re-queues a buffer.
    #[allow(clippy::vec_box)] // see the `headers` field: stable WAVEHDR addresses.
    unsafe fn teardown(
        winmm: &Winmm,
        hwi: HWaveIn,
        event: Handle,
        headers: &mut Vec<Box<WaveHdr>>,
    ) {
        let hdr_size = std::mem::size_of::<WaveHdr>() as u32;
        (winmm.stop)(hwi);
        // Returns all queued buffers so the headers can be unprepared.
        (winmm.reset)(hwi);
        for hdr in headers.iter_mut() {
            (winmm.unprepare)(hwi, &mut **hdr, hdr_size);
        }
        (winmm.close)(hwi);
        (winmm.close_handle)(event);
        headers.clear();
    }
}

impl PcmSource for WinmmCapture {
    fn read(&self, max: usize) -> Result<Vec<i16>, String> {
        self.samples.read(max)
    }

    fn channels(&self) -> u32 {
        self.channels
    }
}

impl Drop for WinmmCapture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        unsafe { (self.winmm.set_event)(self.event) };
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        unsafe { Self::teardown(&self.winmm, self.hwi, self.event, &mut self.headers) };
    }
}

/// Enumerates every `waveIn` input device. Returns an empty Vec on any failure.
///
/// `waveIn` identifies devices by index, so the ids are decimal indices. The
/// default is the input WAVE_MAPPER uses (the system's preferred input), or the
/// first device if that cannot be queried.
pub fn enumerate_input_devices() -> Vec<DeviceInfo> {
    let winmm = match Winmm::load() {
        Ok(w) => w,
        Err(_) => return Vec::new(),
    };
    unsafe {
        let count = (winmm.get_num_devs)();
        let preferred = preferred_input(&winmm);
        let full_names = crate::winmm_names::full_names(&winmm, count);
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
            // szPname is cut at 31 characters; prefer the endpoint's name.
            let name = full_names
                .get(i as usize)
                .cloned()
                .flatten()
                .unwrap_or_else(|| utf16_to_string(&caps.pname));
            out.push(DeviceInfo {
                id: i.to_string(),
                name: if name.is_empty() {
                    format!("Input {i}")
                } else {
                    name
                },
                is_default: false,
            });
        }
        let default = preferred
            .and_then(|p| out.iter().position(|d| d.id == p.to_string()))
            .unwrap_or(0);
        if let Some(d) = out.get_mut(default) {
            d.is_default = true;
        }
        out
    }
}

/// The index of the input WAVE_MAPPER records from, if the driver says.
unsafe fn preferred_input(winmm: &Winmm) -> Option<u32> {
    let mut device: u32 = u32::MAX;
    let mut flags: u32 = 0;
    let rc = (winmm.message)(
        WAVE_MAPPER as usize as HWaveIn,
        DRVM_MAPPER_PREFERRED_GET,
        &mut device as *mut u32 as usize,
        &mut flags as *mut u32 as usize,
    );
    (rc == MMSYSERR_NOERROR && device != u32::MAX).then_some(device)
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
        // Exactly one default whenever any device exists.
        let defaults = devices.iter().filter(|d| d.is_default).count();
        assert_eq!(defaults, usize::from(!devices.is_empty()));
    }

    #[test]
    fn the_default_is_the_mapper_preferred_input() {
        let winmm = Winmm::load().unwrap();
        let devices = enumerate_input_devices();
        if devices.is_empty() {
            return;
        }
        let preferred =
            unsafe { preferred_input(&winmm) }.expect("the mapper reports a preferred input");
        let default = devices.iter().find(|d| d.is_default).unwrap();
        assert_eq!(default.id, preferred.to_string());
    }

    #[test]
    fn captures_and_stops_promptly() {
        let winmm = Arc::new(Winmm::load().unwrap());
        // A host without an input device cannot open one; nothing to test.
        let Ok(capture) = WinmmCapture::open(&winmm, 1, 16_000, None) else {
            return;
        };
        std::thread::sleep(std::time::Duration::from_millis(500));
        let samples = capture.read(usize::MAX).unwrap();
        assert!(
            samples.len() > 4_000,
            "got {} samples in 500 ms",
            samples.len()
        );
        let started = std::time::Instant::now();
        drop(capture);
        assert!(started.elapsed() < std::time::Duration::from_millis(500));
    }

    #[test]
    fn survives_rapid_open_and_close() {
        let winmm = Arc::new(Winmm::load().unwrap());
        for _ in 0..20 {
            let Ok(capture) = WinmmCapture::open(&winmm, 2, 48_000, None) else {
                return;
            };
            std::thread::sleep(std::time::Duration::from_millis(10));
            drop(capture);
        }
    }
}

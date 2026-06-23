//! Minimal ALSA input binding obtained by `dlopen`-ing the runtime
//! `libasound.so.2`.
//!
//! ALSA is the standard audio system on Linux and needs no headers at build time;
//! we declare the few symbols we use ourselves. This keeps the "no system dependencies"
//! guarantee on Linux too.
//!
//! ALSA input is pull-based (snd_pcm_readi), but our `PcmSource` is polled from Dart
//! at its own cadence. A reader thread loops `readi` into a shared buffer that
//! `PcmSource::read` drains, so the device is serviced promptly regardless of how
//! often Dart polls.

use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use libloading::Library;

use crate::PcmSource;

// ALSA error codes and constants.
const SND_PCM_STREAM_CAPTURE: c_uint = 1;
const SND_PCM_FORMAT_S16_LE: c_int = 2;
const SND_PCM_ACCESS_RW_INTERLEAVED: c_uint = 3;

type PcmT = c_void;
type PcmHwParamsT = c_void;
type FnPcmOpen = unsafe extern "C" fn(
    *mut *mut PcmT,
    *const c_char,
    c_uint,
    c_int,
) -> c_int;
type FnPcmClose = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmHwParamsMalloc = unsafe extern "C" fn(*mut *mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsFree = unsafe extern "C" fn(*mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsAny = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsSetAccess =
    unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint) -> c_int;
type FnPcmHwParamsSetFormat = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_int) -> c_int;
type FnPcmHwParamsSetChannels = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint) -> c_int;
type FnPcmHwParamsSetRate =
    unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint, c_int) -> c_int;
type FnPcmHwParams = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT) -> c_int;
type FnPcmPrepare = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmStart = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmDrop = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmReadi = unsafe extern "C" fn(*mut PcmT, *mut c_void, c_ulong) -> c_long;
type FnStrError = unsafe extern "C" fn(c_int) -> *const c_char;

/// Resolved entry points into `libasound.so.2`.
pub struct Alsa {
    _lib: Library,
    pcm_open: FnPcmOpen,
    pcm_close: FnPcmClose,
    pcm_hw_params_malloc: FnPcmHwParamsMalloc,
    pcm_hw_params_free: FnPcmHwParamsFree,
    pcm_hw_params_any: FnPcmHwParamsAny,
    pcm_hw_params_set_access: FnPcmHwParamsSetAccess,
    pcm_hw_params_set_format: FnPcmHwParamsSetFormat,
    pcm_hw_params_set_channels: FnPcmHwParamsSetChannels,
    pcm_hw_params_set_rate: FnPcmHwParamsSetRate,
    pcm_hw_params: FnPcmHwParams,
    pcm_prepare: FnPcmPrepare,
    pcm_start: FnPcmStart,
    pcm_drop: FnPcmDrop,
    pcm_readi: FnPcmReadi,
    str_error: FnStrError,
}

unsafe impl Send for Alsa {}
unsafe impl Sync for Alsa {}

impl Alsa {
    pub fn load() -> Result<Alsa, String> {
        unsafe {
            let lib = Library::new("libasound.so.2")
                .map_err(|e| format!("failed to load libasound.so.2: {e}"))?;
            macro_rules! sym {
                ($name:literal) => {
                    *lib.get($name).map_err(|e| {
                        format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                    })?
                };
            }

            // Try to load all symbols with better error reporting
            let pcm_open = sym!(b"snd_pcm_open\0");
            let pcm_close = sym!(b"snd_pcm_close\0");
            let pcm_hw_params_malloc = sym!(b"snd_pcm_hw_params_malloc\0");
            let pcm_hw_params_free = sym!(b"snd_pcm_hw_params_free\0");
            let pcm_hw_params_any = sym!(b"snd_pcm_hw_params_any\0");
            let pcm_hw_params_set_access = sym!(b"snd_pcm_hw_params_set_access\0");
            let pcm_hw_params_set_format = sym!(b"snd_pcm_hw_params_set_format\0");
            let pcm_hw_params_set_channels = sym!(b"snd_pcm_hw_params_set_channels\0");
            let pcm_hw_params_set_rate = sym!(b"snd_pcm_hw_params_set_rate\0");
            let pcm_hw_params = sym!(b"snd_pcm_hw_params\0");
            let pcm_prepare = sym!(b"snd_pcm_prepare\0");
            let pcm_start = sym!(b"snd_pcm_start\0");
            let pcm_drop = sym!(b"snd_pcm_drop\0");
            let pcm_readi = sym!(b"snd_pcm_readi\0");
            let str_error = sym!(b"snd_strerror\0");

            let alsa = Alsa {
                pcm_open,
                pcm_close,
                pcm_hw_params_malloc,
                pcm_hw_params_free,
                pcm_hw_params_any,
                pcm_hw_params_set_access,
                pcm_hw_params_set_format,
                pcm_hw_params_set_channels,
                pcm_hw_params_set_rate,
                pcm_hw_params,
                pcm_prepare,
                pcm_start,
                pcm_drop,
                pcm_readi,
                str_error,
                _lib: lib,
            };
            Ok(alsa)
        }
    }

    fn str_error(&self, err: c_int) -> String {
        unsafe {
            let ptr = (self.str_error)(err);
            if ptr.is_null() {
                return format!("ALSA error {err}");
            }
            std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }
}

// A raw PCM pointer the reader thread owns for the stream's lifetime. ALSA PCM
// handles are single-threaded; only the reader thread touches it.
struct PcmPtr(*mut PcmT);
unsafe impl Send for PcmPtr {}

/// An open ALSA input stream feeding captured S16 frames into a shared buffer.
pub struct AlsaCapture {
    alsa: Arc<Alsa>,
    samples: Arc<Mutex<Vec<i16>>>,
    stop: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
    channels: u32,
}

impl AlsaCapture {
    pub fn open(alsa: &Arc<Alsa>, channels: u32, rate: u32) -> Result<Self, String> {
        unsafe {
            // Open the default ALSA PCM input device (usually "default").
            let device = std::ffi::CStr::from_bytes_with_nul(b"default\0").unwrap();
            let mut pcm: *mut PcmT = std::ptr::null_mut();
            let rc = (alsa.pcm_open)(
                &mut pcm,
                device.as_ptr(),
                SND_PCM_STREAM_CAPTURE,
                0,
            );
            if rc < 0 {
                return Err(format!("snd_pcm_open: {}", alsa.str_error(rc)));
            }

            // Allocate and configure hardware parameters.
            let mut hw_params: *mut PcmHwParamsT = std::ptr::null_mut();
            let rc = (alsa.pcm_hw_params_malloc)(&mut hw_params);
            if rc < 0 {
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_malloc: {}", alsa.str_error(rc)));
            }
            if hw_params.is_null() {
                (alsa.pcm_close)(pcm);
                return Err("snd_pcm_hw_params_malloc returned null".into());
            }

            let rc = (alsa.pcm_hw_params_any)(pcm, hw_params);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_any: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_hw_params_set_access)(pcm, hw_params, SND_PCM_ACCESS_RW_INTERLEAVED);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_set_access: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_hw_params_set_format)(pcm, hw_params, SND_PCM_FORMAT_S16_LE);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_set_format: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_hw_params_set_channels)(pcm, hw_params, channels as c_uint);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_set_channels: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_hw_params_set_rate)(pcm, hw_params, rate as c_uint, 0);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params_set_rate: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_hw_params)(pcm, hw_params);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_hw_params: {}", alsa.str_error(rc)));
            }

            // hw_params no longer needed; free it.
            (alsa.pcm_hw_params_free)(hw_params);

            let rc = (alsa.pcm_prepare)(pcm);
            if rc < 0 {
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_prepare: {}", alsa.str_error(rc)));
            }

            let rc = (alsa.pcm_start)(pcm);
            if rc < 0 {
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_start: {}", alsa.str_error(rc)));
            }

            let samples = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let reader = Self::spawn_reader(
                alsa.clone(),
                PcmPtr(pcm),
                samples.clone(),
                stop.clone(),
                channels,
            );
            Ok(AlsaCapture {
                alsa: alsa.clone(),
                samples,
                stop,
                reader: Some(reader),
                channels,
            })
        }
    }

    fn spawn_reader(
        alsa: Arc<Alsa>,
        pcm: PcmPtr,
        samples: Arc<Mutex<Vec<i16>>>,
        stop: Arc<AtomicBool>,
        channels: u32,
    ) -> JoinHandle<()> {
        std::thread::spawn(move || {
            // Move the raw PCM pointer into this thread; it owns it now.
            let pcm = pcm;
            // ~1024 frames per read keeps latency low; the shared buffer grows
            // as needed and is drained by PcmSource::read.
            let frames_per_read: usize = 1024;
            let mut buf = vec![0i16; frames_per_read * channels as usize];
            while !stop.load(Ordering::SeqCst) {
                let n = unsafe {
                    (alsa.pcm_readi)(
                        pcm.0,
                        buf.as_mut_ptr() as *mut c_void,
                        frames_per_read as c_ulong,
                    )
                };
                if n > 0 {
                    let count = (n as usize) * (channels as usize);
                    if let Ok(mut s) = samples.lock() {
                        s.extend_from_slice(&buf[..count]);
                    }
                } else if n < 0 {
                    // Negative is an error code; stop reading.
                    break;
                }
                // n == 0 means no data available; loop and retry.
            }
            unsafe {
                let _ = (alsa.pcm_drop)(pcm.0);
                let _ = (alsa.pcm_close)(pcm.0);
            }
        })
    }
}

impl PcmSource for AlsaCapture {
    fn read(&self, max: usize) -> Result<Vec<i16>, String> {
        let mut samples = self.samples.lock().map_err(|e| e.to_string())?;
        if samples.is_empty() || max == 0 {
            return Ok(Vec::new());
        }
        if samples.len() <= max {
            return Ok(std::mem::take(&mut *samples));
        }
        let rest = samples.split_off(max);
        let out = std::mem::replace(&mut *samples, rest);
        Ok(out)
    }

    fn channels(&self) -> u32 {
        self.channels
    }
}

impl Drop for AlsaCapture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.reader.take() {
            let _ = h.join();
        }
        // The reader thread stops/closes the PCM before exiting.
        let _ = &self.alsa;
    }
}

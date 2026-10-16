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

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use libloading::Library;

use crate::queue::SampleQueue;
use crate::{DeviceInfo, PcmSource};

// ALSA error codes and constants.
const SND_PCM_STREAM_CAPTURE: c_uint = 1;
const SND_PCM_FORMAT_S16_LE: c_int = 2;
const SND_PCM_ACCESS_RW_INTERLEAVED: c_uint = 3;
const EAGAIN: c_int = 11;
// How long the reader waits for input before rechecking its stop flag.
const WAIT_MS: c_int = 20;

type PcmT = c_void;
type PcmHwParamsT = c_void;
type FnPcmOpen = unsafe extern "C" fn(*mut *mut PcmT, *const c_char, c_uint, c_int) -> c_int;
type FnPcmClose = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmHwParamsMalloc = unsafe extern "C" fn(*mut *mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsFree = unsafe extern "C" fn(*mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsAny = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT) -> c_int;
type FnPcmHwParamsSetAccess = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint) -> c_int;
type FnPcmHwParamsSetFormat = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_int) -> c_int;
type FnPcmHwParamsSetChannels = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint) -> c_int;
type FnPcmHwParamsSetRate =
    unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT, c_uint, c_int) -> c_int;
type FnPcmHwParams = unsafe extern "C" fn(*mut PcmT, *mut PcmHwParamsT) -> c_int;
type FnPcmPrepare = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmStart = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmDrop = unsafe extern "C" fn(*mut PcmT) -> c_int;
type FnPcmReadi = unsafe extern "C" fn(*mut PcmT, *mut c_void, c_ulong) -> c_long;
type FnPcmRecover = unsafe extern "C" fn(*mut PcmT, c_int, c_int) -> c_int;
type FnPcmNonblock = unsafe extern "C" fn(*mut PcmT, c_int) -> c_int;
type FnPcmWait = unsafe extern "C" fn(*mut PcmT, c_int) -> c_int;
type FnStrError = unsafe extern "C" fn(c_int) -> *const c_char;
type FnDeviceNameHint = unsafe extern "C" fn(c_int, *const c_char, *mut *mut *mut c_void) -> c_int;
type FnDeviceNameGetHint = unsafe extern "C" fn(*const c_void, *const c_char) -> *mut c_char;
type FnDeviceNameFreeHint = unsafe extern "C" fn(*mut *mut c_void) -> c_int;

extern "C" {
    // snd_device_name_get_hint returns malloc'd strings the caller frees.
    fn free(ptr: *mut c_void);
}

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
    pcm_recover: FnPcmRecover,
    pcm_nonblock: FnPcmNonblock,
    pcm_wait: FnPcmWait,
    str_error: FnStrError,
    device_name_hint: FnDeviceNameHint,
    device_name_get_hint: FnDeviceNameGetHint,
    device_name_free_hint: FnDeviceNameFreeHint,
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
            let pcm_recover = sym!(b"snd_pcm_recover\0");
            let pcm_nonblock = sym!(b"snd_pcm_nonblock\0");
            let pcm_wait = sym!(b"snd_pcm_wait\0");
            let str_error = sym!(b"snd_strerror\0");
            let device_name_hint = sym!(b"snd_device_name_hint\0");
            let device_name_get_hint = sym!(b"snd_device_name_get_hint\0");
            let device_name_free_hint = sym!(b"snd_device_name_free_hint\0");

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
                pcm_recover,
                pcm_nonblock,
                pcm_wait,
                str_error,
                device_name_hint,
                device_name_get_hint,
                device_name_free_hint,
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
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }

    /// Reads one field (`NAME`, `DESC`, `IOID`) of a device-name hint.
    unsafe fn hint_field(&self, hint: *const c_void, field: &CStr) -> Option<String> {
        let ptr = (self.device_name_get_hint)(hint, field.as_ptr());
        if ptr.is_null() {
            return None;
        }
        let value = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        free(ptr as *mut c_void);
        Some(value)
    }
}

// A raw PCM pointer the reader thread owns for the stream's lifetime. ALSA PCM
// handles are single-threaded; only the reader thread touches it.
struct PcmPtr(*mut PcmT);
unsafe impl Send for PcmPtr {}

/// An open ALSA input stream feeding captured S16 frames into a shared buffer.
pub struct AlsaCapture {
    alsa: Arc<Alsa>,
    samples: Arc<SampleQueue>,
    stop: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
    channels: u32,
}

impl AlsaCapture {
    /// Opens `device_id` (an ALSA PCM name such as `plughw:CARD=Audio,DEV=0`),
    /// or `default` -- normally the sound server -- when it is `None`.
    pub fn open(
        alsa: &Arc<Alsa>,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Self, String> {
        let name = device_id.unwrap_or("default");
        let device = CString::new(name).map_err(|e| e.to_string())?;
        unsafe {
            let mut pcm: *mut PcmT = std::ptr::null_mut();
            let rc = (alsa.pcm_open)(&mut pcm, device.as_ptr(), SND_PCM_STREAM_CAPTURE, 0);
            if rc < 0 {
                return Err(format!("snd_pcm_open({name}): {}", alsa.str_error(rc)));
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
                return Err(format!(
                    "snd_pcm_hw_params_set_access: {}",
                    alsa.str_error(rc)
                ));
            }

            let rc = (alsa.pcm_hw_params_set_format)(pcm, hw_params, SND_PCM_FORMAT_S16_LE);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!(
                    "snd_pcm_hw_params_set_format: {}",
                    alsa.str_error(rc)
                ));
            }

            let rc = (alsa.pcm_hw_params_set_channels)(pcm, hw_params, channels as c_uint);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!(
                    "snd_pcm_hw_params_set_channels: {}",
                    alsa.str_error(rc)
                ));
            }

            let rc = (alsa.pcm_hw_params_set_rate)(pcm, hw_params, rate as c_uint, 0);
            if rc < 0 {
                (alsa.pcm_hw_params_free)(hw_params);
                (alsa.pcm_close)(pcm);
                return Err(format!(
                    "snd_pcm_hw_params_set_rate: {}",
                    alsa.str_error(rc)
                ));
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

            // Read without blocking (see spawn_reader).
            let rc = (alsa.pcm_nonblock)(pcm, 1);
            if rc < 0 {
                (alsa.pcm_close)(pcm);
                return Err(format!("snd_pcm_nonblock: {}", alsa.str_error(rc)));
            }

            let samples = Arc::new(SampleQueue::default());
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
        samples: Arc<SampleQueue>,
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
            // A blocking readi only returns at a period boundary, which the
            // sound server may set hundreds of milliseconds apart; Drop joins
            // this thread, so that stalled stopping a recording. Wait in short
            // slices instead and read whatever has arrived.
            while !stop.load(Ordering::SeqCst) {
                let rc = unsafe { (alsa.pcm_wait)(pcm.0, WAIT_MS) };
                if rc == 0 {
                    continue; // timed out; recheck the stop flag
                }
                let n = unsafe {
                    (alsa.pcm_readi)(
                        pcm.0,
                        buf.as_mut_ptr() as *mut c_void,
                        frames_per_read as c_ulong,
                    )
                };
                // A failed wait is reported by the read that follows it.
                if n > 0 {
                    let count = (n as usize) * (channels as usize);
                    samples.push(&buf[..count]);
                } else if n == -(EAGAIN as c_long) {
                    continue; // nothing ready after all
                } else if n < 0 {
                    // Negative is an error code. An overrun (-EPIPE) or a
                    // suspend (-ESTRPIPE) is recoverable, at the cost of a
                    // gap; anything else ends capture and is reported through
                    // PcmSource::read rather than reading as silence.
                    let err = n as c_int;
                    if unsafe { (alsa.pcm_recover)(pcm.0, err, 1) } < 0 {
                        samples.fail(format!("snd_pcm_readi: {}", alsa.str_error(err)));
                        break;
                    }
                }
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
        self.samples.read(max)
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

/// Lists ALSA capture devices: `default` (normally the sound server) first,
/// then each sound card's input-capable PCMs. The ids are ALSA PCM names, which
/// [`AlsaCapture::open`] accepts. Returns just `default` if the hints are
/// unavailable, and nothing if libasound cannot be loaded.
pub fn enumerate_input_devices() -> Vec<DeviceInfo> {
    let Ok(alsa) = Alsa::load() else {
        return Vec::new();
    };
    let mut out = vec![DeviceInfo {
        id: "default".into(),
        name: "Default".into(),
        is_default: true,
    }];
    unsafe {
        let mut hints: *mut *mut c_void = std::ptr::null_mut();
        if (alsa.device_name_hint)(-1, c"pcm".as_ptr(), &mut hints) < 0 || hints.is_null() {
            return out;
        }
        let mut i = 0;
        loop {
            let hint = *hints.add(i);
            if hint.is_null() {
                break;
            }
            i += 1;
            let Some(name) = alsa.hint_field(hint, c"NAME") else {
                continue;
            };
            let ioid = alsa.hint_field(hint, c"IOID");
            if !is_card_input(&name, ioid.as_deref()) {
                continue;
            }
            let label = match alsa.hint_field(hint, c"DESC") {
                Some(desc) => one_line(&desc),
                None => name.clone(),
            };
            out.push(DeviceInfo {
                id: name,
                name: label,
                is_default: false,
            });
        }
        (alsa.device_name_free_hint)(hints);
    }
    out
}

/// Whether a hinted PCM is one of a sound card's capture routes. Global plugins
/// (rate converters, sound-server shims, `null`) are skipped -- `default`
/// already reaches the sound server -- as are route kinds that only play but
/// do not say so in IOID.
fn is_card_input(name: &str, ioid: Option<&str>) -> bool {
    const OUTPUT_ONLY: [&str; 5] = ["surround", "dmix", "usbstream", "iec958", "hdmi"];
    name.contains("CARD=")
        && ioid != Some("Output")
        && !OUTPUT_ONLY.iter().any(|kind| name.starts_with(kind))
}

/// Folds a hint's two-line DESC ("USB Audio, USB Audio\nDirect sample snooping
/// device") into one display line.
fn one_line(desc: &str) -> String {
    let mut lines = desc.lines().map(str::trim).filter(|l| !l.is_empty());
    match (lines.next(), lines.next()) {
        (Some(card), Some(kind)) => format!("{card} ({kind})"),
        (Some(card), None) => card.to_string(),
        _ => desc.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{is_card_input, one_line};

    #[test]
    fn keeps_card_capture_routes_only() {
        assert!(is_card_input("plughw:CARD=Audio,DEV=0", None));
        assert!(is_card_input("dsnoop:CARD=Audio,DEV=0", Some("Input")));
        assert!(!is_card_input("hdmi:CARD=NVidia,DEV=0", Some("Output")));
        assert!(!is_card_input("surround51:CARD=PCH", None));
        assert!(!is_card_input("usbstream:CARD=PCH", None));
        assert!(!is_card_input("pipewire", None));
        assert!(!is_card_input("null", None));
    }

    #[test]
    fn folds_the_description_onto_one_line() {
        assert_eq!(
            one_line("USB Audio, USB Audio\nDirect sample snooping device"),
            "USB Audio, USB Audio (Direct sample snooping device)"
        );
        assert_eq!(one_line("HDA Intel PCH"), "HDA Intel PCH");
    }
}

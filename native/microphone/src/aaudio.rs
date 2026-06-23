//! Minimal AAudio input binding obtained by `dlopen`-ing the runtime
//! `libaaudio.so`.
//!
//! AAudio ships with Android (API 26+) and needs no NDK headers at build time;
//! we declare the few symbols we use ourselves, mirroring the ALSA/CoreAudio
//! approach. This keeps the "no system dependencies" guarantee on Android too.
//!
//! AAudio input is pull-based (AAudioStream_read), but our `PcmSource` is
//! polled from Dart at its own cadence. A reader thread loops `read` into a
//! shared buffer that `PcmSource::read` drains, so the device is serviced
//! promptly regardless of how often Dart polls.

use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use libloading::Library;

use crate::PcmSource;

// Stable AAudio ABI constants.
const AAUDIO_DIRECTION_INPUT: c_int = 1;
const AAUDIO_FORMAT_PCM_I16: c_int = 1;
const AAUDIO_OK: c_int = 0;

type Builder = c_void;
type Stream = c_void;

type FnCreateBuilder = unsafe extern "C" fn(*mut *mut Builder) -> c_int;
type FnBuilderSetI32 = unsafe extern "C" fn(*mut Builder, c_int);
type FnBuilderOpen = unsafe extern "C" fn(*mut Builder, *mut *mut Stream) -> c_int;
type FnBuilderDelete = unsafe extern "C" fn(*mut Builder) -> c_int;
type FnStreamOp = unsafe extern "C" fn(*mut Stream) -> c_int;
type FnStreamRead = unsafe extern "C" fn(*mut Stream, *mut c_void, c_int, i64) -> c_int;
type FnStreamGetI32 = unsafe extern "C" fn(*mut Stream) -> c_int;
type FnResultText = unsafe extern "C" fn(c_int) -> *const c_char;

/// Resolved entry points into `libaaudio.so`.
pub struct Aaudio {
    _lib: Library,
    create_builder: FnCreateBuilder,
    builder_set_direction: FnBuilderSetI32,
    builder_set_sample_rate: FnBuilderSetI32,
    builder_set_channel_count: FnBuilderSetI32,
    builder_set_format: FnBuilderSetI32,
    builder_open: FnBuilderOpen,
    builder_delete: FnBuilderDelete,
    stream_start: FnStreamOp,
    stream_read: FnStreamRead,
    stream_get_channel_count: FnStreamGetI32,
    stream_stop: FnStreamOp,
    stream_close: FnStreamOp,
    result_text: FnResultText,
}

unsafe impl Send for Aaudio {}
unsafe impl Sync for Aaudio {}

impl Aaudio {
    pub fn load() -> Result<Aaudio, String> {
        unsafe {
            let lib = Library::new("libaaudio.so")
                .map_err(|e| format!("failed to load libaaudio.so: {e}"))?;
            macro_rules! sym {
                ($name:literal) => {
                    *lib.get($name).map_err(|e| {
                        format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                    })?
                };
            }
            let aaudio = Aaudio {
                create_builder: sym!(b"AAudio_createStreamBuilder\0"),
                builder_set_direction: sym!(b"AAudioStreamBuilder_setDirection\0"),
                builder_set_sample_rate: sym!(b"AAudioStreamBuilder_setSampleRate\0"),
                builder_set_channel_count: sym!(b"AAudioStreamBuilder_setChannelCount\0"),
                builder_set_format: sym!(b"AAudioStreamBuilder_setFormat\0"),
                builder_open: sym!(b"AAudioStreamBuilder_openStream\0"),
                builder_delete: sym!(b"AAudioStreamBuilder_delete\0"),
                stream_start: sym!(b"AAudioStream_requestStart\0"),
                stream_read: sym!(b"AAudioStream_read\0"),
                stream_get_channel_count: sym!(b"AAudioStream_getChannelCount\0"),
                stream_stop: sym!(b"AAudioStream_requestStop\0"),
                stream_close: sym!(b"AAudioStream_close\0"),
                result_text: sym!(b"AAudio_convertResultToText\0"),
                _lib: lib,
            };
            Ok(aaudio)
        }
    }

    fn result_text(&self, code: c_int) -> String {
        unsafe {
            let ptr = (self.result_text)(code);
            if ptr.is_null() {
                return format!("AAudio error {code}");
            }
            std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }
}

// A raw stream pointer the reader thread owns for the stream's lifetime. AAudio
// streams are single-consumer; only the reader thread touches it.
struct StreamPtr(*mut Stream);
unsafe impl Send for StreamPtr {}

/// An open AAudio input stream feeding captured S16 frames into a shared buffer.
pub struct AaudioCapture {
    aaudio: Arc<Aaudio>,
    samples: Arc<Mutex<Vec<i16>>>,
    stop: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
    channels: u32,
}

impl AaudioCapture {
    pub fn open(aaudio: &Arc<Aaudio>, channels: u32, rate: u32) -> Result<Self, String> {
        unsafe {
            let mut builder: *mut Builder = std::ptr::null_mut();
            let rc = (aaudio.create_builder)(&mut builder);
            if rc != AAUDIO_OK {
                return Err(format!("createStreamBuilder: {}", aaudio.result_text(rc)));
            }
            (aaudio.builder_set_direction)(builder, AAUDIO_DIRECTION_INPUT);
            (aaudio.builder_set_sample_rate)(builder, rate as c_int);
            (aaudio.builder_set_channel_count)(builder, channels as c_int);
            (aaudio.builder_set_format)(builder, AAUDIO_FORMAT_PCM_I16);

            let mut stream: *mut Stream = std::ptr::null_mut();
            let rc = (aaudio.builder_open)(builder, &mut stream);
            (aaudio.builder_delete)(builder);
            if rc != AAUDIO_OK {
                return Err(format!("openStream: {}", aaudio.result_text(rc)));
            }
            // The device may grant a different channel count than requested.
            let actual_channels = {
                let c = (aaudio.stream_get_channel_count)(stream);
                if c > 0 {
                    c as u32
                } else {
                    channels.max(1)
                }
            };
            let rc = (aaudio.stream_start)(stream);
            if rc != AAUDIO_OK {
                (aaudio.stream_close)(stream);
                return Err(format!("requestStart: {}", aaudio.result_text(rc)));
            }

            let samples = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let reader = Self::spawn_reader(
                aaudio.clone(),
                StreamPtr(stream),
                samples.clone(),
                stop.clone(),
                actual_channels,
            );
            Ok(AaudioCapture {
                aaudio: aaudio.clone(),
                samples,
                stop,
                reader: Some(reader),
                channels: actual_channels,
            })
        }
    }

    fn spawn_reader(
        aaudio: Arc<Aaudio>,
        stream: StreamPtr,
        samples: Arc<Mutex<Vec<i16>>>,
        stop: Arc<AtomicBool>,
        channels: u32,
    ) -> JoinHandle<()> {
        std::thread::spawn(move || {
            // Move the raw stream pointer into this thread; it owns it now.
            let stream = stream;
            // ~1024 frames per read keeps latency low; the shared buffer grows
            // as needed and is drained by PcmSource::read.
            let frames_per_read: c_int = 1024;
            let mut buf = vec![0i16; frames_per_read as usize * channels as usize];
            while !stop.load(Ordering::SeqCst) {
                let n = unsafe {
                    (aaudio.stream_read)(
                        stream.0,
                        buf.as_mut_ptr() as *mut c_void,
                        frames_per_read,
                        100_000_000, // 100 ms timeout
                    )
                };
                if n > 0 {
                    let count = n as usize * channels as usize;
                    if let Ok(mut s) = samples.lock() {
                        s.extend_from_slice(&buf[..count]);
                    }
                } else if n < 0 {
                    // Negative is an error code; stop reading.
                    break;
                }
                // n == 0 means timeout with no data; loop and check stop.
            }
            unsafe {
                (aaudio.stream_stop)(stream.0);
                (aaudio.stream_close)(stream.0);
            }
        })
    }
}

impl PcmSource for AaudioCapture {
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

impl Drop for AaudioCapture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.reader.take() {
            let _ = h.join();
        }
        // The reader thread stops/closes the stream before exiting.
        let _ = &self.aaudio;
    }
}

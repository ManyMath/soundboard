//! Minimal CoreAudio input binding via dlopen of AudioToolbox.framework.
//!
//! Same header-free pattern as the `sound` crate's output path: declare the
//! AudioQueue symbols we use and load them at runtime. AudioToolbox ships with
//! every macOS and iOS install, so consumers need no Xcode SDK linked at build
//! time.
//!
//! AudioQueue input is callback-driven; `PcmSource` is pull-driven. We bridge
//! them with a shared buffer: the input callback appends captured S16 frames to
//! a Mutex<Vec<i16>>, and `read` drains whatever has accumulated.

use std::os::raw::{c_int, c_void};
use std::sync::{Arc, Mutex};

use libloading::Library;

use crate::PcmSource;

const K_LINEAR_PCM: u32 = u32::from_be_bytes(*b"lpcm");
const K_PCM_FLAG_IS_SIGNED_INT: u32 = 0x4;
const K_PCM_FLAG_IS_PACKED: u32 = 0x8;

#[repr(C)]
#[derive(Clone, Copy)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioTimeStamp {
    sample_time: f64,
    host_time: u64,
    rate_scalar: f64,
    word_clock_time: u64,
    smpte_time: [u8; 24],
    flags: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioQueueBuffer {
    audio_data_bytes_capacity: u32,
    audio_data: *mut c_void,
    audio_data_byte_size: u32,
    user_data: *mut c_void,
    packet_description_capacity: u32,
    packet_descriptions: *mut c_void,
    packet_description_count: u32,
}

type AudioQueueRef = *mut c_void;
type AudioQueueBufferRef = *mut AudioQueueBuffer;

// The input callback: (user_data, queue, buffer, start_time, num_packets,
// packet_descs). We ignore timing and packet descriptions for PCM.
type InputCallback = unsafe extern "C" fn(
    *mut c_void,
    AudioQueueRef,
    AudioQueueBufferRef,
    *const AudioTimeStamp,
    u32,
    *const c_void,
);

type FnNewInput = unsafe extern "C" fn(
    *const AudioStreamBasicDescription,
    Option<InputCallback>,
    *mut c_void,
    *mut c_void,
    *mut c_void,
    u32,
    *mut AudioQueueRef,
) -> c_int;
type FnAlloc = unsafe extern "C" fn(AudioQueueRef, u32, *mut AudioQueueBufferRef) -> c_int;
type FnEnqueue =
    unsafe extern "C" fn(AudioQueueRef, AudioQueueBufferRef, u32, *const c_void) -> c_int;
type FnStart = unsafe extern "C" fn(AudioQueueRef, *mut c_void) -> c_int;
type FnStop = unsafe extern "C" fn(AudioQueueRef, u8) -> c_int;
type FnDispose = unsafe extern "C" fn(AudioQueueRef, u8) -> c_int;
type FnFreeBuffer = unsafe extern "C" fn(AudioQueueRef, AudioQueueBufferRef) -> c_int;
// OSStatus AudioQueueSetProperty(AudioQueueRef, AudioQueuePropertyID,
//                                const void* inData, u32 inDataSize). Only used
// for macOS HAL device selection; iOS routes capture via AVAudioSession.
#[cfg(target_os = "macos")]
type FnSetProperty = unsafe extern "C" fn(AudioQueueRef, u32, *const c_void, u32) -> c_int;

pub struct CoreAudio {
    _lib: Library,
    new_input: FnNewInput,
    alloc: FnAlloc,
    enqueue: FnEnqueue,
    start: FnStart,
    stop: FnStop,
    dispose: FnDispose,
    free_buffer: FnFreeBuffer,
    #[cfg(target_os = "macos")]
    set_property: FnSetProperty,
}

unsafe impl Send for CoreAudio {}
unsafe impl Sync for CoreAudio {}

impl CoreAudio {
    pub fn load() -> Result<CoreAudio, String> {
        // macOS resolves the absolute framework path; iOS resolves the short
        // name from the dyld shared cache. Try both.
        let candidates = [
            "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
            "AudioToolbox.framework/AudioToolbox",
            "AudioToolbox",
        ];
        let mut last_err = String::new();
        let lib = candidates
            .iter()
            .find_map(|p| match unsafe { Library::new(p) } {
                Ok(l) => Some(l),
                Err(e) => {
                    last_err = format!("{p}: {e}");
                    None
                }
            })
            .ok_or_else(|| format!("failed to load AudioToolbox: {last_err}"))?;
        unsafe {
            macro_rules! sym {
                ($name:literal) => {
                    *lib.get($name).map_err(|e| {
                        format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                    })?
                };
            }
            Ok(CoreAudio {
                new_input: sym!(b"AudioQueueNewInput\0"),
                alloc: sym!(b"AudioQueueAllocateBuffer\0"),
                enqueue: sym!(b"AudioQueueEnqueueBuffer\0"),
                start: sym!(b"AudioQueueStart\0"),
                stop: sym!(b"AudioQueueStop\0"),
                dispose: sym!(b"AudioQueueDispose\0"),
                free_buffer: sym!(b"AudioQueueFreeBuffer\0"),
                #[cfg(target_os = "macos")]
                set_property: sym!(b"AudioQueueSetProperty\0"),
                _lib: lib,
            })
        }
    }
}

/// Passed as the AudioQueue user_data. Holds the captured-sample sink and the
/// re-enqueue entry point the callback needs to recycle each buffer.
struct Sink {
    samples: Mutex<Vec<i16>>,
    enqueue: FnEnqueue,
}

unsafe impl Send for Sink {}
unsafe impl Sync for Sink {}

pub struct CoreAudioCapture {
    ca: *const CoreAudio,
    queue: AudioQueueRef,
    sink: Arc<Sink>,
    buffers: Vec<AudioQueueBufferRef>,
    channels: u32,
}

// The queue and buffers are only touched from the owning capture thread and the
// AudioQueue's own callback thread, which CoreAudio serializes; the shared
// sample buffer is behind a Mutex.
unsafe impl Send for CoreAudioCapture {}
unsafe impl Sync for CoreAudioCapture {}

const RING_BUFFERS: u32 = 4;
const FRAMES_PER_BUFFER: u32 = 2048;

impl CoreAudioCapture {
    pub fn open(
        ca: &CoreAudio,
        channels: u32,
        rate: u32,
        device_id: Option<&str>,
    ) -> Result<Self, String> {
        let channels = channels.max(1);
        let bytes_per_frame = channels * 2;
        let asbd = AudioStreamBasicDescription {
            sample_rate: rate as f64,
            format_id: K_LINEAR_PCM,
            format_flags: K_PCM_FLAG_IS_SIGNED_INT | K_PCM_FLAG_IS_PACKED,
            bytes_per_packet: bytes_per_frame,
            frames_per_packet: 1,
            bytes_per_frame,
            channels_per_frame: channels,
            bits_per_channel: 16,
            reserved: 0,
        };
        let sink = Arc::new(Sink {
            samples: Mutex::new(Vec::new()),
            enqueue: ca.enqueue,
        });
        // The callback receives a raw pointer to the Sink; keep it alive via the
        // Arc stored on the capture struct.
        let user_data = Arc::as_ptr(&sink) as *mut c_void;
        unsafe {
            let mut queue: AudioQueueRef = std::ptr::null_mut();
            let rc = (ca.new_input)(
                &asbd,
                Some(input_cb),
                user_data,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                &mut queue,
            );
            if rc != 0 {
                return Err(format!("AudioQueueNewInput: {rc}"));
            }
            // Route the queue to a specific input device before starting. On
            // macOS this is the device UID; iOS has no HAL device routing
            // (capture follows AVAudioSession), so the selector is ignored.
            #[cfg(target_os = "macos")]
            if let Some(uid) = device_id {
                if let Err(e) = set_queue_device(ca, queue, uid) {
                    (ca.dispose)(queue, 1);
                    return Err(e);
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = device_id;
            }
            let buffer_bytes = FRAMES_PER_BUFFER * bytes_per_frame;
            let mut buffers = Vec::with_capacity(RING_BUFFERS as usize);
            for _ in 0..RING_BUFFERS {
                let mut buf: AudioQueueBufferRef = std::ptr::null_mut();
                let rc = (ca.alloc)(queue, buffer_bytes, &mut buf);
                if rc != 0 {
                    (ca.dispose)(queue, 1);
                    return Err(format!("AudioQueueAllocateBuffer: {rc}"));
                }
                (ca.enqueue)(queue, buf, 0, std::ptr::null());
                buffers.push(buf);
            }
            let rc = (ca.start)(queue, std::ptr::null_mut());
            if rc != 0 {
                (ca.dispose)(queue, 1);
                return Err(format!("AudioQueueStart: {rc}"));
            }
            Ok(CoreAudioCapture {
                ca: ca as *const CoreAudio,
                queue,
                sink,
                buffers,
                channels,
            })
        }
    }
}

/// Called by AudioQueue on its own thread when a buffer of input is ready.
unsafe extern "C" fn input_cb(
    user_data: *mut c_void,
    _queue: AudioQueueRef,
    buf: AudioQueueBufferRef,
    _start_time: *const AudioTimeStamp,
    _num_packets: u32,
    _packet_descs: *const c_void,
) {
    let sink = &*(user_data as *const Sink);
    let byte_size = (*buf).audio_data_byte_size as usize;
    let data = (*buf).audio_data as *const i16;
    let n = byte_size / 2;
    if n > 0 && !data.is_null() {
        let slice = std::slice::from_raw_parts(data, n);
        if let Ok(mut samples) = sink.samples.lock() {
            samples.extend_from_slice(slice);
        }
    }
    // Recycle the buffer so the device keeps capturing.
    (sink.enqueue)(_queue, buf, 0, std::ptr::null());
}

impl PcmSource for CoreAudioCapture {
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

impl Drop for CoreAudioCapture {
    fn drop(&mut self) {
        unsafe {
            let ca = &*self.ca;
            (ca.stop)(self.queue, 1);
            for buf in self.buffers.drain(..) {
                (ca.free_buffer)(self.queue, buf);
            }
            (ca.dispose)(self.queue, 1);
        }
        // Keep the Sink alive until after the queue is disposed so the callback
        // cannot deref a freed pointer mid-stop.
        let _ = &self.sink;
    }
}

// ---------------------------------------------------------------------------
// macOS HAL input-device enumeration + AudioQueue device selection.
//
// Same header-free, dlopen-only philosophy as the AudioQueue path above: the
// HAL property API lives in CoreAudio.framework and CFString handling lives in
// CoreFoundation.framework, both of which we load at runtime and declare the
// handful of C symbols we need. Gated to macOS because iOS has no HAL device
// graph (capture is routed by AVAudioSession).
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod macos {
    use std::os::raw::{c_char, c_int, c_void};

    use libloading::Library;

    use crate::DeviceInfo;

    use super::{AudioQueueRef, CoreAudio};

    // OSStatus noErr.
    const NO_ERR: c_int = 0;

    // HAL object / property constants.
    const K_AUDIO_OBJECT_SYSTEM_OBJECT: u32 = 1;
    const K_AUDIO_HARDWARE_PROPERTY_DEVICES: u32 = u32::from_be_bytes(*b"dev#");
    const K_AUDIO_HARDWARE_PROPERTY_DEFAULT_INPUT_DEVICE: u32 = u32::from_be_bytes(*b"dIn ");
    const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = u32::from_be_bytes(*b"glob");
    const K_AUDIO_OBJECT_PROPERTY_SCOPE_INPUT: u32 = u32::from_be_bytes(*b"inpt");
    const K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN: u32 = 0;
    const K_AUDIO_DEVICE_PROPERTY_DEVICE_UID: u32 = u32::from_be_bytes(*b"uid ");
    const K_AUDIO_OBJECT_PROPERTY_NAME: u32 = u32::from_be_bytes(*b"lnam");
    const K_AUDIO_DEVICE_PROPERTY_STREAM_CONFIGURATION: u32 = u32::from_be_bytes(*b"slay");

    // AudioQueue property selector for the current HAL device (a CFStringRef UID).
    const K_AUDIO_QUEUE_PROPERTY_CURRENT_DEVICE: u32 = u32::from_be_bytes(*b"aqcd");

    // CFStringEncoding for UTF-8.
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    type AudioObjectID = u32;
    type CFStringRef = *const c_void;
    type CFAllocatorRef = *const c_void;
    type CFTypeRef = *const c_void;
    type CFIndex = isize;

    #[repr(C)]
    struct AudioObjectPropertyAddress {
        selector: u32,
        scope: u32,
        element: u32,
    }

    #[repr(C)]
    struct AudioBuffer {
        number_channels: u32,
        data_byte_size: u32,
        data: *mut c_void,
    }

    // AudioBufferList is a u32 count followed by a variable-length AudioBuffer
    // array; we parse the raw bytes by hand rather than model the flexible tail.
    #[repr(C)]
    struct AudioBufferListHeader {
        number_buffers: u32,
        // followed by `number_buffers` AudioBuffer entries
        first: AudioBuffer,
    }

    type FnHasProperty =
        unsafe extern "C" fn(AudioObjectID, *const AudioObjectPropertyAddress) -> u8;
    type FnGetPropertyDataSize = unsafe extern "C" fn(
        AudioObjectID,
        *const AudioObjectPropertyAddress,
        u32,
        *const c_void,
        *mut u32,
    ) -> c_int;
    type FnGetPropertyData = unsafe extern "C" fn(
        AudioObjectID,
        *const AudioObjectPropertyAddress,
        u32,
        *const c_void,
        *mut u32,
        *mut c_void,
    ) -> c_int;

    struct Hal {
        _lib: Library,
        has_property: FnHasProperty,
        get_size: FnGetPropertyDataSize,
        get_data: FnGetPropertyData,
    }

    unsafe impl Send for Hal {}
    unsafe impl Sync for Hal {}

    impl Hal {
        fn load() -> Result<Hal, String> {
            let candidates = [
                "/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
                "CoreAudio.framework/CoreAudio",
                "CoreAudio",
            ];
            let mut last_err = String::new();
            let lib = candidates
                .iter()
                .find_map(|p| match unsafe { Library::new(p) } {
                    Ok(l) => Some(l),
                    Err(e) => {
                        last_err = format!("{p}: {e}");
                        None
                    }
                })
                .ok_or_else(|| format!("failed to load CoreAudio: {last_err}"))?;
            unsafe {
                macro_rules! sym {
                    ($name:literal) => {
                        *lib.get($name).map_err(|e| {
                            format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                        })?
                    };
                }
                Ok(Hal {
                    has_property: sym!(b"AudioObjectHasProperty\0"),
                    get_size: sym!(b"AudioObjectGetPropertyDataSize\0"),
                    get_data: sym!(b"AudioObjectGetPropertyData\0"),
                    _lib: lib,
                })
            }
        }
    }

    type FnCFStringCreateWithCString =
        unsafe extern "C" fn(CFAllocatorRef, *const c_char, u32) -> CFStringRef;
    type FnCFStringGetCStringPtr = unsafe extern "C" fn(CFStringRef, u32) -> *const c_char;
    type FnCFStringGetCString = unsafe extern "C" fn(CFStringRef, *mut c_char, CFIndex, u32) -> u8;
    type FnCFStringGetLength = unsafe extern "C" fn(CFStringRef) -> CFIndex;
    type FnCFStringGetMaximumSizeForEncoding = unsafe extern "C" fn(CFIndex, u32) -> CFIndex;
    type FnCFRelease = unsafe extern "C" fn(CFTypeRef);

    struct CoreFoundation {
        _lib: Library,
        create_with_cstring: FnCFStringCreateWithCString,
        get_cstring_ptr: FnCFStringGetCStringPtr,
        get_cstring: FnCFStringGetCString,
        get_length: FnCFStringGetLength,
        max_size_for_encoding: FnCFStringGetMaximumSizeForEncoding,
        release: FnCFRelease,
    }

    unsafe impl Send for CoreFoundation {}
    unsafe impl Sync for CoreFoundation {}

    impl CoreFoundation {
        fn load() -> Result<CoreFoundation, String> {
            let candidates = [
                "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                "CoreFoundation.framework/CoreFoundation",
                "CoreFoundation",
            ];
            let mut last_err = String::new();
            let lib = candidates
                .iter()
                .find_map(|p| match unsafe { Library::new(p) } {
                    Ok(l) => Some(l),
                    Err(e) => {
                        last_err = format!("{p}: {e}");
                        None
                    }
                })
                .ok_or_else(|| format!("failed to load CoreFoundation: {last_err}"))?;
            unsafe {
                macro_rules! sym {
                    ($name:literal) => {
                        *lib.get($name).map_err(|e| {
                            format!("missing symbol {}: {e}", String::from_utf8_lossy($name))
                        })?
                    };
                }
                Ok(CoreFoundation {
                    create_with_cstring: sym!(b"CFStringCreateWithCString\0"),
                    get_cstring_ptr: sym!(b"CFStringGetCStringPtr\0"),
                    get_cstring: sym!(b"CFStringGetCString\0"),
                    get_length: sym!(b"CFStringGetLength\0"),
                    max_size_for_encoding: sym!(b"CFStringGetMaximumSizeForEncoding\0"),
                    release: sym!(b"CFRelease\0"),
                    _lib: lib,
                })
            }
        }

        /// Copies a borrowed CFString into an owned Rust String. Tries the
        /// zero-copy pointer first, falling back to CFStringGetCString (the ptr
        /// form returns null whenever the backing store is not UTF-8).
        unsafe fn cfstring_to_string(&self, s: CFStringRef) -> Option<String> {
            if s.is_null() {
                return None;
            }
            let ptr = (self.get_cstring_ptr)(s, K_CF_STRING_ENCODING_UTF8);
            if !ptr.is_null() {
                let bytes = std::ffi::CStr::from_ptr(ptr).to_bytes();
                return Some(String::from_utf8_lossy(bytes).into_owned());
            }
            let len = (self.get_length)(s);
            let max = (self.max_size_for_encoding)(len, K_CF_STRING_ENCODING_UTF8);
            // +1 for the NUL terminator CFStringGetCString writes.
            let cap = (max.max(0) as usize) + 1;
            let mut buf = vec![0i8; cap];
            let ok = (self.get_cstring)(
                s,
                buf.as_mut_ptr(),
                cap as CFIndex,
                K_CF_STRING_ENCODING_UTF8,
            );
            if ok == 0 {
                return None;
            }
            let bytes = std::ffi::CStr::from_ptr(buf.as_ptr()).to_bytes();
            Some(String::from_utf8_lossy(bytes).into_owned())
        }

        /// Creates a CFString UID from a Rust &str. Caller owns the result and
        /// must CFRelease it.
        unsafe fn cfstring_from_str(&self, s: &str) -> Option<CFStringRef> {
            let c = std::ffi::CString::new(s).ok()?;
            let cf =
                (self.create_with_cstring)(std::ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8);
            if cf.is_null() {
                None
            } else {
                Some(cf)
            }
        }
    }

    /// Reads a CFString device property (UID or name) and returns it as a Rust
    /// String. The HAL hands us a +1-retained CFString we own and must release.
    unsafe fn copy_string_property(
        hal: &Hal,
        cf: &CoreFoundation,
        device: AudioObjectID,
        selector: u32,
    ) -> Option<String> {
        let addr = AudioObjectPropertyAddress {
            selector,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        if (hal.has_property)(device, &addr) == 0 {
            return None;
        }
        let mut value: CFStringRef = std::ptr::null();
        let mut size = std::mem::size_of::<CFStringRef>() as u32;
        let rc = (hal.get_data)(
            device,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut value as *mut CFStringRef as *mut c_void,
        );
        if rc != NO_ERR || value.is_null() {
            return None;
        }
        let out = cf.cfstring_to_string(value);
        (cf.release)(value);
        out
    }

    /// True if `device` exposes at least one input channel.
    unsafe fn is_input_device(hal: &Hal, device: AudioObjectID) -> bool {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_DEVICE_PROPERTY_STREAM_CONFIGURATION,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_INPUT,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        if (hal.has_property)(device, &addr) == 0 {
            return false;
        }
        let mut size: u32 = 0;
        let rc = (hal.get_size)(device, &addr, 0, std::ptr::null(), &mut size);
        if rc != NO_ERR || (size as usize) < std::mem::size_of::<u32>() {
            return false;
        }
        let mut buf = vec![0u8; size as usize];
        let rc = (hal.get_data)(
            device,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            buf.as_mut_ptr() as *mut c_void,
        );
        if rc != NO_ERR {
            return false;
        }
        // Walk the AudioBufferList and sum input channels across buffers.
        let header = &*(buf.as_ptr() as *const AudioBufferListHeader);
        let count = header.number_buffers as usize;
        if count == 0 {
            return false;
        }
        let buffers = std::slice::from_raw_parts(&header.first as *const AudioBuffer, count);
        let total: u32 = buffers.iter().map(|b| b.number_channels).sum();
        total > 0
    }

    /// Reads the system's default input device id, if any.
    unsafe fn default_input_device(hal: &Hal) -> Option<AudioObjectID> {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_PROPERTY_DEFAULT_INPUT_DEVICE,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        let mut id: AudioObjectID = 0;
        let mut size = std::mem::size_of::<AudioObjectID>() as u32;
        let rc = (hal.get_data)(
            K_AUDIO_OBJECT_SYSTEM_OBJECT,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut id as *mut AudioObjectID as *mut c_void,
        );
        if rc != NO_ERR || id == 0 {
            None
        } else {
            Some(id)
        }
    }

    /// Enumerates every input-capable HAL device. Returns an empty Vec on any
    /// failure (never panics, never sets a global error).
    pub fn enumerate_input_devices() -> Vec<DeviceInfo> {
        let hal = match Hal::load() {
            Ok(h) => h,
            Err(_) => return Vec::new(),
        };
        let cf = match CoreFoundation::load() {
            Ok(c) => c,
            Err(_) => return Vec::new(),
        };
        unsafe {
            let default_id = default_input_device(&hal);

            let addr = AudioObjectPropertyAddress {
                selector: K_AUDIO_HARDWARE_PROPERTY_DEVICES,
                scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
                element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
            };
            let mut size: u32 = 0;
            let rc = (hal.get_size)(
                K_AUDIO_OBJECT_SYSTEM_OBJECT,
                &addr,
                0,
                std::ptr::null(),
                &mut size,
            );
            if rc != NO_ERR || size == 0 {
                return Vec::new();
            }
            let count = size as usize / std::mem::size_of::<AudioObjectID>();
            let mut ids = vec![0u32; count];
            let rc = (hal.get_data)(
                K_AUDIO_OBJECT_SYSTEM_OBJECT,
                &addr,
                0,
                std::ptr::null(),
                &mut size,
                ids.as_mut_ptr() as *mut c_void,
            );
            if rc != NO_ERR {
                return Vec::new();
            }

            let mut out = Vec::new();
            for &device in &ids {
                if !is_input_device(&hal, device) {
                    continue;
                }
                let id = match copy_string_property(
                    &hal,
                    &cf,
                    device,
                    K_AUDIO_DEVICE_PROPERTY_DEVICE_UID,
                ) {
                    Some(s) => s,
                    None => continue,
                };
                let name = copy_string_property(&hal, &cf, device, K_AUDIO_OBJECT_PROPERTY_NAME)
                    .unwrap_or_else(|| id.clone());
                let is_default = default_id == Some(device);
                out.push(DeviceInfo {
                    id,
                    name,
                    is_default,
                });
            }
            out
        }
    }

    /// Routes an already-created input AudioQueue to the device with UID `uid`
    /// by setting kAudioQueueProperty_CurrentDevice to a CFString of the UID.
    pub fn set_queue_device(ca: &CoreAudio, queue: AudioQueueRef, uid: &str) -> Result<(), String> {
        let cf = CoreFoundation::load()?;
        unsafe {
            let cfuid = cf
                .cfstring_from_str(uid)
                .ok_or_else(|| format!("failed to create CFString for device UID {uid:?}"))?;
            let rc = (ca.set_property)(
                queue,
                K_AUDIO_QUEUE_PROPERTY_CURRENT_DEVICE,
                &cfuid as *const CFStringRef as *const c_void,
                std::mem::size_of::<CFStringRef>() as u32,
            );
            (cf.release)(cfuid);
            if rc != NO_ERR {
                return Err(format!(
                    "AudioQueueSetProperty(CurrentDevice={uid:?}): {rc}"
                ));
            }
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
use macos::set_queue_device;

/// Lists input-capable audio devices on macOS. Returns an empty Vec on any
/// error and on non-macOS platforms (capture falls back to the default device).
#[cfg(target_os = "macos")]
pub fn enumerate_input_devices() -> Vec<crate::DeviceInfo> {
    macos::enumerate_input_devices()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_audiotoolbox() {
        CoreAudio::load().expect("AudioToolbox loads on this host");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn enumerates_input_devices() {
        let devices = enumerate_input_devices();
        for d in &devices {
            println!(
                "input device: name={:?} uid={:?} default={}",
                d.name, d.id, d.is_default
            );
        }
        assert!(
            !devices.is_empty(),
            "expected at least one input device on this Mac"
        );
        let defaults = devices.iter().filter(|d| d.is_default).count();
        assert!(
            defaults <= 1,
            "at most one device may be marked default, found {defaults}"
        );
        // A Mac with a mic should expose a default input.
        assert_eq!(
            defaults, 1,
            "expected exactly one default input device, found {defaults}"
        );
    }
}

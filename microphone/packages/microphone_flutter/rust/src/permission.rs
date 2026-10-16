//! Microphone permission on Apple platforms, through AVFoundation driven by the
//! Objective-C runtime (the same header-free approach as `ios_session`).
//!
//! iOS asks through AVAudioSession and macOS through AVCaptureDevice; both
//! report the TCC "Microphone" grant that gates AudioQueue input. Asking is
//! asynchronous: [`request`] puts up the system prompt and returns at once,
//! and callers poll [`status`] until the user answers, so no thread (least of
//! all the UI thread the prompt needs) blocks while it is showing.

use std::ffi::c_void;
use std::os::raw::{c_char, c_int, c_ulong};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

use libloading::Library;

use crate::{
    PERMISSION_DENIED, PERMISSION_GRANTED, PERMISSION_NOT_APPLICABLE, PERMISSION_UNDETERMINED,
};

type Id = *mut c_void;
type Sel = *const c_void;
type Class = *mut c_void;

/// The Objective-C runtime entry points and the framework that defines the
/// permission APIs, loaded once.
struct Runtime {
    _objc: Library,
    _framework: Option<Library>,
    get_class: unsafe extern "C" fn(*const c_char) -> Class,
    sel: unsafe extern "C" fn(*const c_char) -> Sel,
    object_get_class: unsafe extern "C" fn(Id) -> Class,
    responds_to: unsafe extern "C" fn(Class, Sel) -> u8,
    msg_send: *const c_void,
    // AVMediaTypeAudio, the media type AVCaptureDevice's permission calls take.
    #[cfg(target_os = "macos")]
    media_type_audio: Id,
}

// The runtime functions are thread-safe and the NSString constant is immortal.
unsafe impl Send for Runtime {}
unsafe impl Sync for Runtime {}

fn runtime() -> Option<&'static Runtime> {
    static RUNTIME: OnceLock<Option<Runtime>> = OnceLock::new();
    RUNTIME.get_or_init(|| unsafe { Runtime::load() }).as_ref()
}

impl Runtime {
    unsafe fn load() -> Option<Runtime> {
        let objc = Library::new("/usr/lib/libobjc.A.dylib").ok()?;
        let get_class: unsafe extern "C" fn(*const c_char) -> Class =
            *objc.get(b"objc_getClass\0").ok()?;
        #[cfg(target_os = "ios")]
        let framework = if get_class(c"AVAudioSession".as_ptr()).is_null() {
            // AVAudioSession lives in AVFAudio from iOS 14.5, AVFoundation before.
            let lib = Library::new("/System/Library/Frameworks/AVFAudio.framework/AVFAudio")
                .or_else(|_| {
                    Library::new("/System/Library/Frameworks/AVFoundation.framework/AVFoundation")
                })
                .ok()?;
            Some(lib)
        } else {
            None
        };
        #[cfg(target_os = "macos")]
        let framework = Some(
            Library::new("/System/Library/Frameworks/AVFoundation.framework/AVFoundation").ok()?,
        );
        let sel: unsafe extern "C" fn(*const c_char) -> Sel =
            *objc.get(b"sel_registerName\0").ok()?;
        let msg_send: *const c_void = *objc.get::<*const c_void>(b"objc_msgSend\0").ok()?;
        #[cfg(target_os = "macos")]
        let media_type_audio = {
            let exported = framework
                .as_ref()?
                .get::<*const Id>(b"AVMediaTypeAudio\0")
                .ok()
                .map(|symbol| **symbol)
                .filter(|value| !value.is_null());
            // The constant's value is "soun"; build it if the symbol is missing.
            match exported {
                Some(value) => value,
                None => ns_string_retained(get_class, sel, msg_send, c"soun")?,
            }
        };
        Some(Runtime {
            get_class,
            sel,
            object_get_class: *objc.get(b"object_getClass\0").ok()?,
            responds_to: *objc.get(b"class_respondsToSelector\0").ok()?,
            msg_send,
            #[cfg(target_os = "macos")]
            media_type_audio,
            _framework: framework,
            _objc: objc,
        })
    }

    /// `sel` if `receiver` (an instance, or a class for class methods)
    /// implements it. Sending an unimplemented selector raises an Objective-C
    /// exception, which would abort the process from here.
    unsafe fn implemented(&self, receiver: Id, name: &std::ffi::CStr) -> Option<Sel> {
        let sel = (self.sel)(name.as_ptr());
        let class = (self.object_get_class)(receiver);
        (!class.is_null() && (self.responds_to)(class, sel) != 0).then_some(sel)
    }

    /// `[AVAudioSession sharedInstance]`.
    #[cfg(target_os = "ios")]
    unsafe fn audio_session(&self) -> Option<Id> {
        let class = (self.get_class)(c"AVAudioSession".as_ptr());
        if class.is_null() {
            return None;
        }
        let shared = self.implemented(class, c"sharedInstance")?;
        let send: unsafe extern "C" fn(Id, Sel) -> Id = std::mem::transmute(self.msg_send);
        let session = send(class, shared);
        (!session.is_null()).then_some(session)
    }

    /// The AVCaptureDevice class.
    #[cfg(target_os = "macos")]
    unsafe fn capture_device(&self) -> Option<Id> {
        let class = (self.get_class)(c"AVCaptureDevice".as_ptr());
        (!class.is_null()).then_some(class)
    }
}

/// `[[NSString stringWithUTF8String:text] retain]`, kept for the process's
/// lifetime.
#[cfg(target_os = "macos")]
unsafe fn ns_string_retained(
    get_class: unsafe extern "C" fn(*const c_char) -> Class,
    sel: unsafe extern "C" fn(*const c_char) -> Sel,
    msg_send: *const c_void,
    text: &std::ffi::CStr,
) -> Option<Id> {
    let class = get_class(c"NSString".as_ptr());
    if class.is_null() {
        return None;
    }
    let with_utf8: unsafe extern "C" fn(Id, Sel, *const c_char) -> Id =
        std::mem::transmute(msg_send);
    let string = with_utf8(class, sel(c"stringWithUTF8String:".as_ptr()), text.as_ptr());
    if string.is_null() {
        return None;
    }
    let retain: unsafe extern "C" fn(Id, Sel) -> Id = std::mem::transmute(msg_send);
    Some(retain(string, sel(c"retain".as_ptr())))
}

/// The permission state TCC reports, as one of the `PERMISSION_*` codes.
fn raw_status() -> c_int {
    match runtime() {
        Some(rt) => unsafe { status_with(rt) }.unwrap_or(PERMISSION_NOT_APPLICABLE),
        None => PERMISSION_NOT_APPLICABLE,
    }
}

/// The current permission state, as one of the `PERMISSION_*` codes.
pub fn status() -> c_int {
    let state = raw_status();
    if state != PERMISSION_UNDETERMINED {
        // TCC has a decision; an earlier request's answer no longer applies.
        ANSWER.store(ANSWER_PENDING, Ordering::SeqCst);
        return state;
    }
    // The system can answer a request without recording a decision (e.g. a
    // sandboxed app lacking the audio-input entitlement, or a process with no
    // app to attribute the prompt to), leaving the status undetermined for
    // good. Take the answer the request's completion handler was given, so a
    // caller polling for the decision is not left waiting forever.
    match ANSWER.load(Ordering::SeqCst) {
        ANSWER_GRANTED => PERMISSION_GRANTED,
        ANSWER_REFUSED => PERMISSION_DENIED,
        _ => PERMISSION_UNDETERMINED,
    }
}

#[cfg(target_os = "ios")]
unsafe fn status_with(rt: &Runtime) -> Option<c_int> {
    // AVAudioSessionRecordPermission: four-character codes.
    const UNDETERMINED: c_ulong = 0x756e_6474; // 'undt'
    const DENIED: c_ulong = 0x6465_6e79; // 'deny'
    const GRANTED: c_ulong = 0x6772_6e74; // 'grnt'
    let session = rt.audio_session()?;
    let sel = rt.implemented(session, c"recordPermission")?;
    let send: unsafe extern "C" fn(Id, Sel) -> c_ulong = std::mem::transmute(rt.msg_send);
    Some(match send(session, sel) {
        UNDETERMINED => PERMISSION_UNDETERMINED,
        DENIED => PERMISSION_DENIED,
        GRANTED => PERMISSION_GRANTED,
        _ => PERMISSION_NOT_APPLICABLE,
    })
}

#[cfg(target_os = "macos")]
unsafe fn status_with(rt: &Runtime) -> Option<c_int> {
    // AVAuthorizationStatus: NotDetermined, Restricted, Denied, Authorized.
    let class = rt.capture_device()?;
    let sel = rt.implemented(class, c"authorizationStatusForMediaType:")?;
    let send: unsafe extern "C" fn(Id, Sel, Id) -> std::os::raw::c_long =
        std::mem::transmute(rt.msg_send);
    Some(match send(class, sel, rt.media_type_audio) {
        0 => PERMISSION_UNDETERMINED,
        1 | 2 => PERMISSION_DENIED,
        3 => PERMISSION_GRANTED,
        _ => PERMISSION_NOT_APPLICABLE,
    })
}

/// Puts up the system permission prompt if the state is undetermined, and
/// returns the state as it is now (still undetermined while the prompt is
/// showing).
pub fn request() -> c_int {
    // Decide from TCC alone: a recorded answer must not stop a fresh request
    // (e.g. after `tccutil reset` while the process runs) from asking again.
    let state = raw_status();
    if state != PERMISSION_UNDETERMINED {
        ANSWER.store(ANSWER_PENDING, Ordering::SeqCst);
        return state;
    }
    let Some(rt) = runtime() else {
        return PERMISSION_NOT_APPLICABLE;
    };
    ANSWER.store(ANSWER_PENDING, Ordering::SeqCst);
    match unsafe { request_with(rt) } {
        Some(()) => PERMISSION_UNDETERMINED,
        None => PERMISSION_NOT_APPLICABLE,
    }
}

#[cfg(target_os = "ios")]
unsafe fn request_with(rt: &Runtime) -> Option<()> {
    let session = rt.audio_session()?;
    let sel = rt.implemented(session, c"requestRecordPermission:")?;
    let send: unsafe extern "C" fn(Id, Sel, *const Block) = std::mem::transmute(rt.msg_send);
    send(session, sel, &RECORD_ANSWER.0);
    Some(())
}

#[cfg(target_os = "macos")]
unsafe fn request_with(rt: &Runtime) -> Option<()> {
    let class = rt.capture_device()?;
    let sel = rt.implemented(class, c"requestAccessForMediaType:completionHandler:")?;
    let send: unsafe extern "C" fn(Id, Sel, Id, *const Block) = std::mem::transmute(rt.msg_send);
    send(class, sel, rt.media_type_audio, &RECORD_ANSWER.0);
    Some(())
}

// The answer the last request's completion handler was given.
const ANSWER_PENDING: u8 = 0;
const ANSWER_GRANTED: u8 = 1;
const ANSWER_REFUSED: u8 = 2;
static ANSWER: AtomicU8 = AtomicU8::new(ANSWER_PENDING);

// The completion handler both request APIs require (they call it
// unconditionally, so it cannot be nil). It is a global block -- no captures,
// so it needs no copying or freeing -- laid out per the Blocks ABI, with the
// type signature clang would emit for `^(BOOL granted)`.

#[repr(C)]
struct Opaque {
    _private: [u8; 0],
}

extern "C" {
    // The isa of every global block, from libSystem.
    static _NSConcreteGlobalBlock: Opaque;
}

// Without copy/dispose helpers, the signature directly follows the size.
#[repr(C)]
struct BlockDescriptor {
    reserved: c_ulong,
    size: c_ulong,
    signature: *const c_char,
}

#[repr(C)]
struct Block {
    isa: *const Opaque,
    flags: c_int,
    reserved: c_int,
    invoke: unsafe extern "C" fn(*const Block, u8),
    descriptor: *const BlockDescriptor,
}

struct SyncBlock(Block);
unsafe impl Sync for SyncBlock {}
struct SyncDescriptor(BlockDescriptor);
unsafe impl Sync for SyncDescriptor {}

const BLOCK_IS_GLOBAL: c_int = 1 << 28;
const BLOCK_HAS_SIGNATURE: c_int = 1 << 30;

// `void (^)(BOOL)`. BOOL is `signed char` (c) only on Intel macOS; it is `bool`
// (B) on Apple-silicon macOS and on every 64-bit iOS target, simulators
// included.
#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
const SIGNATURE: &std::ffi::CStr = c"v12@?0c8";
#[cfg(not(all(target_os = "macos", target_arch = "x86_64")))]
const SIGNATURE: &std::ffi::CStr = c"v12@?0B8";

static RECORD_ANSWER_DESCRIPTOR: SyncDescriptor = SyncDescriptor(BlockDescriptor {
    reserved: 0,
    size: std::mem::size_of::<Block>() as c_ulong,
    signature: SIGNATURE.as_ptr(),
});

// Taking an extern static's address needed `unsafe` before Rust 1.82.
#[allow(unused_unsafe)]
static RECORD_ANSWER: SyncBlock = SyncBlock(Block {
    isa: unsafe { std::ptr::addr_of!(_NSConcreteGlobalBlock) },
    flags: BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE,
    reserved: 0,
    invoke: record_answer,
    descriptor: &RECORD_ANSWER_DESCRIPTOR.0,
});

/// `^(BOOL granted) { ANSWER = granted ? GRANTED : REFUSED; }`
unsafe extern "C" fn record_answer(_block: *const Block, granted: u8) {
    let answer = if granted != 0 {
        ANSWER_GRANTED
    } else {
        ANSWER_REFUSED
    };
    ANSWER.store(answer, Ordering::SeqCst);
}

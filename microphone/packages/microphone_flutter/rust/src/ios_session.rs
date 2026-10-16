//! iOS-only: activate an AVAudioSession so AudioQueue input can start.
//!
//! Unlike macOS, iOS gates audio input behind an active AVAudioSession with a
//! record-capable category; without it AudioQueueStart fails with
//! kAudioQueueErr_CannotStart (-66628). AVAudioSession is Objective-C, so rather
//! than link the framework we drive it through the Objective-C runtime
//! (objc_msgSend) -- the same header-free, no-build-dep spirit as the rest of
//! the crate. AVFAudio is loaded so its classes are registered with the runtime.

use std::ffi::c_void;
use std::os::raw::c_char;

use libloading::Library;

type Id = *mut c_void;
type Sel = *const c_void;
type Class = *mut c_void;

// Objective-C runtime entry points.
type FnGetClass = unsafe extern "C" fn(*const c_char) -> Class;
type FnRegisterName = unsafe extern "C" fn(*const c_char) -> Sel;

// objc_msgSend has no fixed signature; we transmute it per call shape.
type MsgSend0 = unsafe extern "C" fn(Id, Sel) -> Id;
type MsgSendCat = unsafe extern "C" fn(Id, Sel, Id, u64, *mut Id) -> u8;
type MsgSendPlainCat = unsafe extern "C" fn(Id, Sel, Id, *mut Id) -> u8;
type MsgSendActive = unsafe extern "C" fn(Id, Sel, u8, *mut Id) -> u8;
type MsgSendCode = unsafe extern "C" fn(Id, Sel) -> isize;

// AVAudioSessionCategoryOptions. PlayAndRecord alone routes playback to the
// earpiece receiver and will not play to Bluetooth headphones; these send it to
// the speaker or A2DP headphones instead. Neither changes which microphone
// records (AllowBluetooth, which would switch to a headset's HFP microphone at
// phone-call quality, is deliberately not set).
const DEFAULT_TO_SPEAKER: u64 = 0x8;
const ALLOW_BLUETOOTH_A2DP: u64 = 0x20;

/// Activates a record-capable AVAudioSession, which AudioQueue input needs on
/// iOS. Capture cannot start if this fails, so the error is returned.
pub fn activate() -> Result<(), String> {
    unsafe {
        // libobjc is always present on iOS; AVFAudio registers AVAudioSession.
        let objc = Library::new("/usr/lib/libobjc.A.dylib")
            .or_else(|_| Library::new("libobjc.A.dylib"))
            .map_err(|e| format!("load libobjc: {e}"))?;
        // Loading the framework registers its classes with the runtime.
        // AVAudioSession moved into AVFAudio in iOS 14.5; before that it is in
        // AVFoundation (the podspec allows iOS 13).
        let _avf = Library::new("/System/Library/Frameworks/AVFAudio.framework/AVFAudio")
            .or_else(|_| Library::new("AVFAudio.framework/AVFAudio"))
            .or_else(|_| Library::new("AVFAudio"))
            .or_else(|_| {
                Library::new("/System/Library/Frameworks/AVFoundation.framework/AVFoundation")
            })
            .map_err(|e| format!("load AVFAudio: {e}"))?;

        let get_class: FnGetClass = *objc
            .get(b"objc_getClass\0")
            .map_err(|e| format!("objc_getClass: {e}"))?;
        let sel: FnRegisterName = *objc
            .get(b"sel_registerName\0")
            .map_err(|e| format!("sel_registerName: {e}"))?;
        let msg_send: *const c_void = *objc
            .get::<*const c_void>(b"objc_msgSend\0")
            .map_err(|e| format!("objc_msgSend: {e}"))?;

        let cls = get_class(c"AVAudioSession".as_ptr());
        if cls.is_null() {
            return Err("AVAudioSession class not found".into());
        }

        // session = [AVAudioSession sharedInstance]
        let shared_instance = sel(c"sharedInstance".as_ptr());
        let send0: MsgSend0 = std::mem::transmute(msg_send);
        let session = send0(cls as Id, shared_instance);
        if session.is_null() {
            return Err("AVAudioSession sharedInstance returned nil".into());
        }

        // [session setCategory:@"AVAudioSessionCategoryPlayAndRecord"
        //              withOptions:... error:&error]
        // The category constant is an NSString; its underlying C string value is
        // "AVAudioSessionCategoryPlayAndRecord". Build an NSString from it.
        let category = ns_string(&objc, msg_send, "AVAudioSessionCategoryPlayAndRecord")?;
        let set_category = sel(c"setCategory:withOptions:error:".as_ptr());
        let send_cat: MsgSendCat = std::mem::transmute(msg_send);
        let mut error: Id = std::ptr::null_mut();
        let options = DEFAULT_TO_SPEAKER | ALLOW_BLUETOOTH_A2DP;
        if send_cat(session, set_category, category, options, &mut error) == 0 {
            // The options are a routing preference, not a requirement: fall
            // back to the plain category (which is all this used to set, and
            // whose failure was never fatal) and let setActive decide.
            let set_plain = sel(c"setCategory:error:".as_ptr());
            let send_plain: MsgSendPlainCat = std::mem::transmute(msg_send);
            send_plain(session, set_plain, category, std::ptr::null_mut());
            error = std::ptr::null_mut();
        }

        // [session setActive:YES error:&error]
        let set_active = sel(c"setActive:error:".as_ptr());
        let send_active: MsgSendActive = std::mem::transmute(msg_send);
        if send_active(session, set_active, 1, &mut error) == 0 {
            let code = describe_code(error_code(sel, msg_send, error));
            return Err(format!("AVAudioSession setActive failed (error {code})"));
        }
        Ok(())
    }
}

/// `[error code]`, or 0 when no NSError was returned.
unsafe fn error_code(sel: FnRegisterName, msg_send: *const c_void, error: Id) -> isize {
    if error.is_null() {
        return 0;
    }
    let send: MsgSendCode = std::mem::transmute(msg_send);
    send(error, sel(c"code".as_ptr()))
}

/// An error code, with its four-character form when it has one (AVAudioSession
/// errors are four-character codes such as '!pri').
fn describe_code(code: isize) -> String {
    let bytes = (code as u32).to_be_bytes();
    if code > 0 && code <= u32::MAX as isize && bytes.iter().all(|b| b.is_ascii_graphic()) {
        format!("'{}' ({code})", String::from_utf8_lossy(&bytes))
    } else {
        code.to_string()
    }
}

/// Builds an NSString from a Rust &str via the runtime.
unsafe fn ns_string(objc: &Library, msg_send: *const c_void, s: &str) -> Result<Id, String> {
    let get_class: FnGetClass = *objc
        .get(b"objc_getClass\0")
        .map_err(|e| format!("objc_getClass: {e}"))?;
    let sel: FnRegisterName = *objc
        .get(b"sel_registerName\0")
        .map_err(|e| format!("sel_registerName: {e}"))?;
    let cls = get_class(c"NSString".as_ptr());
    if cls.is_null() {
        return Err("NSString class not found".into());
    }
    // [NSString stringWithUTF8String:cstr]
    type MsgSendStr = unsafe extern "C" fn(Id, Sel, *const c_char) -> Id;
    let with_utf8 = sel(c"stringWithUTF8String:".as_ptr());
    let send: MsgSendStr = std::mem::transmute(msg_send);
    let cstr = std::ffi::CString::new(s).map_err(|e| e.to_string())?;
    Ok(send(cls as Id, with_utf8, cstr.as_ptr()))
}

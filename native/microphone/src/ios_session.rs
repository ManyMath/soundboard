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
type MsgSendCat = unsafe extern "C" fn(Id, Sel, Id, u64) -> u8;
type MsgSendActive = unsafe extern "C" fn(Id, Sel, u8, Id) -> u8;

/// Activates a record-capable AVAudioSession. Returns Ok on success; on failure
/// returns a message but the caller may still try to start capture.
pub fn activate() -> Result<(), String> {
    unsafe {
        // libobjc is always present on iOS; AVFAudio registers AVAudioSession.
        let objc = Library::new("/usr/lib/libobjc.A.dylib")
            .or_else(|_| Library::new("libobjc.A.dylib"))
            .map_err(|e| format!("load libobjc: {e}"))?;
        // Loading the framework registers its classes with the runtime.
        let _avf = Library::new("/System/Library/Frameworks/AVFAudio.framework/AVFAudio")
            .or_else(|_| Library::new("AVFAudio.framework/AVFAudio"))
            .or_else(|_| Library::new("AVFAudio"))
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

        // [session setCategory:@"AVAudioSessionCategoryPlayAndRecord" error:nil]
        // The category constant is an NSString; its underlying C string value is
        // "AVAudioSessionCategoryPlayAndRecord". Build an NSString from it.
        let category = ns_string(&objc, msg_send, "AVAudioSessionCategoryPlayAndRecord")?;
        let set_category = sel(c"setCategory:error:".as_ptr());
        let send_cat: MsgSendCat = std::mem::transmute(msg_send);
        send_cat(session, set_category, category, 0);

        // [session setActive:YES error:nil]
        let set_active = sel(c"setActive:error:".as_ptr());
        let send_active: MsgSendActive = std::mem::transmute(msg_send);
        let ok = send_active(session, set_active, 1, std::ptr::null_mut());
        if ok == 0 {
            return Err("AVAudioSession setActive failed".into());
        }
        Ok(())
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

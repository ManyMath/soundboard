//! Full names for `waveIn` devices.
//!
//! `WAVEINCAPSW` truncates device names to 31 characters ("Microphone (2- USB
//! PnP Sound De"). Each waveIn device maps to an audio endpoint, whose ID the
//! driver reports for DRV_QUERYFUNCTIONINSTANCEID; the endpoint's friendly name
//! in the MMDevice API is the full one. COM is driven through raw vtables,
//! loaded at runtime like the rest of the crate.

use std::ffi::c_void;

use libloading::Library;

use crate::winmm::{HWaveIn, Winmm, MMSYSERR_NOERROR};

// waveInMessage: the device's endpoint ID string and its size in bytes.
const DRV_QUERYFUNCTIONINSTANCEID: u32 = 0x0800 + 17;
const DRV_QUERYFUNCTIONINSTANCEIDSIZE: u32 = 0x0800 + 18;

const COINIT_MULTITHREADED: u32 = 0x0;
const CLSCTX_ALL: u32 = 0x17;
const STGM_READ: u32 = 0;
const VT_LPWSTR: u16 = 31;

#[repr(C)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

#[repr(C)]
struct PropertyKey {
    fmtid: Guid,
    pid: u32,
}

const CLSID_MM_DEVICE_ENUMERATOR: Guid = Guid {
    data1: 0xBCDE_0395,
    data2: 0xE52F,
    data3: 0x467C,
    data4: [0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E],
};
const IID_IMM_DEVICE_ENUMERATOR: Guid = Guid {
    data1: 0xA956_64D2,
    data2: 0x9614,
    data3: 0x4F35,
    data4: [0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6],
};
const PKEY_DEVICE_FRIENDLY_NAME: PropertyKey = PropertyKey {
    fmtid: Guid {
        data1: 0xA45C_254E,
        data2: 0xDF1C,
        data3: 0x4EFD,
        data4: [0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0],
    },
    pid: 14,
};

// Vtable slots, after IUnknown's QueryInterface (0), AddRef (1), Release (2).
const RELEASE: usize = 2;
const ENUMERATOR_GET_DEVICE: usize = 5;
const DEVICE_OPEN_PROPERTY_STORE: usize = 4;
const PROPERTY_STORE_GET_VALUE: usize = 5;

type FnCoInitializeEx = unsafe extern "system" fn(*mut c_void, u32) -> i32;
type FnCoUninitialize = unsafe extern "system" fn();
type FnCoCreateInstance =
    unsafe extern "system" fn(*const Guid, *mut c_void, u32, *const Guid, *mut *mut c_void) -> i32;
type FnPropVariantClear = unsafe extern "system" fn(*mut PropVariant) -> i32;
type FnRelease = unsafe extern "system" fn(*mut c_void) -> u32;
type FnGetDevice = unsafe extern "system" fn(*mut c_void, *const u16, *mut *mut c_void) -> i32;
type FnOpenPropertyStore = unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void) -> i32;
type FnGetValue =
    unsafe extern "system" fn(*mut c_void, *const PropertyKey, *mut PropVariant) -> i32;

/// PROPVARIANT: a VARTYPE, three reserved WORDs, then a pointer-sized union
/// (24 bytes on 64-bit, 16 on 32-bit; the largest member is two words).
#[repr(C)]
struct PropVariant {
    vt: u16,
    reserved: [u16; 3],
    value: *mut u16,
    _rest: usize,
}

/// The full endpoint name for each waveIn device index in `0..count`, or None
/// where it cannot be read (the caller keeps the truncated name).
pub fn full_names(winmm: &Winmm, count: u32) -> Vec<Option<String>> {
    let ids: Vec<Option<Vec<u16>>> = (0..count)
        .map(|i| unsafe { endpoint_id(winmm, i) })
        .collect();
    // COM on a thread of our own, so its apartment cannot clash with the
    // caller's (a Flutter runner's UI thread is single-threaded).
    std::thread::spawn(move || unsafe { friendly_names(&ids) })
        .join()
        .unwrap_or_else(|_| vec![None; count as usize])
}

/// The NUL-terminated endpoint ID string of waveIn device `index`.
unsafe fn endpoint_id(winmm: &Winmm, index: u32) -> Option<Vec<u16>> {
    // A device index cast to HWAVEIN addresses the device itself.
    let device = index as usize as HWaveIn;
    let mut size: u32 = 0;
    let rc = winmm.message(
        device,
        DRV_QUERYFUNCTIONINSTANCEIDSIZE,
        &mut size as *mut u32 as usize,
        0,
    );
    if rc != MMSYSERR_NOERROR || size < 4 {
        return None;
    }
    let mut id = vec![0u16; (size as usize).div_ceil(2)];
    let rc = winmm.message(
        device,
        DRV_QUERYFUNCTIONINSTANCEID,
        id.as_mut_ptr() as usize,
        size as usize,
    );
    if rc != MMSYSERR_NOERROR {
        return None;
    }
    // Make sure it is terminated however the driver filled it.
    *id.last_mut()? = 0;
    Some(id)
}

unsafe fn friendly_names(ids: &[Option<Vec<u16>>]) -> Vec<Option<String>> {
    let none = || vec![None; ids.len()];
    let Ok(ole32) = Library::new("ole32.dll") else {
        return none();
    };
    let (Ok(init), Ok(uninit), Ok(create), Ok(clear)) = (
        ole32.get::<FnCoInitializeEx>(b"CoInitializeEx\0"),
        ole32.get::<FnCoUninitialize>(b"CoUninitialize\0"),
        ole32.get::<FnCoCreateInstance>(b"CoCreateInstance\0"),
        ole32.get::<FnPropVariantClear>(b"PropVariantClear\0"),
    ) else {
        return none();
    };
    if init(std::ptr::null_mut(), COINIT_MULTITHREADED) < 0 {
        return none();
    }
    let mut enumerator: *mut c_void = std::ptr::null_mut();
    let names = if create(
        &CLSID_MM_DEVICE_ENUMERATOR,
        std::ptr::null_mut(),
        CLSCTX_ALL,
        &IID_IMM_DEVICE_ENUMERATOR,
        &mut enumerator,
    ) < 0
        || enumerator.is_null()
    {
        none()
    } else {
        let names = ids
            .iter()
            .map(|id| {
                id.as_ref()
                    .and_then(|id| friendly_name(enumerator, id, *clear))
            })
            .collect();
        release(enumerator);
        names
    };
    uninit();
    names
}

/// Looks up the endpoint `id` and reads its PKEY_Device_FriendlyName.
unsafe fn friendly_name(
    enumerator: *mut c_void,
    id: &[u16],
    clear: FnPropVariantClear,
) -> Option<String> {
    let get_device: FnGetDevice = method(enumerator, ENUMERATOR_GET_DEVICE);
    let mut device: *mut c_void = std::ptr::null_mut();
    if get_device(enumerator, id.as_ptr(), &mut device) < 0 || device.is_null() {
        return None;
    }
    let open_store: FnOpenPropertyStore = method(device, DEVICE_OPEN_PROPERTY_STORE);
    let mut store: *mut c_void = std::ptr::null_mut();
    let opened = open_store(device, STGM_READ, &mut store) >= 0 && !store.is_null();
    release(device);
    if !opened {
        return None;
    }
    let get_value: FnGetValue = method(store, PROPERTY_STORE_GET_VALUE);
    let mut value: PropVariant = std::mem::zeroed();
    let mut name = None;
    if get_value(store, &PKEY_DEVICE_FRIENDLY_NAME, &mut value) >= 0
        && value.vt == VT_LPWSTR
        && !value.value.is_null()
    {
        let mut len = 0;
        while *value.value.add(len) != 0 {
            len += 1;
        }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(value.value, len));
        if !text.is_empty() {
            name = Some(text);
        }
    }
    clear(&mut value);
    release(store);
    name
}

/// The function in slot `index` of a COM object's vtable.
unsafe fn method<F: Copy>(object: *mut c_void, index: usize) -> F {
    let vtable = *(object as *const *const usize);
    std::mem::transmute_copy(&*vtable.add(index))
}

unsafe fn release(object: *mut c_void) {
    let release: FnRelease = method(object, RELEASE);
    release(object);
}

#[cfg(test)]
mod tests {
    use super::full_names;
    use crate::winmm::Winmm;

    #[test]
    fn names_every_device_slot_without_panicking() {
        let winmm = Winmm::load().unwrap();
        let count = unsafe { winmm.device_count() };
        let names = full_names(&winmm, count);
        assert_eq!(names.len(), count as usize);
        assert!(names.iter().flatten().all(|n| !n.is_empty()));
    }
}

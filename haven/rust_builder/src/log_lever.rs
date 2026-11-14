//! The log lever (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §M.2, §N.1). Android's
//! Bluetooth classes log, from the app's own process, the address of whatever
//! connects; from Android 11 a process decides what its log calls write. This
//! module puts a logger of Haven's own into the process's `liblog`: a release
//! build then writes no line, with the minimum priority at FATAL behind the
//! logger; a debug build writes the lines under Haven's own tags and no
//! other. Nothing calls it yet: the radio is to, before its first Bluetooth
//! object.
//!
//! This file is exempt from the crate's `unsafe_code` deny, so the compiler
//! reports no `unsafe` in it. What is `unsafe` here is the lookup of five
//! functions, the calls through what it found, and the read of a message's
//! size and tag; what a tag, the build's kind and a check's readings come to
//! is decided by `api.rs`'s `lever_*`, under the deny.
//! `scripts/ci/check_mesh_radio.sh` (check 13) reads this file's text.
//!
//! The five are "available since API level 30" and are found by name at run
//! time: declared `extern`, they would be imports no Android before 11 can
//! bind, and the library would not load there.
//!
//! [`logger`] runs inside `liblog`, on whichever thread logs. It and what it
//! calls log nothing, format nothing, allocate nothing, take no lock, index
//! nothing and add nothing but the wrapping count: there is no panic in it to
//! unwind, and one would abort the process at the `extern "C"` boundary.
//!
//! Built for Android, and into a Unix host's test build, where no lookup of
//! `liblog` is made.

use std::ffi::{c_char, c_void, CStr};
use std::mem::{offset_of, transmute};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::OnceLock;

use crate::api::{lever_held, lever_line, lever_writes_own, LEVER_FLOOR, LEVER_TAG_READ};

/// `LOG_ID_MAIN` and `ANDROID_LOG_ERROR` (`android/log.h`).
const MAIN: i32 = 0;
const ERROR: i32 = 6;

/// Whether this build writes Haven's own lines once the lever is in.
const WRITES_OWN: bool = lever_writes_own(cfg!(debug_assertions));

/// `struct __android_log_message` (`android/log.h`, API 30).
#[repr(C)]
struct Message {
    struct_size: usize,
    buffer_id: i32,
    priority: i32,
    tag: *const c_char,
    file: *const c_char,
    line: u32,
    message: *const c_char,
}

// The NDK's layout, on Android's 64-bit ABIs and its 32-bit ones: a field read
// at another offset is another field.
const _: () = assert!(matches!(
    (
        size_of::<usize>(),
        size_of::<Message>(),
        offset_of!(Message, tag),
        offset_of!(Message, message),
    ),
    (8, 48, 16, 40) | (4, 28, 12, 24)
));

type Logger = unsafe extern "C" fn(*const Message);
type SetLogger = unsafe extern "C" fn(Logger);
type Write = unsafe extern "C" fn(*mut Message);
type SetFloor = unsafe extern "C" fn(i32) -> i32;
type Floor = unsafe extern "C" fn() -> i32;

/// The five functions of `liblog` the lever is made of.
struct Liblog {
    set_logger: SetLogger,
    logd_logger: Logger,
    write_log_message: Write,
    set_minimum_priority: SetFloor,
    get_minimum_priority: Floor,
}

/// What the one lookup found: nothing, where `liblog` lacks a function.
static LIBLOG: OnceLock<Option<Liblog>> = OnceLock::new();

/// The lines [`logger`] was handed, wrapping.
static LINES: AtomicU32 = AtomicU32::new(0);

/// The five functions as `library` has them. It is never closed, so they
/// stay.
fn lookup(library: &CStr) -> Option<Liblog> {
    // SAFETY: `library` is NUL-terminated and outlives the call.
    let handle = unsafe { libc::dlopen(library.as_ptr(), libc::RTLD_NOW) };
    if handle.is_null() {
        return None;
    }
    let find = |name: &CStr| {
        // SAFETY: `handle` is a library `dlopen` answered and nothing closes,
        // and `name` is NUL-terminated and outlives the call.
        let found = unsafe { libc::dlsym(handle, name.as_ptr()) };
        (!found.is_null()).then_some(found)
    };
    let set_logger = find(c"__android_log_set_logger")?;
    let logd_logger = find(c"__android_log_logd_logger")?;
    let write_log_message = find(c"__android_log_write_log_message")?;
    let set_minimum_priority = find(c"__android_log_set_minimum_priority")?;
    let get_minimum_priority = find(c"__android_log_get_minimum_priority")?;
    // SAFETY: none is null; each is what `liblog` exports under the name asked
    // for, a function whose C declaration (`android/log.h`, API 30) is the type
    // it is taken as; and where there is a `dlsym`, a pointer to a function is
    // a pointer to data in size and form.
    Some(unsafe {
        Liblog {
            set_logger: transmute::<*mut c_void, SetLogger>(set_logger),
            logd_logger: transmute::<*mut c_void, Logger>(logd_logger),
            write_log_message: transmute::<*mut c_void, Write>(write_log_message),
            set_minimum_priority: transmute::<*mut c_void, SetFloor>(set_minimum_priority),
            get_minimum_priority: transmute::<*mut c_void, Floor>(get_minimum_priority),
        }
    })
}

/// The first bytes of `message`'s tag, zeros after its end; `None` for a
/// message shorter than this struct, or with no tag.
fn tag_start(message: *const Message) -> Option<[u8; LEVER_TAG_READ]> {
    // SAFETY: `liblog` hands its logger a message that lives for the call and
    // is `struct_size` bytes long, that size its first field in every version.
    let size = unsafe { (*message).struct_size };
    if size < size_of::<Message>() {
        return None;
    }
    // SAFETY: the message is at least as long as this struct, so the field is
    // inside it.
    let mut next = unsafe { (*message).tag }.cast::<u8>();
    if next.is_null() {
        return None;
    }
    let mut start = [0; LEVER_TAG_READ];
    for byte in &mut start {
        // SAFETY: a tag is a NUL-terminated string that lives for the call.
        // `next` is its first byte, or the byte after one that was read and
        // was not the NUL: never past the string's end, however long the tag.
        *byte = unsafe { next.read() };
        if *byte == 0 {
            break;
        }
        next = next.wrapping_add(1);
    }
    Some(start)
}

/// Haven's logger: every line the process logs, in place of the write to
/// `logd`. Before [`install`] has found the platform's writer there is none
/// to hand a line to, and the line is dropped.
extern "C" fn logger(message: *const Message) {
    if !lever_line(WRITES_OWN, &LINES, || tag_start(message)) {
        return;
    }
    if let Some(liblog) = LIBLOG.get().and_then(Option::as_ref) {
        // SAFETY: the message is handed on as it came, inside the call that
        // handed it over, to the function `liblog` itself would have called.
        unsafe { (liblog.logd_logger)(message) };
    }
}

/// Puts the lever in, or back: Haven's logger, and the floor where the build
/// writes nothing. `false` where `liblog` has no such functions — below
/// Android 11 — and off Android, where it is not looked for.
pub(crate) fn install() -> bool {
    let found = LIBLOG.get_or_init(|| {
        if cfg!(target_os = "android") {
            lookup(c"liblog.so")
        } else {
            None
        }
    });
    let Some(liblog) = found else {
        return false;
    };
    // SAFETY: `logger` is of the type `liblog` calls a logger at, lives as
    // long as the process, and cannot unwind. The call stores one pointer.
    unsafe { (liblog.set_logger)(logger) };
    if !WRITES_OWN {
        // SAFETY: takes a plain integer and answers one.
        unsafe { (liblog.set_minimum_priority)(LEVER_FLOOR) };
    }
    true
}

/// Whether a line of this process is handed to Haven's logger now, and —
/// where the build writes nothing — the floor still stands. `false` before
/// [`install`] found a lever.
pub(crate) fn holds() -> bool {
    let Some(liblog) = LIBLOG.get().and_then(Option::as_ref) else {
        return false;
    };
    let empty: [c_char; 1] = [0];
    // To the main buffer: a message for the event buffers returns before the
    // logger. At ERROR: a FATAL one is first kept as the process's abort
    // message. Where the logger in force is not Haven's, this is written: one
    // empty line.
    let mut sentinel = Message {
        struct_size: size_of::<Message>(),
        buffer_id: MAIN,
        priority: ERROR,
        tag: empty.as_ptr(),
        file: std::ptr::null(),
        line: 0,
        message: empty.as_ptr(),
    };
    let before = LINES.load(Ordering::Relaxed);
    // SAFETY: `sentinel` is a whole message whose two strings are
    // NUL-terminated and outlive the call, and no logger keeps a message.
    unsafe { (liblog.write_log_message)(&raw mut sentinel) };
    // SAFETY: takes nothing and answers a plain integer.
    let floor = unsafe { (liblog.get_minimum_priority)() };
    lever_held(WRITES_OWN, before, LINES.load(Ordering::Relaxed), floor)
}

/// What a host can run: no `liblog` is here, so the calls through its
/// functions run nowhere but on Android. That the five resolve there, that
/// the logger is the one in force and that no platform line is written under
/// Haven's pid is proved by nothing until an emulator lane or a device runs.
#[cfg(test)]
mod tests {
    use std::ffi::{c_char, CStr};
    use std::sync::atomic::Ordering;

    use super::{
        holds, install, logger, lookup, tag_start, Message, LEVER_TAG_READ, LIBLOG, LINES,
    };

    fn message(struct_size: usize, tag: *const c_char) -> Message {
        Message {
            struct_size,
            buffer_id: 0,
            priority: 3,
            tag,
            file: std::ptr::null(),
            line: 0,
            message: c"a line".as_ptr(),
        }
    }

    fn start_of(tag: &CStr) -> Option<Vec<u8>> {
        let line = message(size_of::<Message>(), tag.as_ptr());
        tag_start(&raw const line).map(Vec::from)
    }

    /// A library that is not there is no lever, and neither is one that
    /// lacks the functions: on a glibc host — CI's — the second name opens
    /// and has none of the five; on any other it is absent too.
    #[test]
    fn a_library_that_is_absent_or_lacks_the_functions_is_no_lever() {
        assert!(lookup(c"libhaven-no-such-library.so").is_none());
        assert!(lookup(c"libc.so.6").is_none());
    }

    /// Off Android `liblog` is not looked for: there is no lever to put in
    /// and none that holds, before a first call and after.
    #[test]
    fn off_android_there_is_no_lever_and_none_is_looked_for() {
        assert!(!holds(), "a lever nothing installed holds");
        assert!(!install() && !install(), "a host has a lever");
        assert!(
            LIBLOG.get().is_some_and(Option::is_none),
            "the lookup was not settled by the first call"
        );
        assert!(!holds(), "no lever, and it holds");
    }

    /// A tag is read up to its NUL or up to the bytes that decide, whichever
    /// comes first; a message shorter than the struct, or with no tag, is
    /// not read at all.
    #[test]
    fn a_tag_is_read_to_its_end_or_to_the_bytes_that_decide() {
        let mut flutter = vec![0; LEVER_TAG_READ];
        flutter[..7].copy_from_slice(b"flutter");
        assert_eq!(start_of(c"flutter"), Some(flutter));
        assert_eq!(start_of(c""), Some(vec![0; LEVER_TAG_READ]));

        let long = c"haven_core::relay::live_sync::session";
        assert_eq!(
            start_of(long),
            Some(long.to_bytes()[..LEVER_TAG_READ].to_vec()),
            "a tag longer than the bytes that decide was not cut there"
        );

        let short = message(size_of::<Message>() - 1, c"flutter".as_ptr());
        assert!(
            tag_start(&raw const short).is_none(),
            "a message shorter than the struct had its tag read"
        );
        let untagged = message(size_of::<Message>(), std::ptr::null());
        assert!(tag_start(&raw const untagged).is_none());
    }

    /// The logger counts the line it is handed, and with no platform writer
    /// found it hands the line to nothing — an owned tag's too.
    #[test]
    fn the_logger_counts_every_line_it_is_handed() {
        for tag in [c"flutter", c"BluetoothGatt"] {
            let line = message(size_of::<Message>(), tag.as_ptr());
            let before = LINES.load(Ordering::Relaxed);
            logger(&raw const line);
            assert_ne!(LINES.load(Ordering::Relaxed), before);
        }
    }
}

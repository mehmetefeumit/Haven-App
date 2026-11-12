//! The JNI exports Android's radio service drives the mesh engine through
//! (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §A.6): one for each native method of
//! the Kotlin class `com.oblivioustech.haven.mesh.MeshNative`, as
//! `fixtures/mesh_radio_exports.txt` lists them.
//!
//! An export converts its arguments, makes one `radio_*` call under
//! `radio_guarded`, and converts the answer; it decides nothing. It calls
//! nothing of Java's, keeps no `JavaVM` and no reference, attaches no thread,
//! and logs and renders nothing. A JNI call that fails is answered as no
//! engine would answer, with no exception left for Java to throw.
//!
//! Built for Android, and into the host's test build, where every signature
//! is type-checked against `jni`. Only a JVM can call an export.

use haven_core::mesh::store::MAX_LINKS;
use jni::objects::{JByteArray, JLongArray, JObject};
use jni::sys::{jboolean, jbyteArray, jint, jlong, jsize, JNI_FALSE};
use jni::JNIEnv;

use crate::api::{
    radio_connect_failed, radio_guarded, radio_left_ms, radio_link_down, radio_link_up, radio_poll,
    radio_receive, radio_resume, radio_sighting, radio_wake_in_ms, RADIO_MAX_FRAME,
};

/// The most ready links one poll reads: the engine reads no more.
const LINKS: usize = MAX_LINKS as usize;

/// A link's or a peer's number: Kotlin's own, taken bit for bit.
const fn id(number: jlong) -> u64 {
    number.cast_unsigned()
}

const fn is_set(flag: jboolean) -> bool {
    flag != JNI_FALSE
}

/// The peer of a link: a negative number is none.
fn peer_of(peer: jlong) -> Option<u64> {
    u64::try_from(peer).ok()
}

/// Milliseconds from Java: a negative count is none left.
fn millis_in(ms: jlong) -> u64 {
    u64::try_from(ms).unwrap_or(0)
}

fn millis_out(ms: u64) -> jlong {
    jlong::try_from(ms).unwrap_or(jlong::MAX)
}

/// When the engine next has work, for Java: −1 when no engine runs.
fn wake_out(wake_in_ms: Option<u64>) -> jlong {
    wake_in_ms.map_or(-1, millis_out)
}

fn rssi_of(rssi: jint) -> i8 {
    i8::try_from(rssi).unwrap_or(if rssi < 0 { i8::MIN } else { i8::MAX })
}

fn att_mtu_of(att_mtu: jint) -> u16 {
    u16::try_from(att_mtu).unwrap_or(if att_mtu < 0 { 0 } else { u16::MAX })
}

/// The frame of `len` bytes that `read` copies out of Java. One longer than
/// a radio carries is not read: that many bytes of nothing stand for it, and
/// `radio_receive` closes the link of a frame that long.
fn frame_in<E>(len: jsize, read: impl FnOnce() -> Result<Vec<u8>, E>) -> Result<Vec<u8>, E> {
    if usize::try_from(len).is_ok_and(|len| len <= RADIO_MAX_FRAME) {
        read()
    } else {
        Ok(vec![0; RADIO_MAX_FRAME + 1])
    }
}

/// How many of `len` ready links are read.
fn ready_count(len: jsize) -> usize {
    usize::try_from(len).map_or(0, |len| len.min(LINKS))
}

/// The links of `ready`, cut to the engine's bound before any is read.
fn ready_in(env: &JNIEnv, ready: &JLongArray) -> jni::errors::Result<([u64; LINKS], usize)> {
    let mut links = [0; LINKS];
    let count = ready_count(env.get_array_length(ready)?);
    env.get_long_array_region(ready, 0, &mut links[..count])?;
    Ok((links.map(id), count))
}

/// What a JNI call answered, or `None` when it failed. The exception a failed
/// call may have left is cleared: returned with, Java would throw it.
fn settled<T>(env: &JNIEnv, answer: jni::errors::Result<T>) -> Option<T> {
    if answer.is_err() {
        let _ = env.exception_clear();
    }
    answer.ok()
}

// The second parameter of every export is the receiver, or the class if
// Kotlin declares the method static: the same pointer either way, never read.

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_resume(
    _env: JNIEnv,
    _this: JObject,
    left_ms: jlong,
) -> jboolean {
    let left_ms = millis_in(left_ms);
    jboolean::from(radio_guarded(false, || radio_resume(left_ms)))
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    millis_out(radio_guarded(0, radio_left_ms))
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_sighting(
    _env: JNIEnv,
    _this: JObject,
    peer: jlong,
    rssi: jint,
) {
    let (peer, rssi) = (id(peer), rssi_of(rssi));
    radio_guarded((), || radio_sighting(peer, rssi));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_linkUp(
    _env: JNIEnv,
    _this: JObject,
    link: jlong,
    central: jboolean,
    att_mtu: jint,
    peer: jlong,
) {
    let (link, central) = (id(link), is_set(central));
    let (att_mtu, peer) = (att_mtu_of(att_mtu), peer_of(peer));
    radio_guarded((), || radio_link_up(link, central, att_mtu, peer));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_linkDown(
    _env: JNIEnv,
    _this: JObject,
    link: jlong,
) {
    let link = id(link);
    radio_guarded((), || radio_link_down(link));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_connectFailed(
    _env: JNIEnv,
    _this: JObject,
    peer: jlong,
) {
    let peer = id(peer);
    radio_guarded((), || radio_connect_failed(peer));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_receive(
    env: JNIEnv,
    _this: JObject,
    link: jlong,
    frame: JByteArray,
) {
    let read = env
        .get_array_length(&frame)
        .and_then(|len| frame_in(len, || env.convert_byte_array(&frame)));
    let Some(frame) = settled(&env, read) else {
        return;
    };
    let link = id(link);
    radio_guarded((), || radio_receive(link, &frame));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_poll(
    env: JNIEnv,
    _this: JObject,
    ready: JLongArray,
) -> jbyteArray {
    let Some((links, count)) = settled(&env, ready_in(&env, &ready)) else {
        return std::ptr::null_mut();
    };
    let output = radio_guarded(None, || radio_poll(&links[..count]));
    output
        .and_then(|output| settled(&env, env.byte_array_from_slice(&output)))
        .map_or(std::ptr::null_mut(), JByteArray::into_raw)
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_wakeInMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    wake_out(radio_guarded(None, radio_wake_in_ms))
}

/// The conversions, which need no JVM. Calling an export needs one: that the
/// nine link under their names and answer a Kotlin caller is proved only by
/// an Android build and an emulator lane or a device, none of which runs
/// here. What this build proves of the exports is their types, against `jni`.
#[cfg(test)]
mod tests {
    use super::{
        att_mtu_of, frame_in, id, is_set, millis_in, millis_out, peer_of, ready_count, rssi_of,
        wake_out, LINKS, RADIO_MAX_FRAME,
    };

    #[test]
    fn a_link_or_peer_number_crosses_bit_for_bit() {
        assert_eq!(id(0), 0);
        assert_eq!(id(i64::MAX), 0x7fff_ffff_ffff_ffff);
        assert_eq!(id(-1), u64::MAX);
        assert_eq!(id(i64::MIN), 0x8000_0000_0000_0000);
    }

    #[test]
    fn a_java_boolean_is_true_unless_it_is_zero() {
        assert!(!is_set(0));
        assert!(is_set(1));
        assert!(is_set(u8::MAX));
    }

    #[test]
    fn a_negative_peer_of_a_link_is_no_peer() {
        assert_eq!(peer_of(-1), None);
        assert_eq!(peer_of(i64::MIN), None);
        assert_eq!(peer_of(0), Some(0));
        assert_eq!(peer_of(i64::MAX), Some(0x7fff_ffff_ffff_ffff));
    }

    #[test]
    fn a_negative_time_left_is_none_and_no_time_overflows_a_long() {
        assert_eq!(millis_in(-1), 0);
        assert_eq!(millis_in(i64::MIN), 0);
        assert_eq!(millis_in(43_200_000), 43_200_000);
        assert_eq!(millis_out(43_200_000), 43_200_000);
        assert_eq!(millis_out(u64::MAX), i64::MAX);
    }

    #[test]
    fn no_engine_is_a_wake_of_minus_one_and_a_wake_now_is_zero() {
        assert_eq!(wake_out(None), -1);
        assert_eq!(wake_out(Some(0)), 0);
        assert_eq!(wake_out(Some(5_000)), 5_000);
        assert_eq!(wake_out(Some(u64::MAX)), i64::MAX);
    }

    #[test]
    fn a_signal_strength_and_an_mtu_are_clamped_into_their_types() {
        assert_eq!(rssi_of(-40), -40);
        assert_eq!(rssi_of(-129), -128);
        assert_eq!(rssi_of(i32::MIN), -128);
        assert_eq!(rssi_of(128), 127);
        assert_eq!(rssi_of(i32::MAX), 127);
        assert_eq!(att_mtu_of(517), 517);
        assert_eq!(att_mtu_of(-1), 0);
        assert_eq!(att_mtu_of(i32::MIN), 0);
        assert_eq!(att_mtu_of(65_536), 65_535);
        assert_eq!(att_mtu_of(i32::MAX), 65_535);
    }

    #[test]
    fn a_frame_longer_than_a_radio_carries_is_not_read() {
        let longest = i32::try_from(RADIO_MAX_FRAME).expect("a frame's length is a Java int");
        for len in [0, 1, longest] {
            assert_eq!(
                frame_in(len, || Ok::<_, ()>(vec![7])),
                Ok(vec![7]),
                "a frame of {len} bytes was not read"
            );
        }
        for len in [longest + 1, i32::MAX, -1] {
            let mut read = false;
            let frame = frame_in(len, || {
                read = true;
                Ok::<_, ()>(Vec::new())
            });
            assert!(!read, "a frame of {len} bytes was copied out of Java");
            assert!(
                frame.is_ok_and(|frame| frame.len() == RADIO_MAX_FRAME + 1),
                "what stands for a frame of {len} bytes is not one its link is closed for"
            );
        }
        assert_eq!(frame_in(1, || Err::<Vec<u8>, _>(())), Err(()));
    }

    #[test]
    fn the_ready_links_are_cut_to_the_engines_bound() {
        let bound = i32::try_from(LINKS).expect("the bound is a Java int");
        assert_eq!(ready_count(0), 0);
        assert_eq!(ready_count(bound - 1), LINKS - 1);
        assert_eq!(ready_count(bound), LINKS);
        assert_eq!(ready_count(bound + 1), LINKS);
        assert_eq!(ready_count(i32::MAX), LINKS);
        assert_eq!(ready_count(-1), 0);
    }
}

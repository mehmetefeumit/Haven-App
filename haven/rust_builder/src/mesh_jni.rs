//! The JNI exports of the mesh radio's calls: one for each native method of
//! the Kotlin class `com.oblivioustech.haven.mesh.MeshNative`, as
//! `fixtures/mesh_radio_exports.txt` lists them, each forwarding to its
//! function in `mesh_radio.rs` and doing nothing else.
//!
//! This file is exempt from the crate's `unsafe_code` deny, which fires on
//! `#[no_mangle]`, so the compiler checks nothing of that kind in it. What it
//! may hold is therefore fixed, and `scripts/ci/check_mesh_radio.sh` reads
//! every line: `use`s, and the exports. Anything else belongs in
//! `mesh_radio.rs`, under the deny.
//!
//! The second parameter of every export is the receiver, or the class if
//! Kotlin declares the method static: the same pointer either way, never
//! read.

use jni::objects::{JByteArray, JLongArray, JObject};
use jni::sys::{jboolean, jbyteArray, jint, jlong};
use jni::JNIEnv;

use crate::mesh_radio;

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_resume(
    _env: JNIEnv,
    _this: JObject,
    left_ms: jlong,
) -> jboolean {
    mesh_radio::resume(left_ms)
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    mesh_radio::left_ms()
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_sighting(
    _env: JNIEnv,
    _this: JObject,
    peer: jlong,
    rssi: jint,
) {
    mesh_radio::sighting(peer, rssi);
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
    mesh_radio::link_up(link, central, att_mtu, peer);
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_linkDown(
    _env: JNIEnv,
    _this: JObject,
    link: jlong,
) {
    mesh_radio::link_down(link);
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_connectFailed(
    _env: JNIEnv,
    _this: JObject,
    peer: jlong,
) {
    mesh_radio::connect_failed(peer);
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_receive(
    env: JNIEnv,
    _this: JObject,
    link: jlong,
    frame: JByteArray,
) {
    mesh_radio::receive(&env, link, &frame);
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_poll(
    env: JNIEnv,
    _this: JObject,
    ready: JLongArray,
) -> jbyteArray {
    mesh_radio::poll(&env, &ready)
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_wakeInMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    mesh_radio::wake_in_ms()
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leverInstall(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    mesh_radio::lever_install()
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leverHolds(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    mesh_radio::lever_holds()
}

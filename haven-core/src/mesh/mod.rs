//! Bluetooth mesh: an opt-in second carrier for the location events the relay
//! path already seals (`docs/BLUETOOTH_MESH_PLAN.md`).
//!
//! Nothing here does I/O, reads a clock, holds a static, names an MDK type or
//! logs. Randomness is always an injected generator: `OsRng` in production, a
//! seeded or scripted one in tests.

pub mod engine;
pub mod frame;
pub mod noise;
pub mod packet;
pub mod store;

#[cfg(test)]
pub(crate) mod test_rng {
    use std::collections::VecDeque;

    use rand::{CryptoRng, RngCore};

    /// Returns the bytes it was given, in order, and panics when asked for
    /// more: a test that scripts it fixes every byte a function draws and
    /// proves it draws no others.
    pub struct Scripted(VecDeque<u8>);

    impl Scripted {
        pub fn new(bytes: &[u8]) -> Self {
            Self(bytes.iter().copied().collect())
        }

        pub fn is_spent(&self) -> bool {
            self.0.is_empty()
        }
    }

    impl RngCore for Scripted {
        fn next_u32(&mut self) -> u32 {
            let mut bytes = [0; 4];
            self.fill_bytes(&mut bytes);
            u32::from_le_bytes(bytes)
        }

        fn next_u64(&mut self) -> u64 {
            let mut bytes = [0; 8];
            self.fill_bytes(&mut bytes);
            u64::from_le_bytes(bytes)
        }

        fn fill_bytes(&mut self, dest: &mut [u8]) {
            for byte in dest {
                *byte = self.0.pop_front().expect("the script covers every draw");
            }
        }

        fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand::Error> {
            self.fill_bytes(dest);
            Ok(())
        }
    }

    impl CryptoRng for Scripted {}
}

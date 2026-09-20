//! Backpressure with a deadline for the AudioQueue feeders.
//!
//! The queue's callback drains a bounded channel; a writer waits while it is
//! full. When the device stops pulling audio (unplugged, an iOS audio-session
//! interruption) the callback never runs again, so a plain `send` would block
//! the writer, and anything joining its thread, forever.

use std::sync::mpsc::{SyncSender, TrySendError};
use std::time::{Duration, Instant};

/// Sends `item`, waiting while the channel is full, but fails once `stall`
/// passes without the receiver making room.
pub(crate) fn send_or_stall<T>(
    tx: &SyncSender<T>,
    mut item: T,
    stall: Duration,
) -> Result<(), String> {
    let deadline = Instant::now() + stall;
    loop {
        match tx.try_send(item) {
            Ok(()) => return Ok(()),
            Err(TrySendError::Full(back)) => {
                if Instant::now() >= deadline {
                    return Err("audio device stalled: the output stopped draining \
                         (device removed or failed?)"
                        .into());
                }
                item = back;
                std::thread::sleep(Duration::from_millis(2));
            }
            Err(TrySendError::Disconnected(_)) => return Err("audio channel closed".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::sync_channel;

    #[test]
    fn waits_for_the_receiver_to_make_room() {
        let (tx, rx) = sync_channel::<u8>(1);
        tx.send(1).unwrap();
        let reader = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            (rx.recv().unwrap(), rx.recv().unwrap())
        });
        send_or_stall(&tx, 2, Duration::from_secs(5)).unwrap();
        assert_eq!(reader.join().unwrap(), (1, 2));
    }

    #[test]
    fn fails_when_nothing_drains() {
        let (tx, _rx) = sync_channel::<u8>(1);
        tx.send(1).unwrap();
        let started = Instant::now();
        let err = send_or_stall(&tx, 2, Duration::from_millis(50)).unwrap_err();
        assert!(err.contains("stalled"), "{err}");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn fails_when_the_receiver_is_gone() {
        let (tx, rx) = sync_channel::<u8>(1);
        drop(rx);
        let err = send_or_stall(&tx, 1, Duration::from_secs(5)).unwrap_err();
        assert!(err.contains("closed"), "{err}");
    }
}

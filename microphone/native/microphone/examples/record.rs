//! Smoke test for the native capture path: records a few seconds from the
//! default input via the C ABI and writes a WAV. Run with:
//!
//! ```sh
//! cargo run --example record               # records 3 s to recording.wav
//! cargo run --example record out.wav 5     # records 5 s to out.wav
//! ```
//!
//! On macOS the first run prompts for microphone permission; grant it.

use std::ffi::CStr;
use std::thread::sleep;
use std::time::Duration;

use hound::{SampleFormat, WavSpec, WavWriter};
use microphone::{
    microphone_channels, microphone_last_error, microphone_read, microphone_recorder_free,
    microphone_recorder_new, microphone_sample_rate, microphone_start, microphone_stop,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| "recording.wav".into());
    let secs: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(3);
    let rate = 44_100u32;
    let channels = 1u32;

    unsafe {
        let recorder = microphone_recorder_new();
        if recorder.is_null() {
            let msg = CStr::from_ptr(microphone_last_error()).to_string_lossy();
            eprintln!("recorder init failed: {msg}");
            std::process::exit(1);
        }
        // On macOS the first AudioQueue input call blocks until the microphone
        // permission prompt is answered; grant it when it appears.
        // Null device_id captures from the system default input.
        let id = microphone_start(recorder, rate, channels, std::ptr::null());
        if id == 0 {
            let msg = CStr::from_ptr(microphone_last_error()).to_string_lossy();
            eprintln!("start failed: {msg}");
            std::process::exit(1);
        }
        let actual_rate = microphone_sample_rate(recorder, id) as u32;
        let actual_channels = microphone_channels(recorder, id) as u16;
        println!("recording {secs}s at {actual_rate} Hz, {actual_channels} ch...");

        let mut pcm: Vec<i16> = Vec::new();
        let mut buf = vec![0i16; 16_384];
        let deadline = secs * 20; // poll ~every 50 ms
        for _ in 0..deadline {
            let n = microphone_read(recorder, id, buf.as_mut_ptr(), buf.len());
            if n < 0 {
                let msg = CStr::from_ptr(microphone_last_error()).to_string_lossy();
                eprintln!("read error: {msg}");
                break;
            }
            pcm.extend_from_slice(&buf[..n as usize]);
            sleep(Duration::from_millis(50));
        }
        microphone_stop(recorder, id);

        // Drain anything captured after the last poll.
        loop {
            let n = microphone_read(recorder, id, buf.as_mut_ptr(), buf.len());
            if n <= 0 {
                break;
            }
            pcm.extend_from_slice(&buf[..n as usize]);
        }
        microphone_recorder_free(recorder);

        let spec = WavSpec {
            channels: actual_channels,
            sample_rate: actual_rate,
            bits_per_sample: 16,
            sample_format: SampleFormat::Int,
        };
        let mut w = WavWriter::create(&path, spec).expect("create wav");
        for &s in &pcm {
            w.write_sample(s).expect("write sample");
        }
        w.finalize().expect("finalize wav");

        let peak = pcm.iter().map(|&s| s.unsigned_abs()).max().unwrap_or(0);
        println!(
            "wrote {} frames to {path} (peak amplitude {peak})",
            pcm.len() / actual_channels.max(1) as usize
        );
    }
}

//! A `symphonia::core::io::MediaSource` backed by an HTTP response body that
//! is still downloading, so decoding (and therefore playback) can start
//! before the whole file has arrived.
//!
//! A background thread pulls bytes from [`net::get`] and appends them to a
//! shared, growable buffer; [`StreamingSource`] serves `Read`/`Seek` against
//! that buffer, blocking when a read or forward seek needs bytes that
//! haven't arrived yet. Already-downloaded bytes stay in the buffer for the
//! lifetime of the source, so seeking backward (or re-reading during a
//! format probe) is always immediate — the tradeoff is holding the whole
//! track in memory by the time it finishes downloading, same as the
//! existing bytes/file sources after `symphonia` decodes them.

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use symphonia::core::io::MediaSource;

use crate::net;

struct Shared {
    /// Bytes downloaded so far, in order from the start of the response.
    buf: Vec<u8>,
    /// Total size from `Content-Length`, if the server sent one.
    total_len: Option<u64>,
    /// Set once the download finishes (successfully or not).
    done: bool,
    /// Set if the download failed; `buf` holds whatever arrived before that.
    error: Option<String>,
}

/// A growable-buffer-backed streaming source fed by a background fetch
/// thread. See the module docs for the buffering/seek tradeoffs.
pub struct StreamingSource {
    shared: Arc<(Mutex<Shared>, Condvar)>,
    pos: u64,
    /// Kept only to detach the thread on drop the same way it exits.
    _handle: Option<thread::JoinHandle<()>>,
}

impl StreamingSource {
    /// Starts fetching `url` (with `headers`) in a background thread and
    /// returns a source that can be handed to `symphonia` immediately —
    /// reads block until enough of the response has arrived.
    pub fn fetch(url: String, headers: Vec<(String, String)>) -> StreamingSource {
        let shared = Arc::new((
            Mutex::new(Shared {
                buf: Vec::new(),
                total_len: None,
                done: false,
                error: None,
            }),
            Condvar::new(),
        ));
        let worker_shared = shared.clone();
        let handle = thread::spawn(move || Self::run(url, headers, worker_shared));
        StreamingSource {
            shared,
            pos: 0,
            _handle: Some(handle),
        }
    }

    fn run(url: String, headers: Vec<(String, String)>, shared: Arc<(Mutex<Shared>, Condvar)>) {
        let (lock, cvar) = &*shared;
        let mut response = match net::get(&url, &headers) {
            Ok(r) => r,
            Err(e) => {
                let mut state = lock.lock().unwrap();
                state.error = Some(e);
                state.done = true;
                cvar.notify_all();
                return;
            }
        };
        if !(200..300).contains(&response.status) {
            let mut state = lock.lock().unwrap();
            state.error = Some(format!("HTTP status {}", response.status));
            state.done = true;
            cvar.notify_all();
            return;
        }
        let content_length = response
            .header("content-length")
            .and_then(|v| v.parse::<u64>().ok());
        {
            let mut state = lock.lock().unwrap();
            state.total_len = content_length;
            cvar.notify_all();
        }

        let mut chunk = [0u8; 64 * 1024];
        loop {
            match response.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    let mut state = lock.lock().unwrap();
                    state.buf.extend_from_slice(&chunk[..n]);
                    cvar.notify_all();
                }
                Err(e) => {
                    let mut state = lock.lock().unwrap();
                    state.error = Some(format!("read body: {e}"));
                    break;
                }
            }
        }
        let mut state = lock.lock().unwrap();
        state.done = true;
        cvar.notify_all();
    }

    /// Blocks until at least `upto` bytes are buffered, or the fetch is done
    /// (successfully or with an error).
    fn wait_until(&self, upto: u64) -> io::Result<()> {
        let (lock, cvar) = &*self.shared;
        let mut state = lock.lock().unwrap();
        while (state.buf.len() as u64) < upto && !state.done {
            state = cvar.wait(state).unwrap();
        }
        if let Some(e) = &state.error {
            if (state.buf.len() as u64) < upto {
                return Err(io::Error::other(e.clone()));
            }
        }
        Ok(())
    }
}

impl Read for StreamingSource {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        // Wait for at least one more byte than we've already consumed, i.e.
        // any progress at all, rather than a full buffer's worth.
        self.wait_until(self.pos + 1)?;
        let (lock, _) = &*self.shared;
        let state = lock.lock().unwrap();
        let available = state.buf.len() as u64;
        if self.pos >= available {
            // Woken because the fetch finished with nothing more to give.
            return Ok(0);
        }
        let start = self.pos as usize;
        let end = (available as usize).min(start + out.len());
        let n = end - start;
        out[..n].copy_from_slice(&state.buf[start..end]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for StreamingSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let target = match pos {
            SeekFrom::Start(n) => n,
            SeekFrom::Current(delta) => {
                let base = self.pos as i64;
                (base + delta).max(0) as u64
            }
            SeekFrom::End(delta) => {
                self.wait_until(u64::MAX)?; // wait for the full download to know the end.
                let (lock, _) = &*self.shared;
                let len = lock.lock().unwrap().buf.len() as u64;
                let base = len as i64;
                (base + delta).max(0) as u64
            }
        };
        // Waiting for `target` bytes to exist makes a forward seek block
        // until the data arrives, and a backward seek within already-
        // buffered data return immediately.
        self.wait_until(target)?;
        self.pos = target;
        Ok(self.pos)
    }
}

impl MediaSource for StreamingSource {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        let (lock, _) = &*self.shared;
        lock.lock().unwrap().total_len
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpListener;

    fn serve_slowly(body: &'static [u8], chunk_len: usize) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut discard = [0u8; 4096];
            let _ = stream.read(&mut discard);
            stream
                .write_all(
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).as_bytes(),
                )
                .unwrap();
            for chunk in body.chunks(chunk_len) {
                stream.write_all(chunk).unwrap();
                stream.flush().unwrap();
                thread::sleep(std::time::Duration::from_millis(5));
            }
        });
        format!("http://{addr}/track")
    }

    #[test]
    fn reads_full_body_as_it_arrives() {
        let body: Vec<u8> = (0u8..=255).collect();
        let leaked: &'static [u8] = Box::leak(body.clone().into_boxed_slice());
        let url = serve_slowly(leaked, 16);
        let mut source = StreamingSource::fetch(url, Vec::new());
        let mut got = Vec::new();
        source.read_to_end(&mut got).unwrap();
        assert_eq!(got, body);
    }

    #[test]
    fn byte_len_reflects_content_length() {
        let body: &'static [u8] = b"hello world, this is a streamed body";
        let url = serve_slowly(body, 8);
        let mut source = StreamingSource::fetch(url, Vec::new());
        // Force at least one read so byte_len (set from the response headers
        // before any body arrives) is populated deterministically in a test
        // without a race against the fetch thread's startup.
        let mut first = [0u8; 1];
        source.read_exact(&mut first).unwrap();
        assert_eq!(source.byte_len(), Some(body.len() as u64));
    }

    #[test]
    fn seek_backward_after_forward_read() {
        let body: Vec<u8> = (0u8..=200).collect();
        let leaked: &'static [u8] = Box::leak(body.clone().into_boxed_slice());
        let url = serve_slowly(leaked, 32);
        let mut source = StreamingSource::fetch(url, Vec::new());
        let mut all = Vec::new();
        source.read_to_end(&mut all).unwrap();
        assert_eq!(all, body);

        source.seek(SeekFrom::Start(10)).unwrap();
        let mut buf = [0u8; 5];
        source.read_exact(&mut buf).unwrap();
        assert_eq!(buf, body[10..15]);
    }

    #[test]
    fn propagates_fetch_error() {
        // Nothing is listening on this port.
        let mut source = StreamingSource::fetch("http://127.0.0.1:1".to_string(), Vec::new());
        let mut buf = [0u8; 8];
        assert!(source.read(&mut buf).is_err());
    }
}

//! The sample queue between a backend's capture thread and `PcmSource::read`
//! (ALSA, AAudio, waveIn).

use std::sync::Mutex;

/// Samples captured by a reader thread and not yet drained, plus the error that
/// ended capture, if any.
#[derive(Default)]
pub(crate) struct SampleQueue {
    samples: Mutex<Vec<i16>>,
    error: Mutex<Option<String>>,
}

impl SampleQueue {
    /// Appends freshly captured interleaved samples.
    pub fn push(&self, samples: &[i16]) {
        if let Ok(mut queued) = self.samples.lock() {
            queued.extend_from_slice(samples);
        }
    }

    /// Records why the reader thread stopped capturing. The first error wins.
    pub fn fail(&self, error: String) {
        if let Ok(mut slot) = self.error.lock() {
            slot.get_or_insert(error);
        }
    }

    /// Drains up to `max` queued samples (see `PcmSource::read`). Once the
    /// queue is empty, the error recorded by [`fail`](Self::fail) is returned,
    /// so a capture that died is reported rather than reading as silence.
    pub fn read(&self, max: usize) -> Result<Vec<i16>, String> {
        let mut samples = self.samples.lock().map_err(|e| e.to_string())?;
        if samples.is_empty() {
            return match self.error.lock().map_err(|e| e.to_string())?.as_ref() {
                Some(e) => Err(e.clone()),
                None => Ok(Vec::new()),
            };
        }
        if max == 0 {
            return Ok(Vec::new());
        }
        if samples.len() <= max {
            return Ok(std::mem::take(&mut *samples));
        }
        let rest = samples.split_off(max);
        Ok(std::mem::replace(&mut *samples, rest))
    }
}

#[cfg(test)]
mod tests {
    use super::SampleQueue;

    #[test]
    fn drains_up_to_max_and_keeps_the_rest() {
        let q = SampleQueue::default();
        q.push(&[1, 2, 3]);
        q.push(&[4, 5]);
        assert_eq!(q.read(4).unwrap(), vec![1, 2, 3, 4]);
        assert_eq!(q.read(4).unwrap(), vec![5]);
        assert_eq!(q.read(4).unwrap(), Vec::<i16>::new());
    }

    #[test]
    fn reports_the_error_after_the_queued_samples() {
        let q = SampleQueue::default();
        q.push(&[1, 2]);
        q.fail("device gone".into());
        q.fail("later error".into());
        assert_eq!(q.read(16).unwrap(), vec![1, 2]);
        assert_eq!(q.read(16), Err("device gone".to_string()));
        assert_eq!(q.read(16), Err("device gone".to_string()));
    }
}

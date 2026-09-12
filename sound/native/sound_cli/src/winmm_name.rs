//! Matching a requested output device against the names WinMM enumerates.
//! Kept apart from `winmm` (Windows-only) so its tests run on any host.

/// WAVEOUTCAPSW's szPname holds 32 UTF-16 units including the NUL, so
/// drivers cut longer names off at 31.
const TRUNCATED_LEN: usize = 31;

/// Returns the id of the entry in `devices` (id and name, in enumeration
/// order) that `wanted` names, ignoring case. An exact match wins. Failing
/// that, `wanted` may be the start of a longer device name, or a device name
/// the driver truncated may be the start of `wanted`.
pub(crate) fn match_output_device(wanted: &str, devices: &[(u32, String)]) -> Option<u32> {
    let wanted = wanted.trim().to_lowercase();
    if wanted.is_empty() {
        return None;
    }
    let exact = devices
        .iter()
        .find(|(_, name)| name.to_lowercase() == wanted);
    let prefix = || {
        devices.iter().find(|(_, name)| {
            let folded = name.to_lowercase();
            let truncated = name.encode_utf16().count() == TRUNCATED_LEN;
            folded.starts_with(&wanted) || (truncated && wanted.starts_with(&folded))
        })
    };
    exact.or_else(prefix).map(|(id, _)| *id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn devices(names: &[&str]) -> Vec<(u32, String)> {
        names
            .iter()
            .enumerate()
            .map(|(id, name)| (id as u32, name.to_string()))
            .collect()
    }

    #[test]
    fn prefers_an_exact_match_over_an_earlier_prefix_match() {
        let devices = devices(&["Speakers (USB)", "Speakers"]);
        assert_eq!(match_output_device("speakers", &devices), Some(1));
    }

    #[test]
    fn a_shorter_device_name_does_not_match() {
        let devices = devices(&["Speakers", "Headphones"]);
        assert_eq!(match_output_device("Speakers (USB)", &devices), None);
    }

    #[test]
    fn an_empty_name_never_matches() {
        let devices = devices(&["", "Speakers"]);
        assert_eq!(match_output_device("CABLE Input", &devices), None);
        assert_eq!(match_output_device("  ", &devices), None);
    }

    #[test]
    fn matches_the_start_of_a_longer_device_name() {
        let devices = devices(&["Speakers", "CABLE Input (VB-Audio Virtual Cable)"]);
        assert_eq!(match_output_device(" cable input ", &devices), Some(1));
    }

    #[test]
    fn matches_a_name_the_driver_truncated() {
        let full = "CABLE Input (VB-Audio Virtual Cable)";
        let truncated: String = full.chars().take(TRUNCATED_LEN).collect();
        let devices = devices(&["Speakers", &truncated]);
        assert_eq!(match_output_device(full, &devices), Some(1));
    }
}

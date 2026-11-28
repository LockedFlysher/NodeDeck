use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum StreamResolutionPreset {
    Fhd1080p,
    Qhd1440p,
    Uhd4k,
}

impl StreamResolutionPreset {
    pub fn dimensions(self) -> (u32, u32) {
        match self {
            Self::Fhd1080p => (1920, 1080),
            Self::Qhd1440p => (2560, 1440),
            Self::Uhd4k => (3840, 2160),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Fhd1080p => "1080p",
            Self::Qhd1440p => "1440p",
            Self::Uhd4k => "4K",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum StreamRefreshRate {
    Hz30 = 30,
    Hz60 = 60,
    Hz120 = 120,
    Hz144 = 144,
    Hz165 = 165,
}

/// Computes recommended Moonlight video bitrate (kbps), scaled smoothly by
/// pixel area and frame rate, rounded to nearest 2 Mbps step (4..120 Mbps).
/// Supports 30Hz low-bandwidth presets (e.g. 1080p@30Hz = 12 Mbps, 720p@30Hz = 6 Mbps).
pub fn recommended_bitrate_kbps(width: u32, height: u32, fps: u32) -> u32 {
    let w = width.max(640) as f64;
    let h = height.max(360) as f64;
    let f = fps.max(30) as f64;
    let pixel_ratio = (w * h) / (1920.0 * 1080.0);
    let fps_ratio = f / 60.0;
    let raw = 20_000.0 * pixel_ratio.powf(0.72) * fps_ratio.powf(0.75);
    let stepped = ((raw / 2_000.0).round() as u32).saturating_mul(2_000);
    stepped.clamp(4_000, 120_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitrate_scales_monotonically() {
        let b1080_30 = recommended_bitrate_kbps(1920, 1080, 30);
        let b1080 = recommended_bitrate_kbps(1920, 1080, 60);
        let b1440 = recommended_bitrate_kbps(2560, 1440, 60);
        let b4k120 = recommended_bitrate_kbps(3840, 2160, 120);
        assert!(b1080_30 < b1080);
        assert_eq!(b1080, 20_000);
        assert!(b1440 > b1080);
        assert!(b4k120 > b1440);
        assert!(b4k120 <= 120_000);
    }
}

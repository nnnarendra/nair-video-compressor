use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const SETTINGS_FILE_NAME: &str = "kompres-video-settings.json";
const VALID_PRESETS: [&str; 5] = ["ringan", "seimbang", "youtube", "kecil", "265"];
const VALID_RESOLUSI: [&str; 4] = ["", "1080", "720", "480"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AppSettings {
    #[serde(default = "default_preset")]
    pub preset: String,
    #[serde(default)]
    pub resolusi: String,
    #[serde(default)]
    pub output_dir: String,
    #[serde(default)]
    pub use_gpu: bool,
}

fn default_preset() -> String {
    "seimbang".to_string()
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            preset: default_preset(),
            resolusi: String::new(),
            output_dir: String::new(),
            use_gpu: false,
        }
    }
}

impl AppSettings {
    pub fn sanitize(mut self) -> Self {
        let preset_trimmed = self.preset.trim().to_ascii_lowercase();
        self.preset = if VALID_PRESETS.contains(&preset_trimmed.as_str()) {
            preset_trimmed
        } else {
            default_preset()
        };

        let res_trimmed = self.resolusi.trim().to_string();
        self.resolusi = if VALID_RESOLUSI.contains(&res_trimmed.as_str()) {
            res_trimmed
        } else {
            String::new()
        };

        self.output_dir = self.output_dir.trim().trim_matches('"').to_string();
        self
    }
}

fn exe_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("NAIR_PORTABLE_DIR") {
        let p = PathBuf::from(dir);
        if !p.as_os_str().is_empty() {
            return Some(p);
        }
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
}

pub fn appdata_dir() -> PathBuf {
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        PathBuf::from(local).join("nair-video-compressor")
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".config").join("nair-video-compressor")
    } else {
        std::env::temp_dir().join("nair-video-compressor")
    }
}

pub fn is_dir_writable(dir: &Path) -> bool {
    if !dir.exists() && fs::create_dir_all(dir).is_err() {
        return false;
    }
    let probe = dir.join(format!(".nair-write-probe-{}", std::process::id()));
    match fs::OpenOptions::new().write(true).create_new(true).open(&probe) {
        Ok(_) => {
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

pub fn resolve_settings_path() -> PathBuf {
    if let Some(dir) = exe_dir() {
        let candidate = dir.join(SETTINGS_FILE_NAME);
        if is_dir_writable(&dir) {
            return candidate;
        }
    }
    appdata_dir().join(SETTINGS_FILE_NAME)
}

pub fn load_settings() -> AppSettings {
    let mut candidates = Vec::new();
    if let Some(dir) = exe_dir() {
        candidates.push(dir.join(SETTINGS_FILE_NAME));
    }
    candidates.push(appdata_dir().join(SETTINGS_FILE_NAME));

    for path in candidates {
        if path.is_file() {
            if let Ok(raw) = fs::read_to_string(&path) {
                let cleaned = raw.trim_start_matches('\u{feff}');
                if let Ok(parsed) = serde_json::from_str::<AppSettings>(cleaned) {
                    return parsed.sanitize();
                }
            }
        }
    }

    AppSettings::default()
}

pub fn save_settings(settings: &AppSettings) -> Result<(), String> {
    let clean = settings.clone().sanitize();
    let path = resolve_settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create settings folder: {}", e))?;
    }
    let json = serde_json::to_string_pretty(&clean)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;
    fs::write(&path, format!("{}\n", json))
        .map_err(|e| format!("Failed to save settings to {}: {}", path.display(), e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pascal_case_json_round_trip() {
        let raw = r#"{
            "Preset": "265",
            "Resolusi": "1080",
            "OutputDir": "D:\\Videos\\Out",
            "UseGpu": true
        }"#;

        let parsed: AppSettings = serde_json::from_str(raw).unwrap();
        let clean = parsed.sanitize();
        assert_eq!(clean.preset, "265");
        assert_eq!(clean.resolusi, "1080");
        assert_eq!(clean.output_dir, r"D:\Videos\Out");
        assert!(clean.use_gpu);

        let serialized = serde_json::to_value(&clean).unwrap();
        assert_eq!(serialized["Preset"], "265");
        assert_eq!(serialized["Resolusi"], "1080");
        assert_eq!(serialized["OutputDir"], r"D:\Videos\Out");
        assert_eq!(serialized["UseGpu"], true);
    }

    #[test]
    fn invalid_values_fallback_to_defaults() {
        let dirty = AppSettings {
            preset: "ultra-max".to_string(),
            resolusi: "4k".to_string(),
            output_dir: "  \"C:\\Temp\\Out\"  ".to_string(),
            use_gpu: true,
        };
        let clean = dirty.sanitize();
        assert_eq!(clean.preset, "seimbang");
        assert_eq!(clean.resolusi, "");
        assert_eq!(clean.output_dir, r"C:\Temp\Out");
        assert!(clean.use_gpu);
    }
}

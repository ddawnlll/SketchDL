use serde_json::{Value, json};

pub const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
const MAX_ERROR_CHARS: usize = 240;

#[derive(Clone, Debug, Default)]
pub struct Format {
    pub id: String,
    pub ext: String,
    pub height: i64,
    pub vcodec: String,
    pub acodec: String,
    pub size_est: i64,
    pub has_size: bool,
    pub combined: bool,
    pub has_video: bool,
    pub has_audio: bool,
    pub compat: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Inspection {
    pub id: String,
    pub title: String,
    pub duration: Option<i64>,
    pub formats: Vec<Format>,
}

fn mp4_compat(f: &Format) -> bool {
    if f.ext != "mp4" && f.ext != "m4a" {
        return false;
    }
    if f.vcodec.is_empty() && f.acodec.is_empty() {
        return false;
    }
    let v_ok = f.vcodec == "none" || f.vcodec.starts_with("avc") || f.vcodec.starts_with("mp4v");
    let a_ok = f.acodec == "none" || f.acodec.starts_with("mp4a");
    if !v_ok || !a_ok {
        return false;
    }
    if f.vcodec != "none" && f.acodec == "none" && f.ext != "mp4" {
        return false;
    }
    true
}

pub fn parse_inspection(text: &[u8], expected_id: &str) -> Option<Inspection> {
    let root: Value = serde_json::from_slice(text).ok()?;
    if root.get("id")?.as_str()? != expected_id {
        return None;
    }
    let title = root
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let duration = root.get("duration").and_then(Value::as_i64);
    let mut formats = Vec::new();
    if let Some(arr) = root.get("formats").and_then(Value::as_array) {
        for node in arr {
            let fid = match node.get("format_id").and_then(Value::as_str) {
                Some(v) => v,
                None => continue,
            };
            let ext = node.get("ext").and_then(Value::as_str).unwrap_or("");
            let vcodec = node.get("vcodec").and_then(Value::as_str).unwrap_or("");
            let acodec = node.get("acodec").and_then(Value::as_str).unwrap_or("");
            if ext.is_empty() || vcodec.is_empty() || acodec.is_empty() {
                continue;
            }
            let height = node.get("height").and_then(Value::as_i64).unwrap_or(0);
            let mut size_est = 0;
            let mut has_size = false;
            if let Some(v) = node.get("filesize").and_then(Value::as_i64) {
                if v >= 0 {
                    size_est = v;
                    has_size = true;
                }
            }
            if !has_size {
                if let Some(v) = node.get("filesize_approx").and_then(Value::as_i64) {
                    if v >= 0 {
                        size_est = v;
                        has_size = true;
                    }
                }
            }
            let has_video = vcodec != "none";
            let has_audio = acodec != "none";
            let mut f = Format {
                id: fid.to_string(),
                ext: ext.to_string(),
                height,
                vcodec: vcodec.to_string(),
                acodec: acodec.to_string(),
                size_est,
                has_size,
                combined: has_video && has_audio,
                has_video,
                has_audio,
                compat: false,
            };
            f.compat = mp4_compat(&f);
            formats.push(f);
        }
    }
    Some(Inspection {
        id: expected_id.to_string(),
        title,
        duration,
        formats,
    })
}

pub fn formats_to_json(formats: &[Format]) -> String {
    let arr: Vec<Value> = formats
        .iter()
        .map(|f| {
            json!({
                "id": f.id,
                "ext": f.ext,
                "h": f.height,
                "v": f.vcodec,
                "a": f.acodec,
                "size": if f.has_size { Value::from(f.size_est) } else { Value::Null },
                "compat": f.compat,
            })
        })
        .collect();
    Value::Array(arr).to_string()
}

pub fn parse_stored_formats(text: &str) -> Vec<Format> {
    let mut out = Vec::new();
    let arr: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return out,
    };
    let arr = match arr.as_array() {
        Some(a) => a,
        None => return out,
    };
    for node in arr {
        let id = node.get("id").and_then(Value::as_str).unwrap_or("");
        let ext = node.get("ext").and_then(Value::as_str).unwrap_or("");
        let vcodec = node.get("v").and_then(Value::as_str).unwrap_or("");
        let acodec = node.get("a").and_then(Value::as_str).unwrap_or("");
        let h = node.get("h").and_then(Value::as_i64).unwrap_or(0);
        let size = node.get("size").and_then(Value::as_i64);
        let compat = node.get("compat").and_then(Value::as_bool).unwrap_or(false);
        if id.is_empty() || ext.is_empty() {
            continue;
        }
        let has_video = vcodec != "none";
        let has_audio = acodec != "none";
        out.push(Format {
            id: id.to_string(),
            ext: ext.to_string(),
            height: h,
            vcodec: vcodec.to_string(),
            acodec: acodec.to_string(),
            size_est: size.unwrap_or(0),
            has_size: size.is_some(),
            combined: has_video && has_audio,
            has_video,
            has_audio,
            compat,
        });
    }
    out
}

fn better_video(a: &Format, b: &Format) -> bool {
    if a.height != b.height {
        return a.height > b.height;
    }
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb {
        return sa > sb;
    }
    a.id < b.id
}

fn better_audio(a: &Format, b: &Format) -> bool {
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb {
        return sa > sb;
    }
    a.id < b.id
}

fn better_audio_for_video(a: &Format, b: &Format, video_size: i64) -> bool {
    let a_fits = a.has_size && a.size_est <= video_size;
    let b_fits = b.has_size && b.size_est <= video_size;
    if a_fits != b_fits {
        return a_fits;
    }
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb {
        return if a_fits { sa > sb } else { sa < sb };
    }
    a.id < b.id
}

pub fn valid_format_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 24
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'+')
        && id.bytes().filter(|b| *b == b'+').count() <= 1
        && !id.starts_with('+')
        && !id.ends_with('+')
}

#[derive(Clone, Debug)]
pub struct QualityOption {
    pub label: String,
    pub spec: String,
    pub combined: bool,
    pub size_est: i64,
}

/// One row per actual H.264 height, using the same selector as enqueue.
/// Options whose estimated size exceeds `max_bytes` are omitted so the UI
/// cannot offer a download that the worker will immediately reject.
pub fn quality_options(formats: &[Format], max_bytes: i64) -> Vec<QualityOption> {
    let mut heights: Vec<i64> = formats
        .iter()
        .filter(|f| f.compat && f.has_video && f.height > 0)
        .map(|f| f.height)
        .collect();
    heights.sort_unstable();
    heights.dedup();
    heights.reverse();
    let mut out = Vec::new();
    for h in heights {
        let Some((spec, est)) = select_format(formats, h) else {
            continue;
        };
        if max_bytes > 0 && est > max_bytes {
            continue;
        }
        out.push(QualityOption {
            label: format!("{h}p"),
            combined: !spec.contains('+'),
            spec,
            size_est: est,
        });
    }
    out
}

/// Returns (format spec, estimated bytes or -1).
pub fn select_format(formats: &[Format], ceiling: i64) -> Option<(String, i64)> {
    let mut bv: Option<&Format> = None;
    for f in formats {
        if f.compat && f.has_video && f.height > 0 && f.height <= ceiling {
            if bv.is_none() || better_video(f, bv.unwrap()) {
                bv = Some(f);
            }
        }
    }
    let bv = bv?;
    if bv.combined {
        return Some((bv.id.clone(), if bv.has_size { bv.size_est } else { -1 }));
    }
    let mut ba: Option<&Format> = None;
    for f in formats {
        if f.compat && f.has_audio && !f.has_video && f.ext == "m4a" {
            if bv.has_size {
                if ba.is_none() || better_audio_for_video(f, ba.unwrap(), bv.size_est) {
                    ba = Some(f);
                }
            } else if ba.is_none() || better_audio(f, ba.unwrap()) {
                ba = Some(f);
            }
        }
    }
    let ba = ba?;
    let est = if bv.has_size && ba.has_size {
        bv.size_est + ba.size_est
    } else {
        -1
    };
    Some((format!("{}+{}", bv.id, ba.id), est))
}

pub const PROGRESS_MARKER: &str = "skdl-progress|";

pub fn progress_template_arg() -> &'static str {
    "download:skdl-progress|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.format_id)s|%(info.vcodec)s|%(info.acodec)s"
}

#[derive(Clone, Debug, Default)]
pub struct Progress {
    pub downloaded: i64,
    pub total: Option<i64>,
    pub estimate: Option<i64>,
    pub speed: Option<i64>,
    pub eta: Option<i64>,
    pub format_id: String,
    pub has_video: bool,
    pub has_audio: bool,
}

fn parse_number(tok: &str) -> Option<i64> {
    let tok = tok.trim();
    if tok.is_empty()
        || matches!(
            tok,
            "NA" | "N/A" | "None" | "none" | "unknown" | "nan" | "NaN"
        )
    {
        return None;
    }
    let bytes = tok.as_bytes();
    let mut i = 0usize;
    let mut v: i64 = 0;
    let mut digits = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        let d = (bytes[i] - b'0') as i64;
        v = v.checked_mul(10)?.checked_add(d)?;
        digits += 1;
        i += 1;
    }
    if digits == 0 {
        return None;
    }
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1;
        let mut frac = 0;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
            frac += 1;
        }
        if frac == 0 {
            return None;
        }
    }
    if i != bytes.len() {
        return None;
    }
    Some(v)
}

pub fn parse_progress(line: &str) -> Option<Progress> {
    let line = line.trim_end_matches(['\r', '\n']).trim();
    let body = line.strip_prefix(PROGRESS_MARKER)?;
    let parts: Vec<&str> = body.split('|').collect();
    if parts.len() != 8 {
        return None;
    }
    let downloaded = parse_number(parts[0])?;
    let total = parse_number(parts[1]);
    let estimate = parse_number(parts[2]);
    let speed = parse_number(parts[3]);
    let eta = parse_number(parts[4]);
    let fid = parts[5].trim().to_string();
    let vcodec = parts[6].trim();
    let acodec = parts[7].trim();
    Some(Progress {
        downloaded,
        total,
        estimate,
        speed,
        eta,
        format_id: fid,
        has_video: !vcodec.is_empty() && vcodec != "NA" && vcodec != "none",
        has_audio: !acodec.is_empty() && acodec != "NA" && acodec != "none",
    })
}

#[derive(Clone, Debug, Default)]
pub struct Component {
    pub id: String,
    pub downloaded: i64,
    pub total: Option<i64>,
    pub has_video: bool,
    pub has_audio: bool,
}

#[derive(Clone, Debug)]
pub struct ProgressTracker {
    pub comps: Vec<Component>,
    pub expected: usize,
    pub any: bool,
    pub speed: Option<i64>,
    pub eta: Option<i64>,
    pub current: usize,
}

impl ProgressTracker {
    pub fn new(expected: usize) -> Self {
        Self {
            comps: Vec::new(),
            expected: expected.max(1),
            any: false,
            speed: None,
            eta: None,
            current: 0,
        }
    }

    fn component_index(&mut self, p: &Progress) -> usize {
        for (i, c) in self.comps.iter().enumerate() {
            if c.id == p.format_id {
                return i;
            }
        }
        if self.comps.len() < 4 {
            self.comps.push(Component {
                id: p.format_id.clone(),
                downloaded: 0,
                total: None,
                has_video: p.has_video,
                has_audio: p.has_audio,
            });
            self.comps.len() - 1
        } else {
            0
        }
    }

    pub fn feed(&mut self, p: &Progress) {
        if p.format_id.is_empty() || p.format_id == "NA" {
            // Some extractors/mocks do not expose info.format_id in the
            // progress context. Treat the stream as one component rather
            // than waiting forever for a second id to appear.
            self.expected = 1;
        }
        if !p.has_video && !p.has_audio && p.format_id.is_empty() && !self.comps.is_empty() {
            self.current = 0;
        } else {
            self.current = self.component_index(p);
        }
        let c = &mut self.comps[self.current];
        if p.downloaded > c.downloaded {
            c.downloaded = p.downloaded;
        }
        if p.has_video {
            c.has_video = true;
        }
        if p.has_audio {
            c.has_audio = true;
        }
        if p.total.is_some() {
            c.total = p.total;
        } else if p.estimate.is_some() {
            c.total = p.estimate;
        }
        if p.speed.is_some() {
            self.speed = p.speed;
        }
        if p.eta.is_some() {
            self.eta = p.eta;
        }
        self.any = true;
    }

    pub fn downloaded(&self) -> i64 {
        self.comps.iter().map(|c| c.downloaded).sum()
    }

    pub fn total(&self) -> Option<i64> {
        if self.comps.len() < self.expected {
            return None;
        }
        let mut sum = 0;
        for c in &self.comps {
            sum += c.total?;
        }
        if self.comps.is_empty() {
            None
        } else {
            Some(sum)
        }
    }

    pub fn stage(&self) -> &'static str {
        if let Some(total) = self.total() {
            if self.downloaded() >= total {
                return "merging";
            }
        }
        if let Some(c) = self.comps.get(self.current) {
            if c.has_video && !c.has_audio {
                return "downloading-video";
            }
            if c.has_audio && !c.has_video {
                return "downloading-audio";
            }
        }
        "downloading"
    }
}

pub fn classify_error(stderr_tail: &str) -> (String, String) {
    let msg: String = stderr_tail
        .chars()
        .map(|c| if c == '\n' { ' ' } else { c })
        .collect();
    let code = if msg.contains("Sign in to confirm") {
        "BOT_CHECK"
    } else if msg.contains("Private video") {
        "PRIVATE"
    } else if msg.contains("Requested format") {
        "FORMAT_UNAVAILABLE"
    } else if msg.contains("Video unavailable") || msg.contains("is no longer available") {
        "UNAVAILABLE"
    } else if msg.contains("Sign in") {
        "AGE_RESTRICTED"
    } else if msg.contains("HTTP Error 403") || msg.contains("HTTP Error 429") {
        "NETWORK"
    } else if msg.contains("no video") || msg.contains("No formats") {
        "NO_FORMATS"
    } else if !msg.is_empty() {
        "DOWNLOAD_FAILED"
    } else {
        ""
    };
    let detail: String = msg.chars().take(MAX_ERROR_CHARS).collect();
    (code.to_string(), detail)
}

#[cfg(test)]
mod tests {
    use super::valid_format_id;

    #[test]
    fn split_format_specs_are_valid() {
        assert!(valid_format_id("18"));
        assert!(valid_format_id("299+140"));
        assert!(valid_format_id("160+599"));
        assert!(!valid_format_id("+140"));
        assert!(!valid_format_id("299+"));
        assert!(!valid_format_id("299++140"));
        assert!(!valid_format_id("299+140+251"));
        assert!(!valid_format_id("299; rm -rf /"));
    }
}

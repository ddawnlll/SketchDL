use url::Url;

#[derive(Debug, PartialEq, Eq)]
pub enum InputError {
    BadHost,
    BadId,
}

pub fn valid_id(id: &str) -> bool {
    id.len() == 11
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Strict YouTube URL validation. Returns (video_id, canonical URL).
pub fn parse_youtube_url(raw: &str) -> Result<(String, String), InputError> {
    let u = Url::parse(raw).map_err(|_| InputError::BadHost)?;
    if u.scheme() != "https" {
        return Err(InputError::BadHost);
    }
    let host = u.host_str().unwrap_or("").to_ascii_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host);
    let mut id: Option<String> = None;
    match host {
        "youtu.be" => {
            let p = u.path().trim_start_matches('/');
            if !p.is_empty() && !p.contains('/') {
                id = Some(p.to_string());
            }
        }
        "youtube.com" | "m.youtube.com" => {
            let path = u.path();
            if path == "/watch" {
                for (k, v) in u.query_pairs() {
                    if k == "v" {
                        id = Some(v.into_owned());
                        break;
                    }
                }
            } else if let Some(rest) = path.strip_prefix("/shorts/") {
                if !rest.is_empty() && !rest.contains('/') {
                    id = Some(rest.to_string());
                }
            } else if let Some(rest) = path.strip_prefix("/embed/") {
                if !rest.is_empty() && !rest.contains('/') {
                    id = Some(rest.to_string());
                }
            }
        }
        _ => return Err(InputError::BadHost),
    }
    let id = id.ok_or(InputError::BadId)?;
    if !valid_id(&id) {
        return Err(InputError::BadId);
    }
    let canonical = format!("https://www.youtube.com/watch?v={id}");
    Ok((id, canonical))
}

pub fn valid_job_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

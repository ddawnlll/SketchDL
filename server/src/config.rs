use std::env;

#[derive(Clone, Debug)]
pub struct Config {
    pub db: String,
    pub data: String,
    pub listen: String,
    pub ytdlp: String,
    pub ffmpeg: String,
    pub ffprobe: String,
    pub deno: String,
    pub ejs_parent: Option<String>,
    pub bgutil_home: Option<String>,
    pub job: Option<String>,
    pub out: Option<String>,
    pub secure_cookies: bool,
    pub trust_proxy: bool,
    pub session_days: i64,
    pub retain_hours: i64,
    pub max_download_bytes: i64,
    pub max_duration: i64,
    pub inspect_timeout: u64,
    pub download_timeout: u64,
    pub min_free_bytes: i64,
    pub max_active: i64,
    pub concurrent_fragments: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            db: "data/sketchdl.db".into(),
            data: "data".into(),
            listen: "127.0.0.1:8087".into(),
            ytdlp: "/usr/local/bin/yt-dlp".into(),
            ffmpeg: "/usr/bin/ffmpeg".into(),
            ffprobe: "/usr/bin/ffprobe".into(),
            deno: "/usr/local/bin/deno".into(),
            ejs_parent: None,
            bgutil_home: None,
            job: None,
            out: None,
            secure_cookies: true,
            trust_proxy: false,
            session_days: 30,
            retain_hours: 12,
            max_download_bytes: 2 * 1024 * 1024 * 1024,
            max_duration: 4 * 60 * 60,
            inspect_timeout: 60,
            download_timeout: 30 * 60,
            min_free_bytes: 20 * 1024 * 1024 * 1024,
            max_active: 5,
            concurrent_fragments: 4,
        }
    }
}

pub fn usage() -> &'static str {
    "SketchDL (Rust/Axum)\n  sketchdl serve [--db PATH] [--data DIR] [--listen 127.0.0.1:8087]\n                   [--ytdlp PATH] [--ffmpeg PATH] [--ffprobe PATH] [--deno PATH]\n                   [--ejs-parent DIR] [--bgutil-home DIR] [--insecure-cookies] [--trust-proxy]\n                   [--retain-hours N] [--max-download-bytes N] [--max-duration S]\n                   [--inspect-timeout S] [--download-timeout S] [--min-free-bytes N]\n                   [--max-active N] [--concurrent-fragments N]\n  sketchdl admin set-password [--db PATH]\n  sketchdl admin backup [--db PATH] --out PATH\n  sketchdl admin integrity [--db PATH]\n"
}

fn parse_i64(s: &str) -> Option<i64> {
    s.parse::<i64>().ok()
}

pub fn parse(args: &[String], start: usize) -> Result<Config, String> {
    let mut c = Config::default();
    let mut i = start;
    while i < args.len() {
        let a = &args[i];
        let next = |i: &mut usize| -> Result<String, String> {
            if *i + 1 >= args.len() {
                return Err(format!("missing value for {a}"));
            }
            *i += 2;
            Ok(args[*i - 1].clone())
        };
        match a.as_str() {
            "--db" => c.db = next(&mut i)?,
            "--data" => c.data = next(&mut i)?,
            "--listen" => c.listen = next(&mut i)?,
            "--ytdlp" => c.ytdlp = next(&mut i)?,
            "--ffmpeg" => c.ffmpeg = next(&mut i)?,
            "--ffprobe" => c.ffprobe = next(&mut i)?,
            "--deno" => c.deno = next(&mut i)?,
            "--ejs-parent" => c.ejs_parent = Some(next(&mut i)?),
            "--bgutil-home" => c.bgutil_home = Some(next(&mut i)?),
            "--job" => c.job = Some(next(&mut i)?),
            "--out" => c.out = Some(next(&mut i)?),
            "--insecure-cookies" => {
                c.secure_cookies = false;
                i += 1;
            }
            "--trust-proxy" => {
                c.trust_proxy = true;
                i += 1;
            }
            "--retain-hours" => {
                c.retain_hours = parse_i64(&next(&mut i)?).ok_or("bad --retain-hours")?
            }
            "--max-download-bytes" => {
                c.max_download_bytes =
                    parse_i64(&next(&mut i)?).ok_or("bad --max-download-bytes")?
            }
            "--max-duration" => {
                c.max_duration = parse_i64(&next(&mut i)?).ok_or("bad --max-duration")?
            }
            "--inspect-timeout" => {
                c.inspect_timeout = parse_i64(&next(&mut i)?).ok_or("bad --inspect-timeout")? as u64
            }
            "--download-timeout" => {
                c.download_timeout =
                    parse_i64(&next(&mut i)?).ok_or("bad --download-timeout")? as u64
            }
            "--min-free-bytes" => {
                c.min_free_bytes = parse_i64(&next(&mut i)?).ok_or("bad --min-free-bytes")?
            }
            "--max-active" => c.max_active = parse_i64(&next(&mut i)?).ok_or("bad --max-active")?,
            "--concurrent-fragments" => {
                let v = parse_i64(&next(&mut i)?).ok_or("bad --concurrent-fragments")?;
                if (1..=16).contains(&v) {
                    c.concurrent_fragments = v as u32;
                }
            }
            _ => return Err(format!("unknown or incomplete argument: {a}")),
        }
    }
    Ok(c)
}

pub enum Command {
    Serve(Config),
    AdminSetPassword(Config),
    AdminBackup(Config),
    AdminIntegrity(Config),
    Help,
}

pub fn parse_command() -> Result<Command, String> {
    let args: Vec<String> = env::args().collect();
    let command = args.get(1).map(String::as_str).unwrap_or("serve");
    match command {
        "serve" => Ok(Command::Serve(parse(&args, 2)?)),
        "admin" => {
            let sub = args.get(2).map(String::as_str).unwrap_or("");
            match sub {
                "set-password" => Ok(Command::AdminSetPassword(parse(&args, 3)?)),
                "backup" => Ok(Command::AdminBackup(parse(&args, 3)?)),
                "integrity" => Ok(Command::AdminIntegrity(parse(&args, 3)?)),
                _ => Err(usage().to_string()),
            }
        }
        "--help" | "help" => Ok(Command::Help),
        _ => Err(format!("unknown command: {command}\n{}", usage())),
    }
}

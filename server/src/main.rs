mod auth;
mod config;
mod db;
mod input;
mod jobs;
mod media;
mod proc;
mod state;
mod views;
mod web;
mod ytdlp;

use config::Command;
use std::io::Read;
use std::path::{Path, PathBuf};

fn absolute_dir(path: &str) -> Result<String, String> {
    std::fs::create_dir_all(path).map_err(|e| format!("create {path}: {e}"))?;
    std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().to_string())
        .map_err(|e| format!("canonicalize {path}: {e}"))
}

fn absolute_file(path: &str) -> Result<String, String> {
    let p = Path::new(path);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
        let parent = std::fs::canonicalize(parent)
            .map_err(|e| format!("canonicalize {}: {e}", parent.display()))?;
        let name = p
            .file_name()
            .ok_or_else(|| format!("invalid path {path}"))?;
        Ok(parent.join(name).to_string_lossy().to_string())
    } else {
        Ok(p.to_string_lossy().to_string())
    }
}

fn read_password_stdin() -> Result<String, String> {
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .map_err(|e| format!("read stdin: {e}"))?;
    let pw = buf.trim_end_matches(['\n', '\r']);
    if !auth::valid_password_bytes(pw) {
        return Err("password must be 12-1024 bytes of valid UTF-8".into());
    }
    Ok(pw.to_string())
}

fn main() {
    let cmd = match config::parse_command() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    match cmd {
        Command::Help => {
            print!("{}", config::usage());
        }
        Command::AdminSetPassword(mut cfg) => {
            let pw = match read_password_stdin() {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(2);
                }
            };
            cfg.db = match absolute_file(&cfg.db) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            };
            let db = match db::Db::open(&cfg.db) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("open database: {e}");
                    std::process::exit(1);
                }
            };
            let hash = match auth::hash_password(&pw) {
                Some(h) => h,
                None => {
                    eprintln!("could not hash password");
                    std::process::exit(1);
                }
            };
            if let Err(e) = db.set_owner_hash(&hash, db::now()) {
                eprintln!("store password: {e}");
                std::process::exit(1);
            }
            println!("password set");
        }
        Command::AdminBackup(mut cfg) => {
            cfg.db = match absolute_file(&cfg.db) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            };
            let out = match cfg.out {
                Some(o) => o,
                None => {
                    eprintln!("--out PATH is required");
                    std::process::exit(2);
                }
            };
            if PathBuf::from(&out).exists() {
                let _ = std::fs::remove_file(&out);
            }
            let db = match db::Db::open(&cfg.db) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("open database: {e}");
                    std::process::exit(1);
                }
            };
            match db.backup_to(&out) {
                Ok(()) => println!("backup written to {out}"),
                Err(e) => {
                    eprintln!("backup failed: {e}");
                    std::process::exit(1);
                }
            }
        }
        Command::AdminIntegrity(mut cfg) => {
            cfg.db = match absolute_file(&cfg.db) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            };
            let db = match db::Db::open(&cfg.db) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("open database: {e}");
                    std::process::exit(1);
                }
            };
            if db.integrity() {
                println!("ok");
            } else {
                eprintln!("integrity check failed");
                std::process::exit(1);
            }
        }
        Command::Serve(mut cfg) => {
            if let Err(e) = run_server(&mut cfg) {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    }
}

fn run_server(cfg: &mut config::Config) -> Result<(), String> {
    cfg.data = absolute_dir(&cfg.data)?;
    cfg.db = absolute_file(&cfg.db)?;
    let state = state::AppState::new(cfg.clone())?;
    eprintln!(
        "sketchdl: listening on {} data={} db={}",
        cfg.listen, cfg.data, cfg.db
    );
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("runtime: {e}"))?;
    rt.block_on(web::run(state))
}

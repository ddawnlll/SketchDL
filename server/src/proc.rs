use std::io;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub struct Tail {
    buf: Vec<u8>,
    cap: usize,
}

impl Tail {
    pub fn new(cap: usize) -> Self {
        Self {
            buf: Vec::with_capacity(cap.min(64 * 1024)),
            cap,
        }
    }

    pub fn push_str(&mut self, s: &str) {
        let bytes = s.as_bytes();
        if bytes.len() >= self.cap {
            self.buf.clear();
            self.buf.extend_from_slice(&bytes[bytes.len() - self.cap..]);
            return;
        }
        if self.buf.len() + bytes.len() > self.cap {
            let drop = self.buf.len() + bytes.len() - self.cap;
            self.buf.drain(0..drop);
        }
        self.buf.extend_from_slice(bytes);
    }

    pub fn push_bytes(&mut self, bytes: &[u8]) {
        if bytes.len() >= self.cap {
            self.buf.clear();
            self.buf.extend_from_slice(&bytes[bytes.len() - self.cap..]);
            return;
        }
        if self.buf.len() + bytes.len() > self.cap {
            let drop = self.buf.len() + bytes.len() - self.cap;
            self.buf.drain(0..drop);
        }
        self.buf.extend_from_slice(bytes);
    }

    pub fn as_str(&self) -> String {
        String::from_utf8_lossy(&self.buf).to_string()
    }
}

/// Put the child in its own process group so cancellation can kill ffmpeg
/// and Deno descendants too.
pub fn isolate_process_group(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        cmd.as_std_mut().pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

pub fn kill_group(pid: u32) {
    if pid == 0 {
        return;
    }
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
        libc::kill(pid as i32, libc::SIGKILL);
    }
}

pub struct Captured {
    pub stdout: Vec<u8>,
    pub stderr_tail: String,
    pub code: Option<i32>,
    pub timed_out: bool,
    pub too_large: bool,
    pub spawn_error: Option<String>,
}

pub async fn run_capture(cmd: &mut Command, timeout: Duration, stdout_cap: usize) -> Captured {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    isolate_process_group(cmd);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return Captured {
                stdout: Vec::new(),
                stderr_tail: String::new(),
                code: None,
                timed_out: false,
                too_large: false,
                spawn_error: Some(e.to_string()),
            };
        }
    };
    let pid = child.id().unwrap_or(0);
    let mut stdout = match child.stdout.take() {
        Some(s) => BufReader::new(s),
        None => {
            return Captured {
                stdout: Vec::new(),
                stderr_tail: String::new(),
                code: None,
                timed_out: false,
                too_large: false,
                spawn_error: Some("stdout unavailable".into()),
            };
        }
    };
    let mut stderr = BufReader::new(child.stderr.take().expect("stderr piped"));
    let mut out = Vec::with_capacity(64 * 1024);
    let mut err = Tail::new(16 * 1024);
    let mut out_open = true;
    let mut err_open = true;
    let mut too_large = false;
    let deadline = tokio::time::Instant::now() + timeout;
    let mut out_chunk = vec![0u8; 16 * 1024];
    let mut err_chunk = vec![0u8; 16 * 1024];
    let mut timed_out = false;
    while out_open || err_open {
        tokio::select! {
            n = read_chunk(&mut stdout, &mut out_chunk), if out_open => {
                match n {
                    Ok(0) => out_open = false,
                    Ok(n) => {
                        if out.len() + n > stdout_cap {
                            too_large = true;
                            kill_group(pid);
                            break;
                        }
                        out.extend_from_slice(&out_chunk[..n]);
                    }
                    Err(_) => out_open = false,
                }
            }
            n = read_chunk(&mut stderr, &mut err_chunk), if err_open => {
                match n {
                    Ok(0) => err_open = false,
                    Ok(n) => err.push_bytes(&err_chunk[..n]),
                    Err(_) => err_open = false,
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                timed_out = true;
                kill_group(pid);
                break;
            }
        }
    }
    let code = match tokio::time::timeout(Duration::from_secs(5), child.wait()).await {
        Ok(Ok(status)) => status.code(),
        _ => None,
    };
    Captured {
        stdout: out,
        stderr_tail: err.as_str(),
        code,
        timed_out,
        too_large,
        spawn_error: None,
    }
}

async fn read_chunk<R: tokio::io::AsyncRead + Unpin>(
    r: &mut R,
    buf: &mut [u8],
) -> io::Result<usize> {
    use tokio::io::AsyncReadExt;
    r.read(buf).await
}

/// Split a stream into lines, returning None at EOF.
pub struct LineReader<R> {
    inner: BufReader<R>,
}

impl<R: tokio::io::AsyncRead + Unpin> LineReader<R> {
    pub fn new(r: R) -> Self {
        Self {
            inner: BufReader::new(r),
        }
    }

    pub async fn next_line(&mut self) -> io::Result<Option<String>> {
        let mut buf = Vec::new();
        let n = self.inner.read_until(b'\n', &mut buf).await?;
        if n == 0 {
            return Ok(None);
        }
        while buf.last().is_some_and(|b| *b == b'\n' || *b == b'\r') {
            buf.pop();
        }
        Ok(Some(String::from_utf8_lossy(&buf).to_string()))
    }
}

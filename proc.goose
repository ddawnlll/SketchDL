// Subprocess wrapper over vendor/proc.c. This is the ONLY place that talks
// to child processes. Arguments are passed as a structured argv (never a
// shell string). The child runs in its own session; killing its process
// group kills yt-dlp plus its deno/ffmpeg descendants.
namespace proc;

import std;

extern fn sk_spawn3(exe: const u8&, blob: const u8&, offsets: const i32&, n: i32, cwd: const u8&, pid_out: i32&, out_fd: i32&, err_fd: i32&) -> i32 = "sk_spawn3";
extern fn sk_spawn4(exe: const u8&, blob: const u8&, offsets: const i32&, n: i32, cwd: const u8&, env_blob: const u8&, pid_out: i32&, out_fd: i32&, err_fd: i32&) -> i32 = "sk_spawn4";
extern fn sk_spawn_null(exe: const u8&, blob: const u8&, offsets: const i32&, n: i32, cwd: const u8&, pid_out: i32&) -> i32 = "sk_spawn_null";
extern fn sk_free_bytes(path: const u8&) -> i64 = "sk_free_bytes"; // C: long long
extern fn sk_poll_read(fd: i32, buf: u8&, max: i32, timeout_ms: i32) -> i32 = "sk_poll_read";
extern fn sk_wait(pid: i32, exit_code: i32&) -> i32 = "sk_wait";
extern fn sk_try_wait(pid: i32, exit_code: i32&) -> i32 = "sk_try_wait";
extern fn sk_kill_group(pid: i32, sig: i32) -> i32 = "sk_kill_group";
extern fn sk_close_fd(fd: i32) -> i32 = "sk_close_fd";
extern fn sk_mkdir_p(path: const u8&) -> i32 = "sk_mkdir_p";
extern fn sk_rm_rf(path: const u8&) -> i32 = "sk_rm_rf";
extern fn sk_rename(from: const u8&, to: const u8&) -> i32 = "sk_rename";
extern fn sk_unlink(path: const u8&) -> i32 = "sk_unlink";
extern fn sk_file_size(path: const u8&) -> i64 = "sk_file_size";
extern fn sk_access_x(path: const u8&) -> i32 = "sk_access_x";
extern fn sk_fsync_path(path: const u8&) -> i32 = "sk_fsync_path";
extern fn sk_open_read(path: const u8&) -> i32 = "sk_open_read";
extern fn sk_pread(fd: i32, buf: u8&, max: i32, offset: i64) -> i32 = "sk_pread";
extern fn sk_sendfile(out_fd: i32, in_fd: i32, offset: i64, count: i64) -> i32 = "sk_sendfile";
extern fn sk_self_exe(buf: u8&, max: i32) -> i32 = "sk_self_exe";
extern fn sk_sleep_ms(ms: i32) -> i32 = "sk_sleep_ms";

// Compares up to n bytes starting at two offsets of the same buffer.
fn sleep_ms(ms: i64) {
    sk_sleep_ms(ms as i32);
}

fn cstr(s: u8[:], out: u8[>..]&) {
    out.append(s);
    out.push(0);
}

fn argv_push(blob: u8[>..]&, offs: i32[>..]&, s: u8[:]) {
    offs.push(blob.len as i32);
    blob.append(s);
    blob.push(0);
}

fn mkdir_p(path: u8[:]) -> bool {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_mkdir_p(p[0]) == 0;
}

fn rm_rf(path: u8[:]) -> bool {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_rm_rf(p[0]) == 0;
}

fn rename_file(from_s: u8[:], to_s: u8[:]) -> bool {
    var f: u8[>..] = [];
    var t: u8[>..] = [];
    cstr(from_s, f);
    cstr(to_s, t);
    return sk_rename(f[0], t[0]) == 0;
}

fn unlink(path: u8[:]) -> bool {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_unlink(p[0]) == 0;
}

fn file_size(path: u8[:]) -> i64 {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_file_size(p[0]);
}

fn access_x(path: u8[:]) -> bool {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_access_x(p[0]) == 0;
}

fn fsync_path(path: u8[:]) {
    var p: u8[>..] = [];
    cstr(path, p);
    sk_fsync_path(p[0]);
}

fn self_exe(out: u8[>..]&) -> bool {
    out.resize(4096, 0);
    let n = sk_self_exe(out[0], 4096);
    if n < 0 { out.resize(0); return false; }
    out.resize(n);
    return true;
}

// A running child: separate stdout/stderr read ends.
struct Child { pid: i64, out_fd: i64, err_fd: i64 }

// Spawn. cwd "" inherits the parent's working directory. False on failure.
fn spawn(exe: u8[:], blob: u8[>..]&, offs: i32[>..]&, cwd: u8[:], child: Child&) -> bool {
    // argv must contain at least the exe as argv[0].
    if offs.len < 1 { return false; }
    var exe_c: u8[>..] = [];
    cstr(exe, exe_c);
    var cwd_c: u8[>..] = [];
    cstr(cwd, cwd_c);
    var pid: i32 = 0;
    var out_fd: i32 = 0;
    var err_fd: i32 = 0;
    let n = offs.len as i32;
    // The C side uses blob/offs only during this call, and it runs before
    // the first fork, so passing them by reference is safe.
    let rc = sk_spawn3(exe_c[0], blob[0], offs[0], n, cwd_c[0], pid, out_fd, err_fd);
    if rc != 0 { return false; }
    child.pid = pid;
    child.out_fd = out_fd;
    child.err_fd = err_fd;
    return true;
}

// Read from one pipe with a poll timeout. Returns: >0 bytes (appended to
// `out`), 0 EOF, -1 timeout, -2 error.
fn poll_read(fd: i64, buf: u8[65536]&, timeout_ms: i64) -> i64 {
    let r = sk_poll_read(fd as i32, buf[0], 65536, timeout_ms as i32);
    if r <= 0 { return r; }
    return r;
}

fn try_wait(pid: i64) -> i64, i64 {
    var ec: i32 = -1;
    let r = sk_try_wait(pid as i32, ec);
    return ec, r;
}

fn wait(pid: i64) -> i64, bool {
    var ec: i32 = -1;
    let r = sk_wait(pid as i32, ec);
    return ec, r == 0;
}

fn kill_group(pid: i64, sig: i64) -> bool {
    return sk_kill_group(pid as i32, sig as i32) == 0;
}

fn close_fd(fd: i64) {
    sk_close_fd(fd as i32);
}

fn free_bytes(path: u8[:]) -> i64 {
    var p: u8[>..] = [];
    cstr(path, p);
    return sk_free_bytes(p[0]);
}

// Spawn with extra environment entries ("KEY=VALUE" strings, newline
// separated for the C side). Empty entries = inherit the environment.
// Fire-and-forget spawn (supervisor workers): stdout/stderr go to
// /dev/null in the child; no pipes, no SIGPIPE, exit code via waitpid.
fn spawn_null(exe: u8[:], blob: u8[>..]&, offs: i32[>..]&, cwd: u8[:], child: Child&) -> bool {
    if offs.len < 1 { return false; }
    var exe_c: u8[>..] = [];
    cstr(exe, exe_c);
    var cwd_c: u8[>..] = [];
    cstr(cwd, cwd_c);
    var pid: i32 = 0;
    let rc = sk_spawn_null(exe_c[0], blob[0], offs[0], offs.len as i32, cwd_c[0], pid);
    if rc != 0 { return false; }
    child.pid = pid;
    child.out_fd = -1;
    child.err_fd = -1;
    return true;
}

fn spawn_env(exe: u8[:], blob: u8[>..]&, offs: i32[>..]&, cwd: u8[:], env: u8[:], child: Child&) -> bool {
    if offs.len < 1 { return false; }
    var exe_c: u8[>..] = [];
    cstr(exe, exe_c);
    var cwd_c: u8[>..] = [];
    cstr(cwd, cwd_c);
    var env_c: u8[>..] = [];
    if env.len == 0 {
        env_c.push(0);
    } else {
        env_c.append(env);
        env_c.push(10);
        env_c.push(0);
    }
    var pid: i32 = 0;
    var out_fd: i32 = 0;
    var err_fd: i32 = 0;
    let n = offs.len as i32;
    let rc = sk_spawn4(exe_c[0], blob[0], offs[0], n, cwd_c[0], env_c[0], pid, out_fd, err_fd);
    if rc != 0 { return false; }
    child.pid = pid;
    child.out_fd = out_fd;
    child.err_fd = err_fd;
    return true;
}

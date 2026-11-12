// Phase 0 probe: spawn a child process from Goose via C interop,
// read its merged stdout+stderr, wait, and report the exit code.
// If this compiles and runs, the whole SketchDL download engine is feasible:
// yt-dlp is just another argv built the same way.

import std;
import os;

extern fn sk_spawn2(exe: const u8&, blob: const u8&, offsets: const i32&, n: i32, cwd: const u8&, pid_out: i32&, out_fd: i32&) -> i32 = "sk_spawn2";
extern fn sk_poll_read(fd: i32, buf: u8&, max: i32, timeout_ms: i32) -> i32 = "sk_poll_read";
extern fn sk_wait(pid: i32, exit_code: i32&) -> i32 = "sk_wait";
extern fn sk_try_wait(pid: i32, exit_code: i32&) -> i32 = "sk_try_wait";
extern fn sk_kill_group(pid: i32, sig: i32) -> i32 = "sk_kill_group";
extern fn sk_mkdir_p(path: const u8&) -> i32 = "sk_mkdir_p";
extern fn sk_rm_rf(path: const u8&) -> i32 = "sk_rm_rf";
extern fn sk_file_size(path: const u8&) -> i64 = "sk_file_size";
extern fn sk_access_x(path: const u8&) -> i32 = "sk_access_x";
extern fn sk_self_exe(buf: u8&, max: i32) -> i32 = "sk_self_exe";
extern fn sk_rename(from: const u8&, to: const u8&) -> i32 = "sk_rename";
extern fn sk_unlink(path: const u8&) -> i32 = "sk_unlink";

// Append one NUL-terminated string to a packed argv blob.
fn pack_arg(blob: u8[>..]&, offs: i32[>..]&, s: u8[:]) {
    offs.push(blob.len as i32);
    blob.append(s);
    blob.push(0);
}

fn cstr(s: u8[:], out: u8[>..]&) {
    out.append(s);
    out.push(0);
}

// Run argv (argv[0] == exe path) and capture merged output.
// Prints child output and exit code; returns exit code (127 on spawn failure).
fn run_capture(exe: const u8[:], args: const u8[:][>..]) -> i64 {
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    pack_arg(blob, offs, exe);
    for a in args { pack_arg(blob, offs, a); }
    var exe_c: u8[>..] = [];
    cstr(exe, exe_c);
    var cwd_c: u8[>..] = [];
    cwd_c.push(0); // inherit cwd
    var pid: i32 = 0;
    var fd: i32 = 0;
    let n = (offs.len) as i32;
    let rc = sk_spawn2(exe_c[0], blob[0], offs[0], n, cwd_c[0], pid, fd);
    if rc != 0 {
        print("SPAWN FAILED rc=", rc);
        return 127;
    }
    print("spawned pid=", pid, " fd=", fd);
    var buf: u8[65536] = [0; 65536];
    var total = 0;
    var out: u8[>..] = [];
    var rounds = 0;
    loop {
        rounds += 1;
        if rounds > 1000 { print("read loop guard tripped"); break; }
        let r = sk_poll_read(fd, buf[0], 65536, 500);
        if r == 0 { break; } // EOF
        if r > 0 {
            total += r;
            out.append(buf[..(r as i64)]);
        }
        // r == -1 (timeout): loop again
        if r < -1 { print("read error r=", r); break; }
    }
    var exit_code: i32 = -1;
    let wrc = sk_wait(pid, exit_code);
    print("child output (", total, " bytes): ", out);
    print("wait rc=", wrc, " exit_code=", exit_code);
    return exit_code;
}

fn main() {
    // 1. /bin/echo
    var a1: const u8[:][>..] = [];
    a1.push("hello from goose");
    let e1 = run_capture("/bin/echo", copy(a1));
    if e1 != 0 { print("FAIL echo exit"); exit(1); }

    // 2. failing command with stderr text + exit 3
    var a2: const u8[:][>..] = [];
    var script: u8[>..] = [];
    script.append("import sys; print('line one'); print('boom on stderr', file=sys.stderr); sys.exit(3)");
    a2.push("-c");
    a2.push(script);
    let e2 = run_capture("/usr/bin/python3", copy(a2));
    if e2 != 3 { print("FAIL python exit != 3"); exit(1); }

    // 3. Missing executable -> child _exit(127)
    var a3: const u8[:][>..] = [];
    let e3 = run_capture("/nonexistent/binary", copy(a3));
    if e3 != 127 { print("FAIL missing exe exit != 127"); exit(1); }

    // 4. mkdir -p + file size + rename + rm -rf
    var d: u8[>..] = [];
    cstr("/tmp/sketchdl-probe/a/b", d);
    if sk_mkdir_p(d[0]) != 0 { print("FAIL mkdir_p"); exit(1); }
    var f: u8[>..] = [];
    cstr("/tmp/sketchdl-probe/file.txt", f);
    write_file("/tmp/sketchdl-probe/file.txt", "hello probe");
    var sz = sk_file_size(f[0]);
    print("file_size=", sz);
    if sz != 11 { print("FAIL file size"); exit(1); }
    var g: u8[>..] = [];
    cstr("/tmp/sketchdl-probe/renamed.txt", g);
    if sk_rename(f[0], g[0]) != 0 { print("FAIL rename"); exit(1); }
    if sk_access_x(g[0]) == 0 { print("FAIL access_x should fail for non-exe"); exit(1); }
    if sk_rm_rf(d[0]) != 0 { print("FAIL rm_rf"); exit(1); }
    if !file_exists("/tmp/sketchdl-probe/renamed.txt") {
        print("FAIL rm_rf deleted outside its subtree");
        exit(1);
    }
    if file_exists("/tmp/sketchdl-probe/a/b/file.txt") {
        print("FAIL rm_rf left subtree behind");
        exit(1);
    }

    // 5. self exe path
    var selfexe: u8[4096] = [0; 4096];
    let sl = sk_self_exe(selfexe[0], 4096);
    print("self_exe len=", sl, " path=", selfexe[..(sl as i64)]);

    // 6. kill test: spawn a sleep, SIGKILL the group, reap.
    var a6: const u8[:][>..] = [];
    a6.push("30");
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    pack_arg(blob, offs, "/bin/sleep");
    for a in a6 { pack_arg(blob, offs, a); }
    var exe6: u8[>..] = [];
    cstr("/bin/sleep", exe6);
    var cwd6: u8[>..] = [];
    cwd6.push(0);
    var pid6: i32 = 0;
    var fd6: i32 = 0;
    if sk_spawn2(exe6[0], blob[0], offs[0], offs.len as i32, cwd6[0], pid6, fd6) != 0 {
        print("FAIL sleep spawn");
        exit(1);
    }
    var st6: i32 = -1;
    let tw = sk_try_wait(pid6, st6);
    if tw != 0 { print("FAIL sleep should be running, try_wait=", tw); exit(1); }
    if sk_kill_group(pid6, 9) != 0 { print("FAIL kill_group"); exit(1); }
    var ec6: i32 = -1;
    if sk_wait(pid6, ec6) != 0 { print("FAIL wait after kill"); exit(1); }
    print("killed sleep pid=", pid6, " exit_code=", ec6, " (expect 137)");

    print("ALL PROBE CHECKS PASSED");
}

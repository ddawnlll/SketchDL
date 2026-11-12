// Minimal TCP server primitives over POSIX sockets. The HTTP parser and
// router live in sketchdl.goose; this module owns only the syscalls.
namespace net;

import std;

extern fn c_socket(domain: i32, stype: i32, proto: i32) -> i32 = "socket";
extern fn c_bind(fd: i32, addr: const SockaddrIn&, len: u32) -> i32 = "bind";
extern fn c_listen(fd: i32, backlog: i32) -> i32 = "listen";
extern fn c_accept(fd: i32, addr: u64&, len: u64&) -> i32 = "accept";
extern fn c_close(fd: i32) -> i32 = "close";
extern fn c_read(fd: i32, buf: u8&, count: i64) -> i64 = "read";
extern fn c_write(fd: i32, buf: const u8&, count: i64) -> i64 = "write";
extern fn c_setsockopt(fd: i32, level: i32, name: i32, opt: const u8&, len: u32) -> i32 = "setsockopt";
extern fn c_shutdown(fd: i32, how: i32) -> i32 = "shutdown";
extern fn c_fcntl(fd: i32, cmd: i32, arg: i32) -> i32 = "fcntl";

struct SockaddrIn { family: u16, port: u16, addr: u32, zero: u8[8] }

const AF_INET = 2;
const SOCK_STREAM = 1;
const IPPROTO_TCP = 6;
const SOL_SOCKET = 1;
const SO_REUSEADDR = 2;
const SO_RCVTIMEO = 20;
const SO_SNDTIMEO = 21;
const TCP_NODELAY = 1;
const SHUT_RDWR = 2;
const F_GETFL = 3;
const F_SETFL = 4;
const F_SETFD = 2;
const FD_CLOEXEC = 1;
const O_NONBLOCK = 2048;

fn listen(host_octets: u32, port: i64) -> i64 {
    let fd = c_socket(AF_INET, SOCK_STREAM, 0);
    if fd < 0 { return -1; }
    // Children spawned later must not inherit the listener (it would keep
    // the port bound after the server dies; see vendor/proc.c).
    c_fcntl(fd, F_SETFD, FD_CLOEXEC);
    var one: u8[4] = [1, 0, 0, 0];
    c_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one[0], 4);
    var sa = SockaddrIn { family: AF_INET, port: htons(port), addr: host_octets, zero: [0; 8] };
    if c_bind(fd, sa, 16) != 0 { c_close(fd); return -1; }
    if c_listen(fd, 64) != 0 { c_close(fd); return -1; }
    return fd;
}

// Applies a millisecond timeout to future accept/read/write calls on fd.
// On Linux this makes accept() on a listening socket return -1 (EAGAIN)
// after the timeout, which the supervisor loop uses for housekeeping.
fn set_timeouts(fd: i64, ms: i64) {
    var tv: u8[16] = [0; 16];
    let sec = ms / 1000;
    let usec = (ms % 1000) * 1000;
    tv[0] = sec as u8; tv[1] = (sec >> 8) as u8; tv[2] = (sec >> 16) as u8; tv[3] = (sec >> 24) as u8;
    tv[4] = usec as u8; tv[5] = (usec >> 8) as u8; tv[6] = (usec >> 16) as u8; tv[7] = (usec >> 24) as u8;
    c_setsockopt(fd as i32, SOL_SOCKET, SO_RCVTIMEO, tv[0], 16);
    c_setsockopt(fd as i32, SOL_SOCKET, SO_SNDTIMEO, tv[0], 16);
}

fn htons(port: i64) -> u16 {
    let p = port as u16;
    return (p << 8) | (p >> 8);
}

// Puts a listening socket into non-blocking mode. Linux accept() ignores
// SO_RCVTIMEO, so a blocking accept would sleep forever and the
// supervisor's housekeeping (worker spawn, reaping, janitor) would never
// run. With O_NONBLOCK, accept returns -1 (EAGAIN) at once when no
// connection is pending and the serve loop can housekeep on a timer.
fn set_nonblocking(fd: i64) {
    let flags = c_fcntl(fd as i32, F_GETFL, 0);
    if flags >= 0 { c_fcntl(fd as i32, F_SETFL, flags | O_NONBLOCK); }
}

fn accept(listen_fd: i64) -> i64 {
    var dummy: u64 = 0;
    var dlen: u64 = 0;
    let fd = c_accept(listen_fd as i32, dummy, dlen);
    if fd < 0 { return -1; }
    set_timeouts(fd, 30000);
    var nodelay: u8[4] = [1, 0, 0, 0];
    c_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, nodelay[0], 4);
    return fd;
}

fn read_into(fd: i64, buf: u8[65536]&, count: i64) -> i64 {
    let n = c_read(fd as i32, buf[0], count);
    if n < 0 { return -1; }
    return n;
}

fn write_all(fd: i64, data: u8[:]) -> bool {
    if data.len == 0 { return true; }
    var sent = 0;
    while sent < data.len {
        let n = c_write(fd as i32, data[sent], data.len - sent);
        if n <= 0 { return false; }
        sent += n;
    }
    return true;
}

fn close(fd: i64) {
    if fd >= 0 { c_close(fd as i32); }
}

fn shutdown(fd: i64) {
    if fd >= 0 { c_shutdown(fd as i32, SHUT_RDWR); }
}

fn parse_ipv4(text: u8[:], out: u32&) -> bool {
    var parts: i64[4] = [0; 4];
    var part = 0;
    var value = 0;
    var digits = 0;
    var i = 0;
    loop {
        if i == text.len || text[i] == '.' {
            if digits == 0 || value > 255 { return false; }
            parts[part] = value;
            part += 1;
            value = 0;
            digits = 0;
            if i == text.len { break; }
            if part >= 4 { return false; }
        } else {
            let c = text[i];
            if c < '0' || c > '9' { return false; }
            value = value * 10 + (c - '0');
            digits += 1;
        }
        i += 1;
    }
    if part != 4 { return false; }
    out = (parts[0] as u32) | ((parts[1] as u32) << 8) | ((parts[2] as u32) << 16) | ((parts[3] as u32) << 24);
    return true;
}

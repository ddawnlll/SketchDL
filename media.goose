// ffprobe verification: a file is only READY when its container is MP4
// and its streams match the selected MP4-compatible profile (h264 + aac).
// A container alone proves nothing; codecs decide.
namespace media;

import std;
import proc;
import util;

const MAX_PROBE_BYTES = 64 * 1024;

// Runs ffprobe on path (timeout_ms) and checks the result. Details collect
// human-readable facts for the UI. False with a reason when not verifiable.
fn verify_mp4(ffprobe: u8[:], path: u8[:], timeout_ms: i64, facts: u8[>..]&) -> bool {
    if !proc::access_x(ffprobe) { facts.append("ffprobe not executable"); return false; }
    if proc::file_size(path) <= 0 { facts.append("empty file"); return false; }
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    proc::argv_push(blob, offs, ffprobe);
    proc::argv_push(blob, offs, "-v");
    proc::argv_push(blob, offs, "error");
    proc::argv_push(blob, offs, "-show_entries");
    proc::argv_push(blob, offs, "format=format_name");
    proc::argv_push(blob, offs, "-show_entries");
    proc::argv_push(blob, offs, "stream=codec_name,codec_type");
    proc::argv_push(blob, offs, "-of");
    proc::argv_push(blob, offs, "default=noprint_wrappers=1");
    proc::argv_push(blob, offs, path);
    var child = proc::Child { pid: 0, out_fd: 0, err_fd: 0 };
    if !proc::spawn(ffprobe, blob, offs, "", child) { facts.append("ffprobe spawn failed"); return false; }
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    var buf: u8[65536] = [0; 65536];
    var out_eof = false;
    var err_eof = false;
    var final_ec = -1;
    var reaped = false;
    let start_ns = clock_ns();
    loop {
        let elapsed_ms = (clock_ns() - start_ns) / 1000000;
        let remaining = timeout_ms - elapsed_ms;
        var wait_ms: i64 = 100;
        if remaining < wait_ms { wait_ms = if remaining < 0 { 0 } else { remaining }; }
        if !(out_eof && err_eof) {
            let mask = proc::poll2(child.out_fd, child.err_fd, wait_ms);
            if mask > 0 {
                if (mask & 1) != 0 && !out_eof {
                    let r = proc::poll_read(child.out_fd, buf, 0);
                    if r > 0 { if out.len + r <= MAX_PROBE_BYTES { out.append(buf[..r]); } }
                    else if r == 0 { out_eof = true; }
                }
                if (mask & 2) != 0 && !err_eof {
                    let r = proc::poll_read(child.err_fd, buf, 0);
                    if r > 0 {
                        err.append(buf[..r]);
                        if err.len > MAX_PROBE_BYTES { var nt = util::newest_tail(err, MAX_PROBE_BYTES); err = copy(nt); }
                    } else if r == 0 { err_eof = true; }
                }
            }
        } else {
            proc::sleep_ms(50);
        }
        let ec, st = proc::try_wait(child.pid);
        if st == 1 {
            // Drain whatever remains, then judge.
            final_ec = ec;
            reaped = true;
            break;
        }
        if elapsed_ms >= timeout_ms {
            proc::kill_group(child.pid, 9);
            let _ec2, _w = proc::wait(child.pid);
            proc::close_fd(child.out_fd);
            proc::close_fd(child.err_fd);
            facts.append("ffprobe timed out");
            return false;
        }
    }
    // Final drain.
    var rounds = 0;
    while (!out_eof || !err_eof) && rounds < 50 {
        rounds += 1;
        let mask = proc::poll2(child.out_fd, child.err_fd, 100);
        if mask <= 0 {
            if mask < 0 { break; }
            continue;
        }
        if !out_eof {
            let r = proc::poll_read(child.out_fd, buf, 0);
            if r > 0 { if out.len + r <= MAX_PROBE_BYTES { out.append(buf[..r]); } }
            else if r == 0 { out_eof = true; }
        }
        if !err_eof {
            let r = proc::poll_read(child.err_fd, buf, 0);
            if r > 0 {
                err.append(buf[..r]);
                if err.len > MAX_PROBE_BYTES { var nt = util::newest_tail(err, MAX_PROBE_BYTES); err = copy(nt); }
            }
            else if r == 0 { err_eof = true; }
        }
    }
    proc::close_fd(child.out_fd);
    proc::close_fd(child.err_fd);
    // Never double-wait: try_wait already reaped the child in the normal
    // path, and waitpid on a reaped pid returns ECHILD with exit code -1.
    let exit_code = if reaped { final_ec } else { let e2, _w = proc::wait(child.pid); e2 };
    if exit_code != 0 { facts.append("ffprobe failed"); return false; }
    if find(out, "mp4") < 0 { facts.append("not an MP4 container"); return false; }
    let has_h264 = find(out, "codec_name=h264") >= 0;
    let has_aac = find(out, "codec_name=aac") >= 0;
    let has_video = find(out, "codec_type=video") >= 0;
    let has_audio = find(out, "codec_type=audio") >= 0;
    facts.append("streams: ");
    if has_h264 { facts.append("h264"); } else { facts.append("video not h264"); }
    if has_aac { facts.append(" + aac"); }
    else if has_audio { facts.append(" + audio not aac"); }
    if !has_h264 { facts.append("; expected H.264 video"); return false; }
    if has_audio && !has_aac { facts.append("; expected AAC audio"); return false; }
    return true;
}

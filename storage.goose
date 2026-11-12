// Filesystem layout and lifecycle: job directories, atomic publication,
// expiry, and quota checks. Untrusted names never reach the filesystem:
// job ids are server-issued hex, filenames are fixed templates.
namespace storage;

import std;
import proc;

const MAX_ID_HEX = 32;

fn valid_job_id(id: u8[:]) -> bool {
    if id.len == 0 || id.len > MAX_ID_HEX { return false; }
    for c in id {
        if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { return false; }
    }
    return true;
}

fn job_dir(out: u8[>..]&, data: u8[:], id: u8[:]) {
    out.append(data);
    if data.len > 0 && data[data.len - 1] != '/' { out.push('/'); }
    out.append("jobs/");
    out.append(id);
}

fn job_tmp_dir(out: u8[>..]&, data: u8[:], id: u8[:]) {
    job_dir(out, data, id);
    out.append("/tmp");
}

fn complete_path(out: u8[>..]&, data: u8[:], id: u8[:]) {
    out.append(data);
    if data.len > 0 && data[data.len - 1] != '/' { out.push('/'); }
    out.append("complete/");
    out.append(id);
    out.append(".mp4");
}

fn ensure_layout(data: u8[:]) -> bool {
    var jobs: u8[>..] = [];
    jobs.append(data);
    if data.len > 0 && data[data.len - 1] != '/' { jobs.push('/'); }
    jobs.append("jobs");
    if !proc::mkdir_p(jobs) { return false; }
    var complete: u8[>..] = [];
    complete.append(data);
    if data.len > 0 && data[data.len - 1] != '/' { complete.push('/'); }
    complete.append("complete");
    return proc::mkdir_p(complete);
}

// Publishes a staged file: staged (in jobs/<id>/) -> complete/<id>.mp4.
// Both dirs share a filesystem, so rename is atomic. Returns file size or -1.
fn publish(data: u8[:], id: u8[:], staged: u8[:]) -> i64 {
    var target: u8[>..] = [];
    complete_path(target, data, id);
    let size = proc::file_size(staged);
    if size <= 0 { return -1; }
    if !proc::rename_file(staged, target) { return -1; }
    // fsync the complete dir so the rename itself is durable.
    var dir: u8[>..] = [];
    dir.append(data);
    if data.len > 0 && data[data.len - 1] != '/' { dir.push('/'); }
    dir.append("complete");
    proc::fsync_path(dir);
    return size;
}

// Removes the whole staging area for a job (keeps the complete/ file).
fn cleanup_job(data: u8[:], id: u8[:]) {
    var d: u8[>..] = [];
    job_dir(d, data, id);
    proc::rm_rf(d);
}

// Removes a published file (expiry). Missing is success.
fn remove_complete(data: u8[:], id: u8[:]) {
    var p: u8[>..] = [];
    complete_path(p, data, id);
    proc::unlink(p);
}

fn complete_size(data: u8[:], id: u8[:]) -> i64 {
    var p: u8[>..] = [];
    complete_path(p, data, id);
    return proc::file_size(p);
}

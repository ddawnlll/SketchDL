// SketchDL subprocess + filesystem interop layer.
//
// Goose strictly passes {ptr,len} structs for slices, which C prototypes do
// not accept. So strings cross as `const u8&` (a `char*`) over NUL-terminated
// buffers, and argv crosses as a packed blob + int offset array. All syscall
// details (fork/dup2/setpgid/poll/waitpid) stay in this file.
//
// The child is started in its own session (setsid) so the whole tree
// (yt-dlp -> deno/ffmpeg) can be killed with one killpg.

#define _GNU_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sendfile.h>
#include <sys/statvfs.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <limits.h>

// Close every inherited descriptor above stderr in a freshly forked child,
// just before exec. Without this, spawned processes (notably the
// download workers, which are setsid-detached and outlive the server)
// keep the server's listening socket and client sockets open: after a
// server restart (e.g. SIGKILL mid-download), the port stays bound in
// the orphaned worker and the new server fails with EADDRINUSE.
static void close_inherited_fds(void) {
    close_range(3, ~0U, 0);
}

// Build argv from a packed blob: blob holds n NUL-terminated strings,
// offsets[i] is the byte offset of string i in blob. n includes argv[0].
// Returns 0 on success. out_fd receives the read end of the merged
// stdout+stderr pipe. The parent's copy of the write end is closed.
int sk_spawn2(const char *exe, const char *blob, const int *offsets, int n,
              const char *cwd, int *pid_out, int *out_fd) {
    if (!exe || !blob || !offsets || n < 1 || !pid_out || !out_fd) return -1;
    char **argv = (char **)malloc(sizeof(char *) * (size_t)(n + 1));
    if (!argv) return -1;
    for (int i = 0; i < n; i++) {
        if (offsets[i] < 0) { free(argv); return -1; }
        argv[i] = (char *)blob + offsets[i];
    }
    argv[n] = NULL;
    int fds[2];
    if (pipe(fds) != 0) { free(argv); return -1; }
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]); close(fds[1]); free(argv);
        return -1;
    }
    if (pid == 0) {
        // Child: own session + process group so killpg hits the whole tree.
        if (setsid() < 0) _exit(127); // setsid returns new SID (>0) on success
        if (cwd && cwd[0] != '\0') {
            if (chdir(cwd) != 0) _exit(126);
        }
        if (dup2(fds[1], 1) < 0) _exit(127);
        if (dup2(fds[1], 2) < 0) _exit(127);
        close(fds[0]);
        if (fds[1] > 2) close(fds[1]);
        close_inherited_fds();
        execv(exe, argv);
        _exit(127);
    }
    free(argv);
    close(fds[1]);
    *pid_out = (int)pid;
    *out_fd = fds[0];
    return 0;
}

// Poll for output and read once. Returns: >0 bytes read, 0 EOF,
// -1 timeout (no data within timeout_ms), -2 error.
int sk_poll_read(int fd, char *buf, int max, int timeout_ms) {
    if (fd < 0 || !buf || max <= 0) return -2;
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int r;
    do { r = poll(&pfd, 1, timeout_ms); } while (r < 0 && errno == EINTR);
    if (r == 0) return -1;
    if (r < 0) return -2;
    if (pfd.revents & (POLLIN | POLLHUP)) {
        ssize_t n;
        do { n = read(fd, buf, (size_t)max); } while (n < 0 && errno == EINTR);
        if (n == 0) return 0;
        if (n < 0) return -2;
        return (int)n;
    }
    if (pfd.revents & (POLLERR | POLLNVAL)) return -2;
    return -1;
}

static int decode_status(int status, int *exit_code) {
    if (WIFEXITED(status)) { *exit_code = WEXITSTATUS(status); return 0; }
    if (WIFSIGNALED(status)) { *exit_code = 128 + WTERMSIG(status); return 0; }
    return -1;
}

// Blocking wait. 0 ok (*exit_code valid), -1 error.
int sk_wait(int pid, int *exit_code) {
    if (pid <= 0) return -1;
    int status;
    for (;;) {
        pid_t r = waitpid((pid_t)pid, &status, 0);
        if (r == (pid_t)pid) return decode_status(status, exit_code);
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
}

// WNOHANG. 1 reaped (*exit_code valid), 0 still running, -1 error.
int sk_try_wait(int pid, int *exit_code) {
    if (pid <= 0) return -1;
    int status;
    for (;;) {
        pid_t r = waitpid((pid_t)pid, &status, WNOHANG);
        if (r == (pid_t)pid) { return decode_status(status, exit_code) == 0 ? 1 : -1; }
        if (r == 0) return 0;
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
}

// Kill the child's whole process group. sig e.g. 9 (SIGKILL), 15 (SIGTERM).
// The child becomes the group leader via setsid() in sk_spawn2, but there is a
// race: the parent may call this before the child has run setsid. So retry
// for up to ~2s; "already gone" is success, since the goal is that nothing
// in the tree survives.
int sk_kill_group(int pid, int sig) {
    if (pid <= 0) return -1;
    for (int i = 0; i < 200; i++) {
        if (killpg((pid_t)pid, sig) == 0) return 0;
        if (errno == ESRCH) {
            // Group does not exist yet (child pre-setsid) or is gone entirely.
            // Distinguish: if the leader process itself is gone, we are done.
            errno = 0;
            if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) return 0;
            // Otherwise the child exists but is not a group leader yet: retry.
        } else if (errno == EPERM) {
            return -1;
        }
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 10 * 1000 * 1000; // 10ms
        nanosleep(&ts, NULL);
    }
    return -1;
}

// Wait up to timeout_ms (poll loop). 1 exited (*exit_code valid),
// 0 timeout (child still running), -1 error.
int sk_wait_timeout(int pid, int timeout_ms, int *exit_code) {
    if (pid <= 0) return -1;
    int waited = 0;
    for (;;) {
        int st = 0;
        int r = sk_try_wait(pid, &st);
        if (r == 1) { *exit_code = st; return 1; }
        if (r < 0) return -1;
        if (waited >= timeout_ms) return 0;
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 50 * 1000 * 1000; // 50ms
        nanosleep(&ts, NULL);
        waited += 50;
    }
}

long sk_file_size(const char *path) {
    if (!path) return -1;
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    if (!S_ISREG(st.st_mode)) return -1;
    return (long)st.st_size;
}

int sk_access_x(const char *path) {
    if (!path) return -1;
    return access(path, X_OK);
}

// mkdir -p: creates every missing component. 0 ok (incl. already exists), -1 err.
int sk_mkdir_p(const char *path) {
    if (!path || !path[0]) return -1;
    char copy[PATH_MAX];
    size_t len = strlen(path);
    if (len >= sizeof(copy) - 1) return -1;
    memcpy(copy, path, len + 1);
    // Remove trailing slashes (except lone "/").
    while (len > 1 && copy[len - 1] == '/') copy[--len] = '\0';
    for (size_t i = 1; i <= len; i++) {
        if (copy[i] == '/' || copy[i] == '\0') {
            char c = copy[i];
            copy[i] = '\0';
            if (mkdir(copy, 0755) != 0 && errno != EEXIST) return -1;
            struct stat st;
            if (stat(copy, &st) != 0 || !S_ISDIR(st.st_mode)) return -1;
            copy[i] = c;
        }
    }
    return 0;
}

int sk_rename(const char *from, const char *to) {
    if (!from || !to) return -1;
    return rename(from, to);
}

int sk_unlink(const char *path) {
    if (!path) return -1;
    return unlink(path);
}

// Recursively delete a directory tree created by us (job dirs). Never follows
// symlinks: symlinked entries are unlinked, not descended into.
static int rm_rf_inner(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        return unlink(path);
    }
    DIR *d = opendir(path);
    if (!d) return -1;
    int rc = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char child[PATH_MAX];
        int w = snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
        if (w < 0 || (size_t)w >= sizeof(child)) { rc = -1; continue; }
        if (rm_rf_inner(child) != 0) rc = -1;
    }
    closedir(d);
    if (rmdir(path) != 0) rc = -1;
    return rc;
}

// 0 ok (missing == ok), -1 err. Only call on job dirs we own.
int sk_rm_rf(const char *path) {
    if (!path || !path[0]) return -1;
    struct stat st;
    if (lstat(path, &st) != 0) {
        if (errno == ENOENT) return 0;
        return -1;
    }
    // Refuse to delete "/" or "." or "..".
    if (strcmp(path, "/") == 0 || strcmp(path, ".") == 0 || strcmp(path, "..") == 0) return -1;
    return rm_rf_inner(path);
}

// fsync a file or directory fd-less (by path). 0 ok, -1 err.
int sk_fsync_path(const char *path) {
    if (!path) return -1;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    int r = fsync(fd);
    close(fd);
    return r;
}

// Current process executable path into buf (NUL-terminated). Returns byte
// count (excl. NUL) or -1.
int sk_self_exe(char *buf, int max) {
    if (!buf || max <= 0) return -1;
    ssize_t n = readlink("/proc/self/exe", buf, (size_t)(max - 1));
    if (n < 0) return -1;
    buf[n] = '\0';
    return (int)n;
}

// --- Separate stdout/stderr spawn, file serving, and fd helpers -----------

// Spawn with separate stdout and stderr pipes. Same argv/blob ABI as
// sk_spawn2. out_fd and err_fd each receive a read end.
int sk_spawn3(const char *exe, const char *blob, const int *offsets, int n,
              const char *cwd, int *pid_out, int *out_fd, int *err_fd) {
    if (!exe || !blob || !offsets || n < 1 || !pid_out || !out_fd || !err_fd) return -1;
    char **argv = (char **)malloc(sizeof(char *) * (size_t)(n + 1));
    if (!argv) return -1;
    for (int i = 0; i < n; i++) {
        if (offsets[i] < 0) { free(argv); return -1; }
        argv[i] = (char *)blob + offsets[i];
    }
    argv[n] = NULL;
    int outfds[2], errfds[2];
    if (pipe(outfds) != 0) { free(argv); return -1; }
    if (pipe(errfds) != 0) { close(outfds[0]); close(outfds[1]); free(argv); return -1; }
    pid_t pid = fork();
    if (pid < 0) {
        close(outfds[0]); close(outfds[1]); close(errfds[0]); close(errfds[1]);
        free(argv);
        return -1;
    }
    if (pid == 0) {
        if (setsid() < 0) _exit(127);
        if (cwd && cwd[0] != '\0') {
            if (chdir(cwd) != 0) _exit(126);
        }
        if (dup2(outfds[1], 1) < 0) _exit(127);
        if (dup2(errfds[1], 2) < 0) _exit(127);
        close(outfds[0]); close(outfds[1]); close(errfds[0]); close(errfds[1]);
        close_inherited_fds();
        execv(exe, argv);
        _exit(127);
    }
    free(argv);
    close(outfds[1]);
    close(errfds[1]);
    *pid_out = (int)pid;
    *out_fd = outfds[0];
    *err_fd = errfds[0];
    return 0;
}

// Close an fd. 0 ok, -1 err.
int sk_close_fd(int fd) {
    if (fd < 0) return -1;
    return close(fd);
}

// Open a file for reading. Returns fd, -1 on error.
int sk_open_read(const char *path) {
    if (!path) return -1;
    return open(path, O_RDONLY);
}

// pread into buf. >0 bytes, 0 EOF, -1 err.
int sk_pread(int fd, char *buf, int max, long offset) {
    if (fd < 0 || !buf) return -1;
    ssize_t n;
    do { n = pread(fd, buf, (size_t)max, (off_t)offset); } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    return (int)n;
}

// sendfile: send count bytes from path offset to out_fd. Returns bytes sent,
// 0 when fully sent or EOF-with-nothing, -1 on error. May send fewer than
// count; caller loops.
int sk_sendfile(int out_fd, int in_fd, long offset, long count) {
    if (out_fd < 0 || in_fd < 0 || count <= 0) return -1;
    off_t off = (off_t)offset;
    ssize_t n;
    do { n = sendfile(out_fd, in_fd, &off, (size_t)count); } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    return (int)n;
}

// Sleep milliseconds. 0 ok.
int sk_sleep_ms(int ms) {
    if (ms <= 0) return 0;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
    return 0;
}

// Free bytes on the filesystem containing path (statvfs). -1 on error.
long long sk_free_bytes(const char *path) {
    if (!path) return -1;
    struct statvfs sv;
    if (statvfs(path, &sv) != 0) return -1;
    unsigned long long free_bytes = (unsigned long long)sv.f_bavail * (unsigned long long)sv.f_frsize;
    if (free_bytes > 9000000000000000000ULL) return 9000000000000000000LL;
    return (long long)free_bytes;
}

// Spawn with explicit environment: env_blob holds concatenated
// "KEY=VALUE\n" strings. A non-empty blob is MERGED into the parent
// environment (blob entries win on duplicate keys); an empty blob
// inherits the parent environment unchanged.
int sk_spawn4(const char *exe, const char *blob, const int *offsets, int n,
              const char *cwd, const char *env_blob, int *pid_out, int *out_fd, int *err_fd) {
    if (!exe || !blob || !offsets || n < 1 || !pid_out || !out_fd || !err_fd) return -1;
    char **argv = (char **)malloc(sizeof(char *) * (size_t)(n + 1));
    if (!argv) return -1;
    for (int i = 0; i < n; i++) {
        if (offsets[i] < 0) { free(argv); return -1; }
        argv[i] = (char *)blob + offsets[i];
    }
    argv[n] = NULL;
    // Build envp (NULL means inherit via execv). A non-empty blob is
    // merged into environ: blob entries first (they win on duplicate
    // keys), then the inherited entries that the blob does not set.
    // Children like Deno need HOME/PATH/LANG from the parent environment.
    extern char **environ;
    char **envp = NULL;
    char **env_storage = NULL;
    if (env_blob && env_blob[0] != '\0') {
        size_t blob_count = 0;
        size_t i = 0;
        while (env_blob[i] != '\0') { if (env_blob[i] == '\n') blob_count++; i++; }
        if (i > 0 && env_blob[i - 1] != '\n') blob_count++;
        size_t base_count = 0;
        for (char **e = environ; e && *e; e++) base_count++;
        char **merged = (char **)malloc(sizeof(char *) * (blob_count + base_count + 2));
        if (!merged) { free(argv); return -1; }
        size_t k = 0;
        i = 0;
        size_t start = 0;
        while (env_blob[i] != '\0') {
            if (env_blob[i] == '\n') {
                merged[k++] = (char *)env_blob + start;
                start = i + 1;
            }
            i++;
        }
        if (start < i) merged[k++] = (char *)env_blob + start;
        size_t blob_n = k;
        for (char **e = environ; e && *e; e++) {
            int shadowed = 0;
            for (size_t b = 0; b < blob_n; b++) {
                const char *ke = strchr(merged[b], '=');
                const char *be = strchr(*e, '=');
                size_t kl = ke ? (size_t)(ke - merged[b]) : strlen(merged[b]);
                size_t bl = be ? (size_t)(be - *e) : strlen(*e);
                if (kl == bl && strncmp(merged[b], *e, kl) == 0) { shadowed = 1; break; }
            }
            if (!shadowed) merged[k++] = *e;
        }
        merged[k] = NULL;
        env_storage = merged;
        envp = env_storage;
    }
    int outfds[2], errfds[2];
    if (pipe(outfds) != 0) { free(argv); free(env_storage); return -1; }
    if (pipe(errfds) != 0) { close(outfds[0]); close(outfds[1]); free(argv); free(env_storage); return -1; }
    pid_t pid = fork();
    if (pid < 0) {
        close(outfds[0]); close(outfds[1]); close(errfds[0]); close(errfds[1]);
        free(argv); free(env_storage);
        return -1;
    }
    if (pid == 0) {
        // env_blob is mutated here (newlines replaced with NULs) before
        // execve; the parent's copy is unaffected (copy-on-write).
        if (env_blob && env_blob[0] != '\0') {
            char *m = (char *)env_blob;
            for (size_t i = 0; m[i] != '\0'; i++) { if (m[i] == '\n') m[i] = '\0'; }
        }
        if (setsid() < 0) _exit(127);
        if (cwd && cwd[0] != '\0') {
            if (chdir(cwd) != 0) _exit(126);
        }
        if (dup2(outfds[1], 1) < 0) _exit(127);
        if (dup2(errfds[1], 2) < 0) _exit(127);
        close(outfds[0]); close(outfds[1]); close(errfds[0]); close(errfds[1]);
        close_inherited_fds();
        execve(exe, argv, envp ? envp : environ);
        _exit(127);
    }
    free(argv);
    free(env_storage);
    close(outfds[1]);
    close(errfds[1]);
    *pid_out = (int)pid;
    *out_fd = outfds[0];
    *err_fd = errfds[0];
    return 0;
}

// Spawn a fire-and-forget child (the download supervisor's workers): the
// child's stdout and stderr go to /dev/null. There are no pipes to close
// and no SIGPIPE hazard when the child writes diagnostics to stderr.
int sk_spawn_null(const char *exe, const char *blob, const int *offsets, int n,
                  const char *cwd, int *pid_out) {
    if (!exe || !blob || !offsets || n < 1 || !pid_out) return -1;
    char **argv = (char **)malloc(sizeof(char *) * (size_t)(n + 1));
    if (!argv) return -1;
    for (int i = 0; i < n; i++) {
        if (offsets[i] < 0) { free(argv); return -1; }
        argv[i] = (char *)blob + offsets[i];
    }
    argv[n] = NULL;
    pid_t pid = fork();
    if (pid < 0) { free(argv); return -1; }
    if (pid == 0) {
        if (setsid() < 0) _exit(127);
        if (cwd && cwd[0] != '\0') {
            if (chdir(cwd) != 0) _exit(126);
        }
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, 1);
            dup2(devnull, 2);
            if (devnull > 2) close(devnull);
        }
        close_inherited_fds();
        execv(exe, argv);
        _exit(127);
    }
    free(argv);
    *pid_out = (int)pid;
    return 0;
}

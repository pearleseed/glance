/*
 * pam_glance.c
 *
 * Opt-in OpenPAM authentication module for Glance Face-for-sudo on macOS.
 * Connects over a user-private Unix domain socket inside the invoking user's
 * Application Support directory, verifies peer UID, peer PID executable path,
 * root-owned non-writable binary permissions, and performs a 256-bit challenge-
 * response nonce exchange before returning PAM_SUCCESS.
 *
 * Any failure returns PAM_AUTHINFO_UNAVAIL or PAM_AUTH_ERR so PAM falls
 * through to pam_tid.so and/or password authentication.
 */

#define __STDC_WANT_LIB_EXT1__ 1
#define PAM_SM_AUTH

#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define GLANCE_TRUSTED_EXECUTABLE "/Applications/Glance.app/Contents/MacOS/glance"
#define GLANCE_SOCKET_REL_DIR "Library/Application Support/glance-sudo"
#define GLANCE_SOCKET_NAME "glance-sudo.sock"
#define GLANCE_NONCE_BYTES 32
#define GLANCE_NONCE_HEX_LEN (GLANCE_NONCE_BYTES * 2)
#define GLANCE_SOCKET_TIMEOUT_SEC 30

static bool
is_remote_session(pam_handle_t *pamh)
{
    const void *rhost_item = NULL;
    if (pam_get_item(pamh, PAM_RHOST, &rhost_item) == PAM_SUCCESS && rhost_item != NULL) {
        const char *rhost = (const char *)rhost_item;
        if (rhost[0] != '\0') {
            return true;
        }
    }
    return false;
}

static bool
resolve_invoking_user(pam_handle_t *pamh, uid_t *out_uid, char *out_home, size_t out_home_size)
{
    const char *username = NULL;
    const void *ruser_item = NULL;

    if (pam_get_item(pamh, PAM_RUSER, &ruser_item) == PAM_SUCCESS && ruser_item != NULL) {
        const char *ruser = (const char *)ruser_item;
        if (ruser[0] != '\0') {
            username = ruser;
        }
    }

    if (username == NULL) {
        if (pam_get_user(pamh, &username, NULL) != PAM_SUCCESS ||
            username == NULL ||
            username[0] == '\0') {
            return false;
        }
    }

    struct passwd pwd;
    struct passwd *pwd_res = NULL;
    char pw_buf[8192];
    if (getpwnam_r(username, &pwd, pw_buf, sizeof(pw_buf), &pwd_res) != 0 || pwd_res == NULL) {
        memset_s(pw_buf, sizeof(pw_buf), 0, sizeof(pw_buf));
        return false;
    }

    /* Never allow root (uid 0) authentication via face socket. */
    if (pwd.pw_uid == 0 || pwd.pw_dir == NULL || pwd.pw_dir[0] != '/') {
        memset_s(pw_buf, sizeof(pw_buf), 0, sizeof(pw_buf));
        return false;
    }

    int written = snprintf(out_home, out_home_size, "%s", pwd.pw_dir);
    uid_t uid = pwd.pw_uid;
    memset_s(pw_buf, sizeof(pw_buf), 0, sizeof(pw_buf));

    if (written < 0 || (size_t)written >= out_home_size) {
        return false;
    }

    *out_uid = uid;
    return true;
}

static bool
verify_socket_paths(const char *dir_path, const char *sock_path, uid_t expected_uid)
{
    struct stat st;

    if (lstat(dir_path, &st) != 0) {
        return false;
    }
    if (!S_ISDIR(st.st_mode) ||
        st.st_uid != expected_uid ||
        (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return false;
    }

    if (lstat(sock_path, &st) != 0) {
        return false;
    }
    if (!S_ISSOCK(st.st_mode) || st.st_uid != expected_uid) {
        return false;
    }

    return true;
}

static bool
is_root_owned_dir(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0) {
        return false;
    }
    return st.st_uid == 0 &&
           S_ISDIR(st.st_mode) &&
           (st.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static bool
trusted_peer(int fd, uid_t expected_uid)
{
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 ||
        peer_uid != expected_uid ||
        peer_uid == 0) {
        return false;
    }

    pid_t peer_pid = -1;
    socklen_t pid_len = (socklen_t)sizeof(peer_pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &pid_len) != 0 ||
        pid_len != (socklen_t)sizeof(peer_pid) ||
        peer_pid <= 0) {
        return false;
    }

    char proc_path[PROC_PIDPATHINFO_MAXSIZE];
    int path_len = proc_pidpath((int)peer_pid, proc_path, (uint32_t)sizeof(proc_path));
    if (path_len <= 0 || (size_t)path_len >= sizeof(proc_path)) {
        return false;
    }
    proc_path[path_len] = '\0';

    if (strcmp(proc_path, GLANCE_TRUSTED_EXECUTABLE) != 0) {
        return false;
    }

    /* Ensure all bundle directory components and the executable itself are root-owned and non-writable by group/others. */
    if (!is_root_owned_dir("/Applications/Glance.app") ||
        !is_root_owned_dir("/Applications/Glance.app/Contents") ||
        !is_root_owned_dir("/Applications/Glance.app/Contents/MacOS")) {
        return false;
    }

    struct stat st;
    if (lstat(GLANCE_TRUSTED_EXECUTABLE, &st) != 0) {
        return false;
    }
    if (st.st_uid != 0 ||
        !S_ISREG(st.st_mode) ||
        (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return false;
    }

    return true;
}

static bool
write_all(int fd, const char *buf, size_t len)
{
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

static ssize_t
read_line(int fd, char *buf, size_t cap)
{
    if (cap < 2) {
        return -1;
    }

    size_t used = 0;
    while (used < cap - 1) {
        char ch = '\0';
        ssize_t n = recv(fd, &ch, 1, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        buf[used++] = ch;
        if (ch == '\n') {
            buf[used] = '\0';
            return (ssize_t)used;
        }
    }

    return -1;
}

PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)flags;
    (void)argc;
    (void)argv;

    if (pamh == NULL || is_remote_session(pamh)) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    uid_t target_uid = 0;
    char home_dir[PATH_MAX];
    if (!resolve_invoking_user(pamh, &target_uid, home_dir, sizeof(home_dir))) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    char dir_path[PATH_MAX];
    int dir_len = snprintf(dir_path, sizeof(dir_path), "%s/%s", home_dir, GLANCE_SOCKET_REL_DIR);
    if (dir_len < 0 || (size_t)dir_len >= sizeof(dir_path)) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    int sock_len = snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/%s", dir_path, GLANCE_SOCKET_NAME);
    if (sock_len < 0 || (size_t)sock_len >= sizeof(addr.sun_path)) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (!verify_socket_paths(dir_path, addr.sun_path, target_uid)) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, (socklen_t)sizeof(one)) != 0) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    struct timeval tv;
    tv.tv_sec = GLANCE_SOCKET_TIMEOUT_SEC;
    tv.tv_usec = 0;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, (socklen_t)sizeof(tv)) != 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, (socklen_t)sizeof(tv)) != 0) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (connect(fd, (const struct sockaddr *)&addr, (socklen_t)sizeof(addr)) != 0) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (!trusted_peer(fd, target_uid)) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    uint8_t nonce_raw[GLANCE_NONCE_BYTES];
    char nonce_hex[GLANCE_NONCE_HEX_LEN + 1];
    arc4random_buf(nonce_raw, sizeof(nonce_raw));

    static const char hex_digits[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(nonce_raw); i++) {
        nonce_hex[i * 2] = hex_digits[(nonce_raw[i] >> 4) & 0x0f];
        nonce_hex[i * 2 + 1] = hex_digits[nonce_raw[i] & 0x0f];
    }
    nonce_hex[GLANCE_NONCE_HEX_LEN] = '\0';

    char request[GLANCE_NONCE_HEX_LEN + 16];
    int req_len = snprintf(request, sizeof(request), "AUTH %s\n", nonce_hex);

    char expected_ok[GLANCE_NONCE_HEX_LEN + 16];
    int ok_len = snprintf(expected_ok, sizeof(expected_ok), "OK %s\n", nonce_hex);

    char expected_fail[GLANCE_NONCE_HEX_LEN + 16];
    int fail_len = snprintf(expected_fail, sizeof(expected_fail), "FAIL %s\n", nonce_hex);

    int pam_result = PAM_AUTHINFO_UNAVAIL;
    char response[128];
    memset(response, 0, sizeof(response));

    if (req_len == 5 + GLANCE_NONCE_HEX_LEN + 1 &&
        ok_len == 3 + GLANCE_NONCE_HEX_LEN + 1 &&
        fail_len == 5 + GLANCE_NONCE_HEX_LEN + 1 &&
        write_all(fd, request, (size_t)req_len)) {
        ssize_t resp_len = read_line(fd, response, sizeof(response));
        if (resp_len == (ssize_t)ok_len &&
            timingsafe_bcmp(response, expected_ok, (size_t)ok_len) == 0) {
            pam_result = PAM_SUCCESS;
        } else if (resp_len == (ssize_t)fail_len &&
                   timingsafe_bcmp(response, expected_fail, (size_t)fail_len) == 0) {
            pam_result = PAM_AUTH_ERR;
        }
    }

    memset_s(nonce_raw, sizeof(nonce_raw), 0, sizeof(nonce_raw));
    memset_s(nonce_hex, sizeof(nonce_hex), 0, sizeof(nonce_hex));
    memset_s(request, sizeof(request), 0, sizeof(request));
    memset_s(expected_ok, sizeof(expected_ok), 0, sizeof(expected_ok));
    memset_s(expected_fail, sizeof(expected_fail), 0, sizeof(expected_fail));
    memset_s(response, sizeof(response), 0, sizeof(response));

    close(fd);
    return pam_result;
}

PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_IGNORE;
}

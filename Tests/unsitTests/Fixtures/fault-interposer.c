// Synthetic macOS syscall faults; used only by XCTest subprocesses.
#include <sys/xattr.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
static int target_fd = -1;
static int mode(const char *value) {
    const char *selected = getenv("UNSIT_TEST_FAULT");
    return selected && strcmp(selected, value) == 0;
}
static int test_xattr(int fd, const char *name, const void *bytes, size_t count, u_int32_t pos, int options) {
    target_fd = fd;
    if (strcmp(name, "com.apple.ResourceFork") == 0) {
        if (mode("stop_resource")) raise(SIGSTOP);
        if (mode("resource")) { errno = ENOTSUP; return -1; }
    }
    if (strcmp(name, "com.apple.FinderInfo") == 0 && mode("finder")) { errno = ENOTSUP; return -1; }
    return fsetxattr(fd, name, bytes, count, pos, options);
}
static int test_times(int fd, const struct timeval *times) {
    if (fd == target_fd && mode("date")) { errno = EPERM; return -1; }
    return futimes(fd, times);
}
static int test_close(int fd) {
    if (fd == target_fd && mode("close")) {
        target_fd = -1; close(fd); errno = EIO; return -1;
    }
    return close(fd);
}
static int test_mkdirat(int fd, const char *name, mode_t permissions) {
    if (mode("directory") && strcmp(name, "blocked") == 0) { errno = EACCES; return -1; }
    return mkdirat(fd, name, permissions);
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *a; const void *b; } pair_##replacement \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };
INTERPOSE(test_xattr, fsetxattr)
INTERPOSE(test_times, futimes)
INTERPOSE(test_close, close)

INTERPOSE(test_mkdirat, mkdirat)

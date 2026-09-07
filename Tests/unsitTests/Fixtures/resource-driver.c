// Disposable CLI resource probe. Darwin does not support a useful RLIMIT_AS;
// enforce CPU/file-size limits and watch resident memory from the parent.
#include <sys/resource.h>
#include <sys/wait.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc < 2) return 125;
    pid_t child = fork();
    if (child < 0) return 125;
    if (child == 0) {
        struct rlimit cpu = { 5, 5 }, file = { 1024 * 1024, 1024 * 1024 };
        if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_FSIZE, &file)) _exit(125);
        execv(argv[1], argv + 1); _exit(125);
    }
    int status, limited = 0, polls = 0; struct rusage usage;
    while (1) {
        pid_t done = wait4(child, &status, WNOHANG, &usage);
        if (done == child) break;
        if (done < 0) return 125;
        struct rusage_info_v2 info;
        if ((proc_pid_rusage(child, RUSAGE_INFO_V2, (rusage_info_t *)&info) == 0 &&
             info.ri_resident_size > 128 * 1024 * 1024) || ++polls > 500) {
            limited = 1; kill(child, SIGKILL);
        }
        usleep(10000);
    }
    printf("peak-rss-bytes=%ld\n", usage.ru_maxrss);
    if (limited) return 124;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 124;
}

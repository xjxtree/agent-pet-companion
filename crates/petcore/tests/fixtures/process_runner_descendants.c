#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define OWNERSHIP_FILE_ENV "APC_PROCESS_RUNNER_OWNERSHIP_FILE_V1"

static void fail(const char *message) {
    perror(message);
    _exit(70);
}

static void write_all(int fd, const char *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            fail("write");
        }
        bytes += written;
        length -= (size_t)written;
    }
}

static void write_pid_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        fail("open pid file");
    }
    char line[64];
    int length = snprintf(line, sizeof(line), "%ld\n", (long)getpid());
    if (length <= 0 || (size_t)length >= sizeof(line)) {
        fail("format pid");
    }
    write_all(fd, line, (size_t)length);
    close(fd);
}

static void register_owned_process(void) {
    const char *path = getenv(OWNERSHIP_FILE_ENV);
    if (path == NULL || path[0] == '\0') {
        return;
    }
    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd < 0) {
        fail("open ownership file");
    }
    char line[64];
    int length = snprintf(line, sizeof(line), "%ld\n", (long)getpid());
    if (length <= 0 || (size_t)length >= sizeof(line)) {
        fail("format ownership pid");
    }
    write_all(fd, line, (size_t)length);
    close(fd);
}

static void wait_for_registration_ack(void) {
    const char *path = getenv(OWNERSHIP_FILE_ENV);
    if (path == NULL || path[0] == '\0') {
        return;
    }
    char expected[64];
    int expected_length = snprintf(expected, sizeof(expected), "ACK %ld\n", (long)getpid());
    if (expected_length <= 0 || (size_t)expected_length >= sizeof(expected)) {
        fail("format ownership ack");
    }
    for (int attempt = 0; attempt < 400; attempt++) {
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
            char bytes[8193];
            ssize_t count = read(fd, bytes, sizeof(bytes) - 1);
            close(fd);
            if (count >= 0) {
                bytes[count] = '\0';
                if (strstr(bytes, expected) != NULL) {
                    return;
                }
            }
        }
        const struct timespec delay = {.tv_sec = 0, .tv_nsec = 5000000L};
        nanosleep(&delay, NULL);
    }
    fail("ownership acknowledgement timeout");
}

static void acknowledge_ready(int fd) {
    const char ready = 'R';
    write_all(fd, &ready, 1);
    close(fd);
}

static void wait_for_ready(int fd) {
    char ready = 0;
    ssize_t received;
    do {
        received = read(fd, &ready, 1);
    } while (received < 0 && errno == EINTR);
    close(fd);
    if (received != 1 || ready != 'R') {
        fail("read readiness acknowledgement");
    }
}

static void remain_alive(void) {
    for (;;) {
        pause();
    }
}

static void close_output_pipes_descendant(const char *pid_path) {
    int sync_pipe[2];
    if (pipe(sync_pipe) != 0) {
        fail("pipe");
    }
    pid_t child = fork();
    if (child < 0) {
        fail("fork");
    }
    if (child > 0) {
        close(sync_pipe[1]);
        wait_for_ready(sync_pipe[0]);
        _exit(0);
    }

    close(sync_pipe[0]);
    signal(SIGTERM, SIG_IGN);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    write_pid_file(pid_path);
    register_owned_process();
    acknowledge_ready(sync_pipe[1]);
    remain_alive();
}

static void double_fork_sets_id_descendant(const char *pid_path) {
    int sync_pipe[2];
    int ancestry_pipe[2];
    if (pipe(sync_pipe) != 0) {
        fail("pipe");
    }
    if (pipe(ancestry_pipe) != 0) {
        fail("ancestry pipe");
    }
    pid_t child = fork();
    if (child < 0) {
        fail("first fork");
    }
    if (child > 0) {
        close(sync_pipe[1]);
        close(ancestry_pipe[0]);
        close(ancestry_pipe[1]);
        wait_for_ready(sync_pipe[0]);
        _exit(0);
    }

    close(sync_pipe[0]);
    if (setsid() < 0) {
        fail("setsid");
    }
    pid_t grandchild = fork();
    if (grandchild < 0) {
        fail("second fork");
    }
    if (grandchild > 0) {
        close(ancestry_pipe[1]);
        wait_for_ready(ancestry_pipe[0]);
        _exit(0);
    }

    close(ancestry_pipe[0]);
    signal(SIGTERM, SIG_IGN);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    write_pid_file(pid_path);
    register_owned_process();
    wait_for_registration_ack();
    acknowledge_ready(ancestry_pipe[1]);
    acknowledge_ready(sync_pipe[1]);
    remain_alive();
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s MODE PID_FILE\n", argv[0]);
        return 64;
    }
    if (strcmp(argv[1], "close-pipes") == 0) {
        close_output_pipes_descendant(argv[2]);
    }
    if (strcmp(argv[1], "double-fork-setsid") == 0) {
        double_fork_sets_id_descendant(argv[2]);
    }
    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 64;
}

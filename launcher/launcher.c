/* Runs its arguments as a child and waits, so launchd's job process is this
 * bundled, signed executable. macOS attributes the child's Calendar access
 * request to this bundle, which is the only thing that gets a permission
 * prompt when launched by launchd. exec() would hand the process image to
 * the child and lose that identity. */
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s program [args...]\n", argv[0]);
        return 64;
    }
    pid_t pid;
    int status;
    if (posix_spawn(&pid, argv[1], NULL, NULL, &argv[1], environ) != 0) {
        perror("posix_spawn");
        return 71;
    }
    if (waitpid(pid, &status, 0) < 0) {
        perror("waitpid");
        return 71;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

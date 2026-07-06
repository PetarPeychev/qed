#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

// forkpty + exec an interactive shell on the child side. Returns the master fd
// (-1 on failure) and writes the child pid to *out_pid.
int qed_pty_spawn(int rows, int cols, const char *shell, const char *cwd, int *out_pid) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) { /* fall through with inherited cwd */ }
        }
        setenv("TERM", "xterm-256color", 1);
        signal(SIGPIPE, SIG_DFL);
        execl(shell, shell, "-i", (char *)NULL);
        _exit(127);
    }
    *out_pid = pid;
    return master;
}

void qed_pty_resize(int fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(fd, TIOCSWINSZ, &ws);
}

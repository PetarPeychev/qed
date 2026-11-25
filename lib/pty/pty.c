#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <sys/ioctl.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>

extern char **environ;

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

int qed_pty_spawn(int rows, int cols, char *const argv[], char **envp, const char *cwd, int *out_pid) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    /* not forkpty: its master lacks O_CLOEXEC until the caller sets it, so a concurrent fork could inherit it */
    int master = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) {
        return -1;
    }
    char name[128];
    if (grantpt(master) != 0 || unlockpt(master) != 0 || ptsname_r(master, name, sizeof name) != 0) {
        close(master);
        return -1;
    }
    /* set before fork: a TIOCSWINSZ in the child signals itself, and its inherited SIGWINCH handler writes the parent's resize pipe */
    ioctl(master, TIOCSWINSZ, &ws);
    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        return -1;
    }
    if (pid == 0) {
        close(master);
        setsid();
        int slave = open(name, O_RDWR);
        if (slave < 0) {
            _exit(127);
        }
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) {
            close(slave);
        }
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) {}
        }
        environ = envp;
        signal(SIGPIPE, SIG_DFL);
        execvp(argv[0], argv);
        _exit(127);
    }
    *out_pid = pid;
    return master;
}

int qed_pty_open(int rows, int cols, int *out_master, int *out_slave) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) {
        return -1;
    }
    *out_master = master;
    *out_slave = slave;
    return 0;
}

void qed_pty_cell_pixels(int fd, int *w, int *h) {
    struct winsize ws;
    *w = *h = 0;
    if (fd >= 0 && ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
        *w = ws.ws_xpixel / ws.ws_col;
        *h = ws.ws_ypixel / ws.ws_row;
    }
}

void qed_pty_resize(int fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(fd, TIOCSWINSZ, &ws);
}

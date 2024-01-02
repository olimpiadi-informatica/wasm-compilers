#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <netdb.h>
#include <pwd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/vfs.h>
#include <unistd.h>

uid_t getuid(void) { return 1000; }
int getsid(int pid) {
  if (pid == 0 || pid == getpid())
    return getpid();
  return -1;
}
int gethostname(char *name, size_t len) {
  strncpy(name, "wasi", len);
  return 0;
}
char *realpath(const char *path, char *resolved_path) {
  if (resolved_path == NULL) {
    resolved_path = (char *)malloc(PATH_MAX);
  }
  if (resolved_path != NULL) {
    strcpy(resolved_path, path);
  }
  return resolved_path;
}

static int fillstatvfs(struct statvfs *buf) {
  memset(buf, 0, sizeof(*buf));
  buf->f_frsize = 512;
  buf->f_bfree = 1024 * 1024;
  buf->f_blocks = buf->f_bfree * 2;
  buf->f_bavail = buf->f_bfree;
  return 0;
}

int statvfs(const char *path, struct statvfs *buf) { return fillstatvfs(buf); }
int fstatvfs(int fd, struct statvfs *buf) { return fillstatvfs(buf); }

mode_t umask(mode_t mask) { return 0; }
int chmod(const char *pathname, mode_t mode) { return 0; }
int fchmod(int fd, mode_t mode) { return 0; }
int fchmodat(int fd, const char *path, mode_t mode, int flags) { return 0; }
int fchown(int fd, uid_t owner, gid_t group) { return 0; }
unsigned alarm(unsigned seconds) { return 0; }
int socket(int domain, int type, int protocol) {
  errno = EACCES;
  return -1;
}
int bind(int fd, const struct sockaddr *addr, socklen_t len) {
  errno = EBADF;
  return -1;
}
int connect(int fd, const struct sockaddr *addr, socklen_t len) {
  errno = EBADF;
  return -1;
}
int listen(int fd, int n) {
  errno = EBADF;
  return -1;
}

int sigemptyset(sigset_t *set) {
  memset(set, 0, sizeof(*set));
  return 0;
}
int sigfillset(sigset_t *set) {
  memset(set, -1U, sizeof(*set));
  return 0;
}
int sigaddset(sigset_t *set, int sig) {
  set->__val[0] |= (1 << sig);
  return 0;
}
int sigdelset(sigset_t *set, int sig) {
  set->__val[0] &= ~(1 << sig);
  return 0;
}
int sigismember(const sigset_t *set, int sig) {
  return (set->__val[0] & ~(1 << sig)) ? 1 : 0;
}

// LLVM wants to install signal handlers, so failing here causes it not to
// produce any output. Pretend we succeeded and do nothing instead.
int sigprocmask(int how, const sigset_t *set, sigset_t *oset) {
  if (oset) {
    sigemptyset(oset);
  }
  return 0;
}

int sigaction(int sig, const struct sigaction *restrict act,
              struct sigaction *restrict oact) {
  if (oact) {
    oact->sa_handler = SIG_DFL;
  }
  return 0;
}

int posix_madvise(void *addr, size_t len, int advice) { return 0; }

int getpwnam_r(const char *restrict name, struct passwd *restrict pwd,
               char buf[], size_t buflen, struct passwd **restrict result) {
  *result = NULL;
  return ENOENT;
}
int getpwuid_r(uid_t uid, struct passwd *restrict pwd, char buf[],
               size_t buflen, struct passwd **restrict result) {
  *result = NULL;
  return ENOENT;
}

int mprotect(void *addr, size_t len, int prot) {
  if (prot == (PROT_READ | PROT_WRITE)) {
    return 0;
  }
  errno = ENOTSUP;
  return -1;
}

int getrlimit(int resource, struct rlimit *rlp) {
  errno = EINVAL;
  return -1;
}

int setrlimit(int resource, const struct rlimit *rlp) {
  errno = EINVAL;
  return -1;
}

int dup(int oldfd) {
  errno = EBADF;
  return -1;
}

int dup2(int oldfd, int newfd) {
  errno = EBADF;
  return -1;
}

// For Python
#undef h_errno
int h_errno = HOST_NOT_FOUND;
int *__h_errno_location(void) { return &h_errno; }
struct servent *getservbyname(const char *name, const char *proto) {
  return NULL;
}
struct servent *getservbyport(int port, const char *proto) {
  return NULL;
}
struct hostent *gethostbyname(const char *name) {
  return NULL;
}
struct hostent *gethostbyaddr(const void *addr, socklen_t len, int type) {
  return NULL;
}
const char *hstrerror(int err) { return "host not found"; }
struct protoent *getprotobyname(const char *name) {
  return NULL;
}

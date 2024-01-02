#include <stdlib.h>
#include <sys/types.h>

extern "C" char *realpath(const char *path, char *resolved_path) throw();
extern "C" int getsid(int pid);

#define MNT_LOCAL 1

// fake statvfs for LLVM that always returns a FS with half a gig used and free.
struct statvfs {
  unsigned f_blocks;
  unsigned f_bfree;
  unsigned f_bavail;
  unsigned f_frsize;
  unsigned f_flags;
};

extern "C" int statvfs(const char *path, struct statvfs *buf);
extern "C" int fstatvfs(int fd, struct statvfs *buf);

extern "C" mode_t umask(mode_t mask);
extern "C" int chmod(const char *pathname, mode_t mode);
extern "C" int fchmod(int fd, mode_t mode);
extern "C" int fchown(int fd, uid_t owner, gid_t group);
extern "C" unsigned alarm(unsigned seconds);

#include "wasi_shim.h"

#include <condition_variable>
#include <future>
#include <limits.h>
#include <mutex>
#include <shared_mutex>
#include <stdlib.h>
#include <string.h>

// This file commits all sorts of crimes.

extern "C" int __cxa_atexit(void (*func)(void *), void *arg, void *dso_handle);
extern "C" int __cxa_thread_atexit(void (*func)(void *), void *arg,
                                   void *dso_handle) {
  return __cxa_atexit(func, arg, dso_handle);
}

extern "C" int getpid() { return 12345; }
extern "C" int gethostname(char *name, size_t len) {
  strncpy(name, "wasi", len);
  return 0;
}
extern "C" char *realpath(const char *path, char *resolved_path) throw() {
  if (resolved_path == nullptr) {
    resolved_path = (char *)malloc(PATH_MAX);
  }
  if (resolved_path != nullptr) {
    strcpy(resolved_path, path);
  }
  return resolved_path;
}

static constexpr size_t kThreadKeyCapacity = 1024;
static std::pair<void *, void (*)(void *)>
    thread_key_storage[kThreadKeyCapacity];
static size_t thread_key_size;

__attribute__((destructor)) void cleanup_thread_key() {
  for (size_t _ = 0; _ < 100; _++) {
    bool run = false;
    for (size_t i = 0; i < thread_key_size; i++) {
      auto &kv = thread_key_storage[i];
      if (kv.first) {
        auto v = kv.first;
        kv.first = nullptr;
        kv.second(v);
        run = true;
      }
    }
    if (!run) {
      return;
    }
  }
}

extern "C" int pthread_key_create(pthread_key_t *key,
                                  void (*destructor)(void *)) {
  if (thread_key_size == kThreadKeyCapacity) {
    return EAGAIN;
  }
  *key = thread_key_size++;
  if (!destructor) {
    destructor = +[](void *) {};
  }
  thread_key_storage[*key] = std::make_pair(nullptr, destructor);
  return 0;
}
extern "C" int pthread_key_delete(pthread_key_t key) {
  thread_key_storage[key].first = nullptr;
  return 0;
}
extern "C" int pthread_setspecific(pthread_key_t key, const void *value) {
  thread_key_storage[key].first = const_cast<void *>(value);
  return 0;
}

extern "C" void *pthread_getspecific(pthread_key_t key) {
  return thread_key_storage[key].first;
}

extern "C" int pthread_detach(pthread_t th) { return 0; }

extern "C" int pthread_create(pthread_t *__restrict__ thread,
                              const pthread_attr_t *__restrict__ attr,
                              void *(*start_routine)(void *),
                              void *__restrict__ arg) {
  return EAGAIN;
}

namespace std {
inline namespace __2 {
__shared_mutex_base::__shared_mutex_base() {}
recursive_mutex::recursive_mutex() {}
recursive_mutex::~recursive_mutex() {}
void recursive_mutex::lock() {}
void recursive_mutex::unlock() noexcept {}
mutex::~mutex() noexcept {}
void mutex::lock() {}
void mutex::unlock() noexcept {}
condition_variable::~condition_variable() {}
void condition_variable::wait(
    std::__2::unique_lock<std::__2::mutex> &) noexcept {}
void condition_variable::notify_all() noexcept {}
} // namespace __2
} // namespace std

#include "llvm/libcxx/src/future.cpp"
#include "llvm/libcxx/src/thread.cpp"

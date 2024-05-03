PYTHON := /usr/bin/env python3
DIR := $(shell pwd)
SYSROOT := ${DIR}/build/sysroot
CLANG_VERSION := $(shell /usr/bin/env bash ./llvm_version_major.sh llvm-project)

OUTPUT := ${DIR}/build/output

LLVM_HOST := ${DIR}/build/llvm-host

WASM_CC := ${LLVM_HOST}/bin/clang
WASM_CXX := ${LLVM_HOST}/bin/clang++
WASM_NM := ${LLVM_HOST}/bin/llvm-nm
WASM_AR := ${LLVM_HOST}/bin/llvm-ar
WASM_CFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals
WASM_CXXFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals
WASM_LDFLAGS := -Wl,-z -Wl,stack-size=10485760 \
								-Wl,--shared-memory -Wl,--export-memory -Wl,--import-memory \
								-Wl,--max-memory=4294967296 \
								-Wl,--initial-memory=41943040
MAKE := make

all: ${OUTPUT}.DONE test

build:
	mkdir -p build

build/llvm-host.BUILT: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-host-src
	cmake -S build/llvm-host-src/llvm -B build/llvm-host-build \
		-DCMAKE_INSTALL_PREFIX="${DIR}/build/llvm-host" -DDEFAULT_SYSROOT=${SYSROOT} \
		-DCMAKE_BUILD_TYPE=Release \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi-threads \
		-DLLVM_ENABLE_PROJECTS="clang;lld"
	$(MAKE) -C build/llvm-host-build install
	touch $@

build/wasi-libc.BUILT: wasi-libc build/llvm-host.BUILT | build
	rsync -a --delete wasi-libc/ build/wasi-libc
	$(MAKE) -C build/wasi-libc THREAD_MODEL=posix \
		CC=${WASM_CC} AR=$(WASM_AR) NM=${WASM_NM} EXTRA_CFLAGS="${WASI_CFLAGS} -O2 -DNDEBUG" \
		INSTALL_DIR=${SYSROOT} install
	touch $@

build/llvm.SRC: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-src
	touch $@

build/compiler-rt-host.BUILT: build/llvm.SRC build/wasi-libc.BUILT
	mkdir -p build/compiler-rt-build-host
	cmake -B build/compiler-rt-build-host -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_C}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=wasi \
		-DCMAKE_INSTALL_PREFIX=${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build-host install
	touch $@ 

build/compiler-rt.BUILT: build/llvm.SRC build/compiler-rt-host.BUILT
	mkdir -p build/compiler-rt-build
	cmake -B build/compiler-rt-build -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_C}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=wasi \
		-DCMAKE_INSTALL_PREFIX=${SYSROOT}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build install
	touch $@ 

build/libcxx.BUILT: build/compiler-rt.BUILT
	mkdir -p build/libcxx-build
	# We disable checking the C++ compiler as we are building -lc++, which is needed by the check.
	cmake -B build/libcxx-build -S build/llvm-src/runtimes \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSROOT=$(SYSROOT) -DCMAKE_INSTALL_PREFIX="${SYSROOT}" -DDEFAULT_SYSROOT="/" \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_C}" \
		-DCMAKE_CXX_FLAGS="-I${DIR} ${WASM_CXXFLAGS} -fno-exceptions" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
		-DCMAKE_C_COMPILER_WORKS=ON \
		-DCMAKE_CXX_COMPILER_WORKS=ON \
		-DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLIBCXX_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXX_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT:BOOL=OFF \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_HAS_MUSL_LIBC:BOOL=ON \
    -DLIBCXX_ABI_VERSION=2 \
    -DLIBCXXABI_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXXABI_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXXABI_SILENT_TERMINATE:BOOL=ON \
		-DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
		-DLIBCXX_LIBDIR_SUFFIX=/wasm32-wasi-threads \
		-DLIBCXXABI_LIBDIR_SUFFIX=/wasm32-wasi-threads
	$(MAKE) -C build/libcxx-build install
	touch $@ 

build/llvm.BUILT: build/llvm.SRC build/libcxx.BUILT
	cmake -B build/llvm-build -S build/llvm-src/llvm \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSROOT=$(SYSROOT) -DCMAKE_INSTALL_PREFIX="${SYSROOT}" -DDEFAULT_SYSROOT=/ \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_C}" \
		-DCMAKE_CXX_FLAGS="-I${DIR} ${WASM_CXXFLAGS} -fno-exceptions" \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_ENABLE_PROJECTS="clang;lld;clang-tools-extra" \
		-DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi-threads \
		-DLLVM_INCLUDE_TESTS=OFF -DCLANG_PLUGIN_SUPPORT=OFF \
		-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
		-DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="${WASM_LDFLAGS}"
	$(MAKE) -C build/llvm-build install
	touch "$@"

# Technically, this only needs wasi-libc, but errors get hidden otherwise.
build/python.BUILT: build/wasi-libc.BUILT build/llvm.BUILT
	rsync -a --delete cpython/ build/cpython
	sed -i s/-Wl,--max-memory=10485760// build/cpython/configure
	mkdir -p build/cpython/host-build
	cd build/cpython/host-build && ../configure --prefix=${DIR}/build/cpython/install --disable-test-modules
	$(MAKE) -C build/cpython/host-build
	mkdir -p build/cpython/wasm-build
	cd build/cpython/wasm-build && \
		PATH=${LLVM_HOST}/bin:$$PATH LDFLAGS="${WASM_LDFLAGS}" CFLAGS="${WASM_CFLAGS}" \
		../configure --target wasm32-wasi --host wasm32-wasi --build=$(shell $(CC) -dumpmachine) \
		--with-build-python=${DIR}/build/cpython/host-build/python \
		CC=${WASM_CC} AR=${WASM_AR} NM=${WASM_NM} \
		--prefix=${DIR}/build/sysroot --with-lto=full \
		--enable-wasm-pthreads=yes --disable-test-modules \
		CONFIG_SITE=${DIR}/cpython-config-override
	$(MAKE) -C build/cpython/wasm-build install
	touch "$@"

${OUTPUT}/cpp.COPIED: build/llvm.BUILT build/python.BUILT
	mkdir -p ${OUTPUT}/cpp/{bin,lib,include}
	rsync -avL ${SYSROOT}/bin/clang++ ${SYSROOT}/bin/wasm-ld ${SYSROOT}/bin/clangd ${OUTPUT}/cpp/bin/
	rsync -avL ${SYSROOT}/lib/clang ${SYSROOT}/lib/wasm32-wasi-threads ${OUTPUT}/cpp/lib/
	rsync -avL ${SYSROOT}/include/c++ ${SYSROOT}/include/wasm32-wasi-threads ${OUTPUT}/cpp/include/
	touch "$@"

${OUTPUT}/python.COPIED: build/llvm.BUILT build/python.BUILT
	mkdir -p ${OUTPUT}/python/{bin,lib,include}
	rsync -avL ${SYSROOT}/bin/python3.12.wasm ${OUTPUT}/python/bin/
	rsync -avL ${SYSROOT}/lib/libpython3.12.a ${SYSROOT}/lib/python3.12 --exclude python3.12/config-3.12-wasm32-wasi ${OUTPUT}/python/lib/
	rsync -avL ${SYSROOT}/include/python3.12 ${OUTPUT}/python/include/
	touch "$@"

test: test.sh ${OUTPUT}/cpp.COPIED ${OUTPUT}/python.COPIED
	./test.sh

%.tar.br: %.COPIED
	tar c -C $* . | brotli --large_window=30 > $@

${OUTPUT}.DONE: ${OUTPUT}/cpp.tar.br ${OUTPUT}/python.tar.br

clean:
	rm -rf build/ cpython/cross-build

.PHONY: all test clean

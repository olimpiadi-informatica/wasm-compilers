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
WASM_CFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals -Oz
WASM_CXXFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals \
                 -stdlib=libstdc++ -I ${SYSROOT}/include/c++/15.0.0/wasm32-wasip1/ \
                 -I ${SYSROOT}/include/c++/15.0.0/ -Oz
WASM_LDFLAGS := -Wl,-z -Wl,stack-size=10485760 \
                ``-Wl,--shared-memory -Wl,--export-memory -Wl,--import-memory \
                ``-Wl,--max-memory=4294967296 \
                ``-Wl,--initial-memory=41943040 \
                ``-L${SYSROOT}/lib/

RUST_OPT_FLAGS := -Clink-args=--initial-memory=41943040 \
                  -Clink-args=--max-memory=4294967296 \
                  -C opt-level=z

WASM_OPT_FLAGS := -Oz -O4 -Oz -O4 -Oz

MAKE := make

RT_DIR := wasm32-unknown-wasip1-threads

all: ${OUTPUT}.DONE test

build:
	mkdir -p build

build/llvm-host.BUILT: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-host-src
	cmake -S build/llvm-host-src/llvm -B build/llvm-host-build \
		-DCMAKE_INSTALL_PREFIX="${DIR}/build/llvm-host" -DDEFAULT_SYSROOT=${SYSROOT} \
		-DCMAKE_BUILD_TYPE=Release \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasip1-threads \
		-DLLVM_ENABLE_PROJECTS="clang;lld"
	$(MAKE) -C build/llvm-host-build install
	rm -rf build/llvm-host-build
	touch $@

build/wasi-libc.BUILT: wasi-libc build/llvm-host.BUILT | build
	rsync -a --delete wasi-libc/ build/wasi-libc
	sed -i 's/#define DEFAULT_STACK_SIZE 131072/#define DEFAULT_STACK_SIZE 10485760/' \
		build/wasi-libc/libc-top-half/musl/src/internal/pthread_impl.h
	$(MAKE) -C build/wasi-libc THREAD_MODEL=posix \
		CC=${WASM_CC} AR=$(WASM_AR) NM=${WASM_NM} EXTRA_CFLAGS="${WASI_CFLAGS} -O2 -DNDEBUG" \
		INSTALL_DIR=${SYSROOT} install
	rm -rf build/wasi-libc
	touch $@

build/llvm.SRC: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-src
	touch $@

build/compiler-rt-host.BUILT: build/llvm.SRC build/wasi-libc.BUILT
	mkdir -p build/compiler-rt-build-host
	cmake -B build/compiler-rt-build-host -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=${RT_DIR} \
		-DCMAKE_INSTALL_PREFIX=${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build-host install
	mv ${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins-wasm32.a \
		${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins.a
	rm -rf build/compiler-rt-build-host
	touch $@

build/compiler-rt.BUILT: build/llvm.SRC build/compiler-rt-host.BUILT
	mkdir -p build/compiler-rt-build
	cmake -B build/compiler-rt-build -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=${RT_DIR} \
		-DCMAKE_INSTALL_PREFIX=${SYSROOT}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build install
	mv ${SYSROOT}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins-wasm32.a \
		${SYSROOT}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins.a
	rm -rf build/compiler-rt-build
	touch $@

LIBSTDCXX_FLAGS = -fsized-deallocation -Wno-unknown-warning-option -Wno-vla-cxx-extension \
		-Wno-unused-function -Wno-instantiation-after-specialization \
		-Wno-missing-braces -Wno-unused-variable -Wno-string-plus-int \
		-Wno-unused-parameter -fno-exceptions -Wno-init-priority-reserved \
		-Wno-invalid-constexpr

build/libstdcxx.BUILT: build/compiler-rt.BUILT
	rsync -a --delete gcc/ build/gcc
	mkdir -p build/gcc-build
	cd build/gcc-build && \
		PATH=${LLVM_HOST}/bin:$$PATH LDFLAGS="${WASM_LDFLAGS}" \
		CXXFLAGS="${LIBSTDCXX_FLAGS} ${WASM_CXXFLAGS}" \
		../gcc/libstdc++-v3/configure --prefix=${SYSROOT} \
		--host wasm32-wasip1 --target wasm32-wasip1 --build=$(shell $(CC) -dumpmachine) \
		CC=${WASM_CC} CXX=${WASM_CXX} AR=${WASM_AR} NM=${WASM_NM} \
		--enable-libstdcxx-threads --enable-shared=off -disable-libstdcxx-dual-abi \
		--enable-libstdcxx-filesystem-ts --enable-libstdcxx-time=yes
	cd build/gcc-build && PATH=${LLVM_HOST}/bin:$$PATH $(MAKE) \
		CFLAGS_FOR_TARGET="${WASM_CFLAGS} -fsized-deallocation" \
		CXXFLAGS_FOR_TARGET="${WASM_CXXFLAGS}" install
	rm -rf build/gcc-build
	touch "$@"

build/llvm.BUILT: build/llvm.SRC build/libstdcxx.BUILT
	cmake -B build/llvm-build -S build/llvm-src/llvm \
		-DCMAKE_BUILD_TYPE=MinSizeRel \
		-DCMAKE_SYSROOT=$(SYSROOT) -DCMAKE_INSTALL_PREFIX="${SYSROOT}" -DDEFAULT_SYSROOT=/ \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCMAKE_CXX_FLAGS="-I${DIR} ${WASM_CXXFLAGS} -fno-exceptions" \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_ENABLE_PROJECTS="clang;lld;clang-tools-extra" \
		-DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly \
		-DLLVM_TOOL_LLVM_DRIVER_BUILD=ON \
		-DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasip1-threads \
		-DLLVM_INCLUDE_TESTS=OFF -DCLANG_PLUGIN_SUPPORT=OFF \
		-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
		-DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="${WASM_LDFLAGS}" \
		-DCMAKE_CXX_FLAGS_MINSIZEREL="-Oz -DNDEBUG" \
		-DCMAKE_C_FLAGS_MINSIZEREL="-Oz -DNDEBUG" \
		-DCMAKE_ASM_FLAGS_MINSIZEREL="-Oz -DNDEBUG"
	$(MAKE) -C build/llvm-build install
	rm -rf build/llvm-build
	touch "$@"

build/python.BUILT: cpython build/wasi-libc.BUILT
	rsync -a --delete cpython/ build/cpython
	sed -i s/-Wl,--max-memory=10485760// build/cpython/configure
	sed -i s/wasm32-wasi-threads/wasm32-wasip1-threads/g build/cpython/Misc/platform_triplet.c build/cpython/configure.ac build/cpython/configure
	mkdir -p build/cpython/host-build
	cd build/cpython/host-build && ../configure --prefix=${DIR}/build/cpython/install \
		--disable-test-modules --with-pkg-config=no
	$(MAKE) -C build/cpython/host-build
	mkdir -p build/cpython/wasm-build
	cd build/cpython/wasm-build && \
		PATH=${LLVM_HOST}/bin:$$PATH LDFLAGS="${WASM_LDFLAGS}" CFLAGS="${WASM_CFLAGS}" \
		../configure --target wasm32-wasip1 --host wasm32-wasip1 \
		--build=$(shell $(CC) -dumpmachine) \
		--with-build-python=${DIR}/build/cpython/host-build/python \
		CC=${WASM_CC} AR=${WASM_AR} NM=${WASM_NM} \
		--prefix=${SYSROOT} --with-lto=full \
		--enable-wasm-pthreads=yes --disable-test-modules \
		--with-pkg-config=no \
		CONFIG_SITE=${DIR}/cpython-config-override
	$(MAKE) -C build/cpython/wasm-build install
	rm -rf build/cpython
	touch "$@"

build/ruff.SRC: ruff ruff.patch ignore.patch
	rsync -a --delete ruff/ build/ruff
	cd build/ruff && patch -p1 < ../../ruff.patch
	rsync -a --delete ripgrep/ build/ripgrep
	cd build/ripgrep && patch -p1 < ../../ignore.patch
	touch "$@"

build/ruff.BUILT: build/ruff.SRC
	cd build/ruff && rustup target add wasm32-wasip1-threads
	cd build/ruff && RUSTFLAGS="${RUST_OPT_FLAGS}" cargo build --target wasm32-wasip1-threads --release
	touch "$@"

build/cpp.clangd.OPT: build/llvm.BUILT
	mkdir -p ${OUTPUT}/cpp/bin
	wasm-opt ${WASM_OPT_FLAGS} ${SYSROOT}/bin/clangd -o ${OUTPUT}/cpp/bin/clangd
	touch "$@"

build/cpp.llvm.OPT: build/llvm.BUILT
	mkdir -p ${OUTPUT}/cpp/bin
	wasm-opt ${WASM_OPT_FLAGS} ${SYSROOT}/bin/llvm -o ${OUTPUT}/cpp/bin/llvm
	touch "$@"

build/python.OPT: build/python.BUILT
	mkdir -p ${OUTPUT}/python/bin
	wasm-opt ${WASM_OPT_FLAGS} ${SYSROOT}/bin/python3.13.wasm -o ${OUTPUT}/python/bin/python3.13.wasm
	touch "$@"

build/ruff.OPT: build/ruff.BUILT
	mkdir -p ${OUTPUT}/python/bin
	wasm-opt ${WASM_OPT_FLAGS} build/ruff/target/wasm32-wasip1-threads/release/ruff.wasm -o ${OUTPUT}/python/bin/ruff.wasm
	rm -rf build/ruff
	touch "$@"

${OUTPUT}/cpp.COPIED: build/llvm.BUILT build/cpp.clangd.OPT build/cpp.llvm.OPT
	mkdir -p ${OUTPUT}/cpp/{bin,lib,include}
	rsync -avL ${SYSROOT}/lib/clang ${SYSROOT}/lib/wasm32-wasip1-threads ${OUTPUT}/cpp/lib/
	rsync -avL ${SYSROOT}/include/c++ ${SYSROOT}/include/wasm32-wasip1-threads ${OUTPUT}/cpp/include/
	rsync -avL ${SYSROOT}/lib/libsupc++.a ${SYSROOT}/lib/libstdc++.a ${OUTPUT}/cpp/lib/
	mkdir -p ${OUTPUT}/cpp/include/bits
	touch "$@"

${OUTPUT}/python.COPIED: build/llvm.BUILT build/python.BUILT build/python.OPT build/ruff.OPT
	mkdir -p ${OUTPUT}/python/{bin,lib,include}
	rsync -avL --exclude __pycache__ --exclude config-3.13-wasm32-wasi ${SYSROOT}/lib/python3.13 ${OUTPUT}/python/lib/
	touch "$@"

test: test.sh ${OUTPUT}/cpp.COPIED ${OUTPUT}/python.COPIED
	./test.sh

%.tar: %.COPIED
	tar c -C $* . > $@

%.tar.br: %.tar
	brotli $<

${OUTPUT}.DONE: ${OUTPUT}/cpp.tar.br ${OUTPUT}/python.tar.br

clean:
	rm -rf build/ cpython/cross-build

.PHONY: all test clean

.NOTINTERMEDIATE:

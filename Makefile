WASI_SDK_PREFIX ?= /opt/wasi-sdk/
PYTHON ?= /usr/bin/env python3
DIR := $(shell pwd)
WASMTIME ?= $(shell which wasmtime)
WASMTIME_FLAGS ?= --wasm max-wasm-stack=8388608 --dir {HOST_DIR}::{GUEST_DIR} \
	--env {ENV_VAR_NAME}={ENV_VAR_VALUE} {PYTHON_WASM}

.PHONY:
all: test build/output.tar.br

build/output.tar.br: build/output/python build/output/cpp
	tar c -C build/output . | brotli --large_window=30 > $@

build/output/python:
	rm -rf "$@"
	${PYTHON} cpython/Tools/wasm/wasi.py build \
		--host-runner="${WASMTIME} run ${WASMTIME_FLAGS}" -- \
		--prefix="${DIR}/$@" --exec-prefix="${DIR}/$@" \
		--disable-test-modules
	make -C cpython/cross-build/wasm32-wasi install

build/libwasishim.a: wasi_shim.cpp
	${WASI_SDK_PREFIX}/bin/clang++ -fno-exceptions -std=c++20 $< -O3 -c -o $@

build/llvm-sources: llvm.patch
	rm -rf "$@"
	cp -r llvm "$@"
	cd "$@" && patch -p1 < ${DIR}/llvm.patch

build/llvm-build: build/llvm-sources build/libwasishim.a
	cmake -B build/llvm-build build/llvm-sources/llvm \
		-G Ninja -DCMAKE_BUILD_TYPE=Release \
		-DWASI_SDK_PREFIX=${WASI_SDK_PREFIX} \
		-DCMAKE_TOOLCHAIN_FILE=${WASI_SDK_PREFIX}/share/cmake/wasi-sdk.cmake \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_ENABLE_PROJECTS="clang;lld" \
		-DLLVM_ENABLE_THREADS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi -DCMAKE_MODULE_PATH=${DIR}/cmake \
		-DCMAKE_CXX_FLAGS="-I${DIR} -fno-exceptions" -DLLVM_INCLUDE_TESTS=OFF \
		-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
		-DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
		-DCLANG_PLUGIN_SUPPORT=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="-Wl,-z -Wl,stack-size=1048576 -lwasishim -L${DIR}/build"
	ninja -C build/llvm-build


build/output/cpp: build/llvm-build
	rm -rf "$@"
	mkdir -p $@/root
	cp -Lr ${WASI_SDK_PREFIX}/share/wasi-sysroot/* $@/root/
	cp -L ${WASI_SDK_PREFIX}/lib/clang/*/lib/wasi/libclang_rt.* $@/root/lib/wasm32-wasi/
	rm -rf $@/root/share/wasm32-wasi-threads $@/root/lib/wasm32-wasi-threads
	cp -Lr $</lib/clang/18/include $@/root/clang-include
	cp -Lr $</bin/clang-18 $@/clang
	cp -Lr $</bin/lld $@/wasm-ld

.PHONY:
test: | build/output/python build/output/cpp
	./test.sh

clean:
	rm -rf build/ cpython/cross-build

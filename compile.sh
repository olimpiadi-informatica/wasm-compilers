#!/bin/sh

set -xe

WASI_SDK_PREFIX=${WASI_SDK_PATH:-/opt/wasi-sdk/}

DIR=$PWD


pushd llvm
git checkout .
patch -p1 < ../llvm.patch
popd

$WASI_SDK_PREFIX/bin/clang++ -fno-exceptions -std=c++20 \
  wasi_shim.cpp -O3 -c -o build/libwasishim.a


rm -rf llvm-build
mkdir -p llvm-build
pushd llvm-build
cmake ../llvm/llvm -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DWASI_SDK_PREFIX=${WASI_SDK_PREFIX} \
  -DCMAKE_TOOLCHAIN_FILE=${WASI_SDK_PREFIX}/share/cmake/wasi-sdk.cmake \
  -DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_ENABLE_THREADS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi -DCMAKE_MODULE_PATH=$DIR/cmake \
  -DCMAKE_CXX_FLAGS="-I$DIR -fno-exceptions" -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
  -DCLANG_PLUGIN_SUPPORT=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--stack-first -Wl,-z -Wl,stack-size=1048576 -lwasishim -L$DIR/build"
ninja
popd

rm -rf build/output
mkdir -p build/output/root
cp -Lr ${WASI_SDK_PREFIX}/share/wasi-sysroot/* build/output/root/
cp -L ${WASI_SDK_PREFIX}/lib/clang/*/lib/wasi/libclang_rt.builtins-wasm32.a build/output/root/lib/wasm32-wasi/
rm -rf build/output/root/share/wasm32-wasi-threads build/output/root/lib/wasm32-wasi-threads
cp -Lr llvm-build/lib/clang/18/include build/output/root/clang-include
cp -Lr llvm-build/bin/clang-18 build/output/clang
cp -Lr llvm-build/bin/lld build/output/wasm-ld

(cd build/output && tar c .) | brotli > build/output.tar.br

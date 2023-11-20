#!/bin/bash

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
cmake ../llvm/llvm -G Ninja -DCMAKE_BUILD_TYPE=Release -DWASI_SDK_PREFIX=${WASI_SDK_PREFIX} \
  -DCMAKE_TOOLCHAIN_FILE=${WASI_SDK_PREFIX}/share/cmake/wasi-sdk.cmake \
  -DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_ENABLE_THREADS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi -DCMAKE_MODULE_PATH=$DIR/cmake \
  -DCMAKE_CXX_FLAGS="-I$DIR -fno-exceptions" -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
  -DCLANG_PLUGIN_SUPPORT=OFF -DCMAKE_EXE_LINKER_FLAGS="-lwasishim -L$DIR/build"
ninja
popd

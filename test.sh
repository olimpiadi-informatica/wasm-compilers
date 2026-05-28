#!/usr/bin/env bash

set -xe

ROOT=$PWD/build/output
CPPROOT=$ROOT/cpp
PYROOT=$ROOT/python
RSROOT=$ROOT/rust

DIR=build/test

$(which wasmtime) -W threads=y -S threads=y -W shared-memory=y --dir $PYROOT::/ \
  --env PYTHONPATH=/lib/python-3.13 \
  $PYROOT/bin/python3.13.wasm \
  -c "import json; print(json.dumps('hello'))"

mkdir -p $DIR
rsync -aL --delete $CPPROOT/ $DIR/

cat >$DIR/main.cc <<EOF
#include <bits/stdc++.h>
int main(int argc, char **argv) {
  std::vector<std::string> v;
  for (size_t i = 0; i < argc; i++) {
    v.push_back(argv[i]);
  }
  int a;
  scanf("%d", &a);
  printf("%d\\n", a);
  for (size_t i = 0; i < argc; i++) {
    fprintf(stderr, "%zu: %s\\n", i, v[i].c_str());
  }
  return 0;
}
EOF

$(which wasmtime) -W threads=y -S threads=y -W shared-memory=y --dir $DIR::/ \
  $DIR/bin/llvm clang++ -cc1 -isysroot / \
  "-resource-dir" "lib/clang/20" -I "/include/c++/15.0.0/wasm32-wasip1/" -I "/include/c++/15.0.0/" "-isysroot" "/" \
  "-internal-isystem" "lib/clang/20/include" "-internal-isystem" "/include/wasm32-wasip1-threads" "-internal-isystem" "/include" \
  "-target-feature" "+atomics" "-target-feature" "+bulk-memory" "-target-feature" "+mutable-globals" \
  "-stdlib=libstdc++" \
  -O2 -emit-obj main.cc -o main.wasm

$(which wasmtime) -W threads=y -S threads=y -W shared-memory=y --dir $DIR::/ \
  $DIR/bin/llvm wasm-ld \
  -L /lib/wasm32-wasip1-threads/ /lib/clang/20/lib/wasm32-unknown-wasip1-threads/libclang_rt.builtins.a \
  -lc /lib/wasm32-wasip1-threads/crt1.o \
  -L /lib -lstdc++ -lsupc++ \
  -z stack-size=1048576 --shared-memory --import-memory --export-memory --max-memory=4294967296 \
  main.wasm -o main

$(which wasmtime) -W threads=y -S threads=y -W shared-memory=y $DIR/main a b c d <<<13845

rsync -aL --delete $RSROOT/ $DIR/

cat >$DIR/main.rs <<EOF
fn main() {
    let mem = Box::new('exit: loop {
        break 'exit 5;
    });
    println!("Hello from a WebAssembly-compiled Rust compiler! {mem}");
}
EOF

$(which wasmtime) -W threads=y -W shared-memory=y -S threads=y --dir $DIR::/ \
  $DIR/bin/rustc \
  --target wasm32-wasip1-threads \
  --sysroot / \
  -Zno-parallel-backend \
  -Z threads=1 \
  -C codegen-units=1 \
  -C target-feature=+atomics,+bulk-memory,+mutable-globals \
  main.rs

$(which wasmtime) -W threads=y -S threads=y -W shared-memory=y --dir $DIR::/ \
  $DIR/main.wasm

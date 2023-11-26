#!/bin/sh

set -xe

DIR=build/fs

rm -rf $DIR
mkdir -p $DIR
brotli -d --stdout build/output.tar.br | tar x -C $DIR
cat > $DIR/root/main.cc << EOF
#include <stdio.h>
#include <string>
#include <vector>
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

wasmtime --dir $DIR/root/::/ \
  $DIR/clang -cc1 \
  -I /include/c++/v1/ -I /clang-include/ -I /include/ \
  -O2 -emit-obj main.cc -o main.wasm

wasmtime --dir $DIR/root::/ \
  $DIR/wasm-ld \
  -L /lib/wasm32-wasi/ \
  -lc -lclang_rt.builtins-wasm32 /lib/wasm32-wasi/crt1.o \
  -lc++ -lc++abi main.wasm -o main 

wasmtime $DIR/root/main a b c d <<< 13845

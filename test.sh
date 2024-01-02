#!/bin/sh

set -xe

ROOT=$PWD/build/output
CPPROOT=$ROOT/cpp
PYROOT=$ROOT/python

$(which wasmtime) run --dir $PYROOT::/ \
  --env PYTHONPATH=/lib/python-3.13 \
  $PYROOT/bin/python3.13.wasm \
  -c "import json; print(json.dumps('hello'))"

DIR=build/test

rm -rf $DIR
mkdir -p $DIR
cp -r $CPPROOT/* $DIR

cat > $DIR/main.cc << EOF
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

wasmtime --dir $DIR::/ \
  $DIR/bin/clang++ -cc1 -isysroot / \
  "-resource-dir" "lib/clang/18" -I /include/c++/v1 "-isysroot" "/" \
  "-internal-isystem" "lib/clang/18/include" "-internal-isystem" "/include/wasm32-wasi" "-internal-isystem" "/include" \
  -O2 -emit-obj main.cc -o main.wasm

wasmtime --dir $DIR::/ \
  $DIR/bin/wasm-ld \
  -L /lib/wasm32-wasi/ /lib/clang/18/lib/wasi/libclang_rt.builtins-wasm32.a \
  -lc /lib/wasm32-wasi/crt1.o \
  -lc++ -lc++abi main.wasm -o main 

wasmtime $DIR/main a b c d <<< 13845

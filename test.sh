#!/usr/bin/env bash

set -xe

ROOT=$PWD/build/output
CPPROOT=$ROOT/cpp
PYROOT=$ROOT/python
RSROOT=$ROOT/rust

DIR=build/test

$(which wasmtime) -W threads=y -S threads=y --dir $PYROOT::/ \
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

$(which wasmtime) -W threads=y -S threads=y --dir $DIR::/ \
  $DIR/bin/llvm clang++ -cc1 -isysroot / \
  "-resource-dir" "lib/clang/20" -I "/include/c++/15.0.0/wasm32-wasip1/" -I "/include/c++/15.0.0/" "-isysroot" "/" \
  "-internal-isystem" "lib/clang/20/include" "-internal-isystem" "/include/wasm32-wasip1-threads" "-internal-isystem" "/include" \
  "-target-feature" "+atomics" "-target-feature" "+bulk-memory" "-target-feature" "+mutable-globals" \
  "-stdlib=libstdc++" \
  -O2 -emit-obj main.cc -o main.wasm

$(which wasmtime) -W threads=y -S threads=y --dir $DIR::/ \
  $DIR/bin/llvm wasm-ld \
  -L /lib/wasm32-wasip1-threads/ /lib/clang/20/lib/wasm32-unknown-wasip1-threads/libclang_rt.builtins.a \
  -lc /lib/wasm32-wasip1-threads/crt1.o \
  -L /lib -lstdc++ -lsupc++ \
  -z stack-size=1048576 --shared-memory --import-memory --export-memory --max-memory=4294967296 \
  main.wasm -o main

$(which wasmtime) -W threads=y -S threads=y $DIR/main a b c d <<<13845

rsync -aL --delete $RSROOT/ $DIR/

cat >$DIR/main.rs <<EOF
fn main() {
    let mem = Box::new('exit: loop {
        break 'exit 5;
    });
    println!("Hello from a WebAssembly-compiled Rust compiler! {mem}");
}
EOF

$(which wasmtime) -W threads=y -S threads=y --dir $DIR::/ \
  $DIR/bin/rustc \
  --target wasm32-wasip1-threads \
  --sysroot / \
  -Zno-parallel-backend \
  -Z threads=1 \
  -C codegen-units=1 \
  -C target-feature=+atomics,+bulk-memory,+mutable-globals \
  main.rs

$(which wasmtime) -W threads=y -S threads=y --dir $DIR::/ \
  $DIR/main.wasm

python3 - "$DIR" <<'EOF'
import json, os, subprocess, sys

root = sys.argv[1]
os.makedirs(os.path.join(root, "workdir"), exist_ok=True)
with open(os.path.join(root, "workdir/main.rs"), "w") as f:
    f.write("fn main(){let x:i32=1+2;println!(\"{}\",x);}\n")
with open(os.path.join(root, "workdir/rust-project.json"), "w") as f:
    json.dump({
        "sysroot": "/",
        "sysroot_src": "/lib/rustlib/src/rust/library",
        "crates": [{"root_module": "/workdir/main.rs", "edition": "2024", "deps": []}]
    }, f)

proc = subprocess.Popen(
    ["wasmtime", "-W", "threads=y", "-S", "threads=y", "--dir", f"{root}::/", f"{root}/bin/rust-analyzer"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE
)

def send(msg):
    body = json.dumps(msg).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()

def recv():
    length = 0
    while True:
        line = proc.stdout.readline()
        assert line, "EOF from rust-analyzer"
        if line.startswith(b"Content-Length: "):
            length = int(line[16:].strip())
        elif line == b"\r\n":
            return json.loads(proc.stdout.read(length))

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": "file:///workdir", "capabilities": {}}})
assert recv()["id"] == 1
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
    "textDocument": {"uri": "file:///workdir/main.rs", "languageId": "rust", "version": 1, "text": "fn main(){let v:Vec<i32>=Vec::new();v.}\n"}
}})
while True:
    msg = recv()
    if msg.get("method") == "textDocument/publishDiagnostics":
        break
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion", "params": {
    "textDocument": {"uri": "file:///workdir/main.rs"},
    "position": {"line": 0, "character": 38}
}})
while True:
    msg = recv()
    if msg.get("id") == 2:
        items = msg["result"] if isinstance(msg["result"], list) else msg["result"]["items"]
        assert any(it["label"].startswith("push") for it in items), f"Expected Vec::push completion, got {len(items)} items"
        break
send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
    "textDocument": {"uri": "file:///workdir/main.rs", "version": 2},
    "contentChanges": [{"text": "fn main(){let x:i32=1+2;println!(\"{}\",x);}\n"}]
}})
send({"jsonrpc": "2.0", "id": 3, "method": "textDocument/formatting", "params": {
    "textDocument": {"uri": "file:///workdir/main.rs"},
    "options": {"tabSize": 4, "insertSpaces": True}
}})
while True:
    msg = recv()
    if msg.get("id") == 3:
        assert msg.get("result"), f"Expected formatting edits, got {msg}"
        break
send({"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": None})
send({"jsonrpc": "2.0", "method": "exit", "params": None})
assert proc.wait(timeout=10) == 0
EOF

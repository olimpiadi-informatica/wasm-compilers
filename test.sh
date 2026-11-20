#!/usr/bin/env bash

set -xe

ROOT=$PWD/build/output
CPPROOT=$ROOT/cpp
PYROOT=$ROOT/python
RSROOT=$ROOT/rust
JAVAROOT=$ROOT/java

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

node --input-type=module - "$JAVAROOT" <<'EOF'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const javaRoot = process.argv[2];
const { load } = await import(pathToFileURL(path.join(javaRoot, 'compiler.wasm-runtime.js')).href);
const compilerBytes = fs.readFileSync(path.join(javaRoot, 'compiler.wasm'));
const compileSdk = new Int8Array(fs.readFileSync(path.join(javaRoot, 'compile-classlib-teavm.bin')));
const runtimeSdk = new Int8Array(fs.readFileSync(path.join(javaRoot, 'runtime-classlib-teavm.bin')));

const compilerMod = await load(compilerBytes, {});
const compiler = compilerMod.exports.createCompiler();
compiler.setSdk(compileSdk);
compiler.setTeaVMClasslib(runtimeSdk);
const diagnostics = [];
compiler.onDiagnostic(d => diagnostics.push(`${d.fileName}:${d.lineNumber}:${d.columnNumber}: ${d.severity}: ${d.message}`));
compiler.addSourceFile('Main.java', `
import java.io.*;
import java.math.BigInteger;
import java.util.*;

public class Main {
    public static void main(String[] args) throws Exception {
        Scanner sc = new Scanner(new File("input.txt"));
        int a = sc.nextInt();
        try (PrintWriter pw = new PrintWriter(new FileWriter("output.txt"))) {
            pw.println(a);
            List<String> list = new ArrayList<>(Arrays.asList(args));
            Collections.sort(list);
            pw.println("sorted=" + String.join(",", list));
            pw.println("big=" + BigInteger.valueOf(a).multiply(BigInteger.valueOf(2)));
        }
        IO.println("io=ok");
        for (int i = 0; i < args.length; i++) {
            System.err.println(i + ": " + args[i]);
        }
    }
}
`);
if (!compiler.compile()) {
    throw new Error('javac failed:\n' + diagnostics.join('\n'));
}
const mains = compiler.detectMainClasses();
if (mains.length !== 1 || mains[0] !== 'Main') {
    throw new Error('unexpected main classes: ' + JSON.stringify(mains));
}
if (!(await compiler.generateWebAssembly({ mainClass: 'Main', outputName: 'app', obfuscated: false, asyncEnabled: false }))) {
    throw new Error('TeaVM WasmGC codegen failed:\n' + diagnostics.join('\n'));
}
const appWasm = compiler.getWebAssemblyOutputFile('app.wasm');
const stdinBytes = Buffer.from('13845\n', 'utf8');
let stdinPos = 0;
let stdout = '';
let stderr = '';
const app = await load(appWasm, {
    installImports(imports) {
        imports.teavmConsole.putcharStdout = ch => { stdout += String.fromCharCode(ch); };
        imports.teavmConsole.putcharStderr = ch => { stderr += String.fromCharCode(ch); };
        imports.teavmConsole.readStdin = () => stdinPos < stdinBytes.length ? stdinBytes[stdinPos++] : -1;
        imports.teavmConsole.readStdinNonBlocking = () => stdinPos < stdinBytes.length ? stdinBytes[stdinPos++] : -1;
    }
});
app.exports.main(['d', 'b', 'a', 'c']);
const expectedOut = '13845\nsorted=a,b,c,d\nbig=27690\nio=ok\n';
const expectedErr = '0: d\n1: b\n2: a\n3: c\n';
if (stdout !== expectedOut) {
    throw new Error(`unexpected stdout:\n${JSON.stringify(stdout)}\nexpected:\n${JSON.stringify(expectedOut)}`);
}
if (stderr !== expectedErr) {
    throw new Error(`unexpected stderr:\n${JSON.stringify(stderr)}\nexpected:\n${JSON.stringify(expectedErr)}`);
}

// Verify Java LSP (diagnostics, completion, hover, signatureHelp, definition, references, rename, formatting)
const ls = compilerMod.exports.createLanguageServer();
ls.setSdk(compileSdk);
const lsNotifs = [];
ls.setNotificationHandler(msg => lsNotifs.push(JSON.parse(msg)));
let lsId = 1;
const lsReq = (method, params) => {
    const res = JSON.parse(ls.handleMessage(JSON.stringify({ jsonrpc: '2.0', id: lsId++, method, params })));
    if (res.error) throw new Error(`LSP ${method} error: ${JSON.stringify(res.error)}`);
    return res.result;
};
const lsNotify = (method, params) => ls.handleMessage(JSON.stringify({ jsonrpc: '2.0', method, params }));

const initRes = lsReq('initialize', { processId: null, rootUri: 'file:///workdir', capabilities: {} });
if (!initRes?.capabilities?.completionProvider || !initRes?.capabilities?.documentFormattingProvider) {
    throw new Error('unexpected LSP capabilities: ' + JSON.stringify(initRes));
}
lsNotify('initialized', {});
const helperUri = 'file:///workdir/Helper.java';
const mainUri = 'file:///workdir/Main.java';
lsNotify('textDocument/didOpen', {
    textDocument: {
        uri: helperUri, languageId: 'java', version: 1,
        text: 'public class Helper {\n    public static int computeSum(int a, int b) {\n        return a + b;\n    }\n}\n'
    }
});
const goodMain = 'import java.util.*;\npublic class Main {\n    public static void main(String[] args) {\n        ArrayList<String> list = new ArrayList<>();\n        list.add("hi");\n        String s = list.get(0);\n        int t = Helper.computeSum(1, 2);\n        System.out.println(s + t);\n    }\n}\n';
lsNotify('textDocument/didOpen', {
    textDocument: { uri: mainUri, languageId: 'java', version: 1, text: 'public class Main { public static void main(String[] a) { int x = "bad"; } }\n' }
});
const errNotif = lsNotifs.findLast(n => n.params?.uri === mainUri);
if (!errNotif?.params?.diagnostics?.length) {
    throw new Error('expected javac diagnostic on type error');
}
lsNotify('textDocument/didChange', { textDocument: { uri: mainUri, version: 2 }, contentChanges: [{ text: goodMain }] });
const hover = lsReq('textDocument/hover', { textDocument: { uri: mainUri }, position: { line: 5, character: 25 } });
if (!hover?.contents?.value?.includes('get(int index)')) {
    throw new Error('unexpected hover: ' + JSON.stringify(hover));
}
const def = lsReq('textDocument/definition', { textDocument: { uri: mainUri }, position: { line: 6, character: 26 } });
if (def?.uri !== helperUri) {
    throw new Error('unexpected definition: ' + JSON.stringify(def));
}
const refs = lsReq('textDocument/references', {
    textDocument: { uri: mainUri }, position: { line: 6, character: 26 }, context: { includeDeclaration: true }
});
if (refs?.length !== 2) {
    throw new Error('unexpected references: ' + JSON.stringify(refs));
}
const rename = lsReq('textDocument/rename', {
    textDocument: { uri: mainUri }, position: { line: 6, character: 26 }, newName: 'addNums'
});
if (!rename?.changes?.[helperUri] || !rename?.changes?.[mainUri]) {
    throw new Error('unexpected rename: ' + JSON.stringify(rename));
}
lsNotify('textDocument/didChange', {
    textDocument: { uri: mainUri, version: 3 },
    contentChanges: [{ text: goodMain.replace('list.add("hi");', 'list.') }]
});
const comp = lsReq('textDocument/completion', { textDocument: { uri: mainUri }, position: { line: 4, character: 13 } });
if (!comp?.items?.some(i => i.label === 'subList' && i.detail?.includes('fromIndex'))) {
    throw new Error('expected subList(fromIndex, toIndex) completion');
}
if (comp.items.some(i => i.label === 'modCount')) {
    throw new Error('protected field modCount should not appear in completion');
}
lsNotify('textDocument/didChange', {
    textDocument: { uri: mainUri, version: 4 },
    contentChanges: [{ text: goodMain.replace('list.add("hi");', 'list.subList(0, ') }]
});
const sig = lsReq('textDocument/signatureHelp', { textDocument: { uri: mainUri }, position: { line: 4, character: 24 } });
if (sig?.activeParameter !== 1 || sig?.signatures?.length !== 1) {
    throw new Error('unexpected signatureHelp: ' + JSON.stringify(sig));
}
lsNotify('textDocument/didChange', {
    textDocument: { uri: mainUri, version: 5 },
    contentChanges: [{ text: 'public class Main{public static void main(String[] args){int x=1+2;}}\n' }]
});
const fmt = lsReq('textDocument/formatting', { textDocument: { uri: mainUri }, options: { tabSize: 4, insertSpaces: true } });
if (!fmt?.[0]?.newText?.includes('    public static void main(String[] args) {\n        int x = 1 + 2;')) {
    throw new Error('unexpected formatting: ' + JSON.stringify(fmt));
}
lsReq('shutdown', null);
lsNotify('exit', null);
EOF

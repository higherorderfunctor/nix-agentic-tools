#!/usr/bin/env python3
"""Deterministic Bun standalone module-graph unpacker (Bun 1.4.x, Rust SMG)."""
import json, mmap, os, struct, sys

TRAILER = b"\n---- Bun! ----\n"
REC = 52  # size_of::<CompiledModuleGraphFile>
LOADERS = ["jsx","js","ts","tsx","css","file","json","jsonc","toml","wasm","napi",
           "base64","dataurl","text","bunsh","sqlite","sqlite-embedded","html",
           "yaml","json5","md","xml"]
ENC = {0:"binary",1:"latin1",2:"utf8"}
MODFMT = {0:"none",1:"esm",2:"cjs"}
SIDE = {0:"server",1:"client"}

def find_trailer(mm):
    """Last occurrence of the trailer in the file."""
    i = mm.rfind(TRAILER)
    if i < 0:
        raise SystemExit("no Bun trailer")
    return i

def main(exe, outdir):
    f = open(exe, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    tr = find_trailer(mm)
    end = tr + len(TRAILER)
    off = end - len(TRAILER) - 32          # size_of::<Offsets>() == 32
    (byte_count, moff, mlen, epid, caoff, calen, flags) = struct.unpack_from("<QIIIIII", mm, off)
    base = off - byte_count                 # graph base
    n = mlen // REC
    meta = dict(exe=os.path.basename(exe), file_size=len(mm), trailer_offset=tr,
                offsets_struct_offset=off, graph_base=base, byte_count=byte_count,
                modules_ptr=[moff, mlen], module_count=n, entry_point_id=epid,
                compile_exec_argv=[caoff, calen], flags=flags,
                modules_len_exact=(mlen % REC == 0))
    def sp(o, l):
        return mm[base + o: base + o + l] if l else b""
    os.makedirs(outdir, exist_ok=True)
    index = []
    for i in range(n):
        p = base + moff + i * REC
        v = struct.unpack_from("<12I", mm, p)
        enc, ld, mf, side = mm[p+48], mm[p+49], mm[p+50], mm[p+51]
        name = sp(v[0], v[1]).decode("utf-8", "replace")
        contents = sp(v[2], v[3])
        rel = name
        for pre in ("/$bunfs/root/", "/$bunfs/", "B:/~BUN/root/", "B:/~BUN/"):
            if rel.startswith(pre):
                rel = rel[len(pre):]; break
        rel = rel.lstrip("/") or f"module-{i}"
        dst = os.path.join(outdir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as o:
            o.write(contents)
        index.append(dict(i=i, name=name, path=rel,
                          contents=[v[2], v[3]], sourcemap=[v[4], v[5]],
                          bytecode=[v[6], v[7]], module_info=[v[8], v[9]],
                          bytecode_origin_path=sp(v[10], v[11]).decode("utf-8","replace"),
                          encoding=ENC.get(enc, enc),
                          loader=LOADERS[ld] if ld < len(LOADERS) else ld,
                          module_format=MODFMT.get(mf, mf), side=SIDE.get(side, side),
                          is_entry=(i == epid)))
        # sourcemaps, when present, next to the module
        if v[5]:
            with open(dst + ".bunmap", "wb") as o:
                o.write(sp(v[4], v[5]))
    meta["modules"] = index
    with open(os.path.join(outdir, "_graph.json"), "w") as o:
        json.dump(meta, o, indent=1)
    print(json.dumps({k: v for k, v in meta.items() if k != "modules"}, indent=1))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

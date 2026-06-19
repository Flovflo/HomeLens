#!/usr/bin/env python3
"""Bundle ffmpeg/ffprobe/node + their non-system dylibs into a macOS .app so it
runs with nothing installed. Rewrites install names to @rpath, re-signs ad-hoc
(required on Apple Silicon after install_name_tool)."""
import os, platform, shutil, subprocess, sys, re

HOMEBREW_PREFIXES = ("/opt/homebrew/", "/usr/local/opt/", "/usr/local/Cellar/", "/opt/homebrew/Cellar/")

def find(name, *fallbacks):
    return shutil.which(name) or next((p for p in fallbacks if os.path.exists(p)), None)

def thin(path):
    """Drop non-host slices from a universal binary to shrink the bundle."""
    arch = platform.machine()  # e.g. 'arm64'
    r = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    archs = r.stdout.split()
    if r.returncode == 0 and arch in archs and len(archs) > 1:
        subprocess.run(["lipo", path, "-thin", arch, "-output", path], capture_output=True)

def sh(*a): return subprocess.run(a, check=True, capture_output=True, text=True).stdout
def otool_deps(f):
    out = subprocess.run(["otool", "-L", f], capture_output=True, text=True).stdout
    deps = []
    for line in out.splitlines()[1:]:
        m = re.match(r"\s+(\S+)\s+\(", line)
        if m: deps.append(m.group(1))
    return deps

def is_bundleable(dep):
    return dep.startswith(HOMEBREW_PREFIXES) or dep.startswith("@rpath/") or dep.startswith("@loader_path/")

def resolve(dep, rpaths):
    if dep.startswith(HOMEBREW_PREFIXES):
        return dep if os.path.exists(dep) else None
    base = dep.split("/", 1)[1] if "/" in dep else dep
    for rp in rpaths + ["/opt/homebrew/lib", "/usr/local/lib"]:
        cand = os.path.join(rp.replace("@loader_path", os.path.dirname(dep)) if "@loader_path" in rp else rp, base)
        if os.path.exists(cand): return cand
    # last resort: search homebrew lib by basename
    for root in ("/opt/homebrew/lib", "/usr/local/lib"):
        cand = os.path.join(root, os.path.basename(dep))
        if os.path.exists(cand): return cand
    return None

def main():
    app = sys.argv[1]
    res = os.path.join(app, "Contents", "Resources")
    bindir, libdir = os.path.join(res, "bin"), os.path.join(res, "lib")
    os.makedirs(bindir, exist_ok=True); os.makedirs(libdir, exist_ok=True)

    sources = {
        "ffmpeg": find("ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"),
        "ffprobe": find("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"),
        "node": find("node", "/opt/homebrew/bin/node", "/usr/local/bin/node"),
    }
    missing = [n for n, s in sources.items() if not s]
    if missing:
        sys.exit(f"error: could not locate {', '.join(missing)} to bundle")
    for name, src in sources.items():
        dst = os.path.join(bindir, name)
        shutil.copy(src, dst); os.chmod(dst, 0o755)
        thin(dst)
        print(f"copied {name} from {src}")

    # BFS over Mach-O files, copying every bundleable dylib into lib/
    copied = {}            # realpath -> basename in lib/
    queue = [os.path.join(bindir, n) for n in sources]
    seen = set()
    while queue:
        f = queue.pop()
        if f in seen: continue
        seen.add(f)
        for dep in otool_deps(f):
            if not is_bundleable(dep): continue
            real = resolve(dep, [])
            if not real:
                continue
            real = os.path.realpath(real)
            if real not in copied:
                base = os.path.basename(real)
                # de-dup basenames
                target = os.path.join(libdir, base)
                if os.path.exists(target) and os.path.realpath(target) != real:
                    base = base  # keep; collisions unlikely for ffmpeg tree
                shutil.copy(real, target); os.chmod(target, 0o755)
                copied[real] = base
                queue.append(target)

    print(f"bundled {len(copied)} dylibs")

    def rewrite(f, in_bin):
        # set id for dylibs
        if not in_bin:
            subprocess.run(["install_name_tool", "-id", f"@rpath/{os.path.basename(f)}", f], capture_output=True)
        for dep in otool_deps(f):
            if not is_bundleable(dep): continue
            real = resolve(dep, [])
            if not real: continue
            base = copied.get(os.path.realpath(real))
            if not base: continue
            if dep != f"@rpath/{base}":
                subprocess.run(["install_name_tool", "-change", dep, f"@rpath/{base}", f], capture_output=True)
        # rpath
        rp = "@loader_path/../lib" if in_bin else "@loader_path"
        subprocess.run(["install_name_tool", "-add_rpath", rp, f], capture_output=True)

    for n in sources:
        rewrite(os.path.join(bindir, n), True)
    for base in set(copied.values()):
        rewrite(os.path.join(libdir, base), False)

    # ad-hoc re-sign (mandatory on Apple Silicon after install_name_tool)
    for base in set(copied.values()):
        subprocess.run(["codesign", "--force", "--sign", "-", os.path.join(libdir, base)], capture_output=True)
    for n in sources:
        subprocess.run(["codesign", "--force", "--sign", "-", os.path.join(bindir, n)], capture_output=True)
    print("re-signed bundled binaries")

if __name__ == "__main__":
    main()

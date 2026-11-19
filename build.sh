#!/usr/bin/env bash
# Build Angry Birds Classic v3.3.0 for the browser on Boxedwine's multi-threaded web build.
#
# boxedwine.js / boxedwine.wasm are compiled from the Boxedwine source (release tag) with
# emscripten, as upstream's "make multiThreaded" does, plus memory growth and the source
# fixes in patches/<tag>/:
#   audio-callback-lock.patch  the "memory access out of bounds" crash once sound is on
#   gl-vertex-array-leak.patch vertex arrays in game memory: no memory leak (ran out of memory),
#                              shader attribute 0 kept apart from glVertexPointer (level shapes
#                              drawn across the screen), indexed draws read the right vertices
#   osmesa-web.patch           OpenGL for the web build (see below)
#   wasm-exceptions.patch      compile with wasm exceptions (guest page faults froze the game)
#   web-no-inet-sockets.patch  no internet sockets in the browser: the game sees no network
#                              (emscripten's socket emulation runs poll on the page's main
#                              thread and froze the page when a bird was fired)
#
# Angry Birds draws with OpenGL, and upstream's web build has no OpenGL at all. So Mesa's
# software OpenGL (OSMesa with the classic swrast rasterizer, Mesa 20.3.5) is compiled to
# wasm as well (patches/mesa-20.3.5/) and linked into boxedwine.wasm; the game runs with
# "-opengl osmesa" and every frame is rasterized by Mesa on the CPU.
#
# The game itself comes from the itch.io page the activation key is on
# (https://lsyxnl.itch.io/angry-birds-classic). Its Advanced Installer setup is unpacked here
# (no Windows installer is run), and the game files go to C:\AngryBirds inside Wine.
#
#   ./build.sh            -> dist/ (serve it over http(s))
#
# Options (environment variables):
#   BOXEDWINE_VERSION=26R1    Boxedwine release: source tag <version>.0 and its Wine 11 file system
#   EMSDK_VERSION=5.0.6       emscripten used to compile (the one the 26R1 release was built with)
#   EMSDK_DIR=cache/emsdk     reuse an existing emsdk checkout instead of installing one
#   CACHE=cache               downloads and compiled code; point the six Angry Birds projects at
#                             one shared folder to compile emsdk/Mesa/Boxedwine only once
#   MAX_MEMORY_MB=2048        heap growth limit (512..4096; above 2048 costs some speed)
#   JOBS=<cpu count>          parallel compile jobs
#   MESA_VERSION=20.3.5       last Mesa release with the classic swrast OSMesa
#   INSTALLER=/path/AngryBirdsInstaller__3.3.0.exe   use a local copy instead of downloading it from itch.io
#   RESOLUTION=1024x768       game size: one of the emulated display modes 640x480, 800x600, 1024x768,
#                             1280x1024 (the games run fullscreen); the games ask for at least 1024x768
#   RENDERER=gl2             renderer in config.lua: gl1 (fixed function) or gl2 (GLSL shaders)
#   SPLIT_MB=95               split the game into zips smaller than this (GitHub refuses files over 100 MB)
#
# Needs: bash, git, make, curl, unzip, python3, flex, bison, and 7z (or pip for py7zr).
# meson, ninja and mako (to build Mesa) are installed into $CACHE/venv when missing.
# First run downloads emsdk (~1 GB on disk) and compiles Mesa and Boxedwine (20-40 minutes);
# later runs reuse them from the cache.
set -euo pipefail

GAME_TITLE="Angry Birds Classic v3.3.0"
ITCH_PAGE="https://lsyxnl.itch.io/angry-birds-classic"
ITCH_UPLOAD_ID="10196441"          # data-upload_id of the installer on that page
INSTALLER_NAME="AngryBirdsInstaller__3.3.0.exe"
GAME_DIRNAME="AngryBirds"              # C:\AngryBirds inside Wine
EXE="AngryBirds.exe"

BOXEDWINE_VERSION="${BOXEDWINE_VERSION:-26R1}"
BOXEDWINE_TAG="${BOXEDWINE_TAG:-$BOXEDWINE_VERSION.0}"
EMSDK_VERSION="${EMSDK_VERSION:-5.0.6}"
MAX_MEMORY_MB="${MAX_MEMORY_MB:-2048}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
MESA_VERSION="${MESA_VERSION:-20.3.5}"
INSTALLER="${INSTALLER:-}"
RESOLUTION="${RESOLUTION:-1024x768}"
RENDERER="${RENDERER:-gl2}"
SPLIT_MB="${SPLIT_MB:-95}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$(mkdir -p "${CACHE:-$HERE/cache}" && cd "${CACHE:-$HERE/cache}" && pwd)"   # downloads, emsdk, Mesa, Boxedwine
WORK="$HERE/work"     # scratch, rebuilt every run
OUT="$HERE/dist"      # the website
WEB="$HERE/web"       # index.html, shell.js, coi-serviceworker.js
EMSDK_DIR="${EMSDK_DIR:-$CACHE/emsdk}"

BW_GIT="https://github.com/danoon2/Boxedwine.git"
EMSDK_GIT="https://github.com/emscripten-core/emsdk.git"
# Only the Wine 11 root file system (Wine11/boxedwine.zip) is taken from the release.
BW_RELEASE_URL="https://github.com/danoon2/Boxedwine/releases/download/$BOXEDWINE_TAG/Boxedwine${BOXEDWINE_VERSION}Web.zip"
MESA_URL="https://archive.mesa3d.org/older-versions/${MESA_VERSION%%.*}.x/mesa-$MESA_VERSION.tar.xz"
# The web release ships a stripped Wine 11. Boxedwine's full Wine 11 file system
# (same build, what the desktop app downloads) supplies what the game needs from it.
WINE_FULL_URL="https://boxedwine.org/v2/6/TinyCore15Wine11.0.zip"
WINE_EXTRA_FILES=(
    lib/libGL.so.1                                       # Boxedwine's libGL: Wine's OpenGL calls to the emulator
    opt/wine/lib/wine/i386-unix/winhttp.dll.so           # imported by the game (online features)
    opt/wine/lib/wine/i386-unix/jsproxy.dll.so           #   needed by winhttp
    opt/wine/lib/wine/i386-unix/dhcpcsvc.dll.so          #   needed by winhttp
    opt/wine/lib/wine/i386-unix/secur32.dll.so           #   needed by winhttp
    opt/wine/lib/wine/i386-unix/secur32.so
    opt/wine/lib/wine/i386-unix/windowscodecs.dll.so     # PNG loading (gdiplus -> WIC)
    opt/wine/lib/wine/i386-windows/normaliz.dll          # imported by Angry Birds Classic
    # Present when the activation/ files were made (the game reads machine details through
    # WMI and TLS libraries), so the browser presents the same machine:
    opt/wine/lib/wine/i386-unix/wbemprox.dll.so          # WMI
    opt/wine/lib/wine/i386-unix/schannel.dll.so          # TLS for winhttp/secur32
    opt/wine/lib/wine/i386-unix/ncrypt.dll.so
    opt/wine/lib/wine/i386-unix/cryptnet.dll.so
    opt/wine/lib/wine/i386-unix/dssenh.dll.so
)
GAME_DIR="home/username/.wine/drive_c/$GAME_DIRNAME"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in git make curl unzip python3 flex bison; do
    command -v "$tool" >/dev/null || die "missing '$tool'"
done
[ -f "$WEB/index.html" ] && [ -f "$WEB/shell.js" ] || die "web/index.html and web/shell.js must be next to build.sh"
[[ "$MAX_MEMORY_MB" =~ ^[0-9]+$ ]] && [ "$MAX_MEMORY_MB" -ge 512 ] && [ "$MAX_MEMORY_MB" -le 4096 ] \
    || die "MAX_MEMORY_MB must be between 512 and 4096"
[[ "$RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]] || die "RESOLUTION must look like 800x600"
GAME_W="${BASH_REMATCH[1]}"; GAME_H="${BASH_REMATCH[2]}"
[[ "$RENDERER" =~ ^gl[12]$ ]] || die "RENDERER must be gl1 or gl2"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# fetch URL FILE: download once into the cache.
fetch() {
    if [ -s "$CACHE/$2" ]; then
        echo "cached: $2"
    else
        echo "downloading: $1"
        curl -fL --retry 3 -o "$CACHE/$2.part" "$1"
        mv "$CACHE/$2.part" "$CACHE/$2"
    fi
}

# itch_fetch PAGE UPLOAD_ID FILE: download a free itch.io upload the way the page's
# Download button does (CSRF token from the page, then a short-lived CDN link).
itch_fetch() {
    if [ -s "$CACHE/$3" ]; then echo "cached: $3"; return; fi
    local jar token url
    jar="$(mktemp)"
    token="$(curl -fsSL -c "$jar" -b "$jar" "$1" | grep -o 'name="csrf_token" value="[^"]*"' | head -n1 | sed 's/.*value="//; s/"$//')"
    [ -n "$token" ] || { rm -f "$jar"; die "no csrf_token on $1 (set INSTALLER to a local copy instead)"; }
    url="$(curl -fsSL -c "$jar" -b "$jar" -X POST --data-urlencode "csrf_token=$token" \
        "$1/file/$2?source=view_game&as_props=1&after_download_lightbox=true" \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')" \
        || { rm -f "$jar"; die "itch.io did not hand out a download link (set INSTALLER to a local copy instead)"; }
    rm -f "$jar"
    echo "downloading (itch.io): $3"
    curl -fL --retry 3 -o "$CACHE/$3.part" "$url"
    mv "$CACHE/$3.part" "$CACHE/$3"
}

# python tools (meson/ninja/mako for Mesa, py7zr if there is no 7z) in one venv
venv_python() {
    [ -x "$CACHE/venv/bin/python" ] || python3 -m venv "$CACHE/venv"
    echo "$CACHE/venv/bin/python"
}

# extract_7z ARCHIVE DIR
extract_7z() {
    local seven
    for seven in 7zz 7z 7za; do
        if command -v "$seven" >/dev/null; then "$seven" x -y -o"$2" "$1" >/dev/null; return; fi
    done
    local py; py="$(venv_python)"
    "$py" -c 'import py7zr' 2>/dev/null || "$py" -m pip install -q py7zr
    "$py" -m py7zr x "$1" "$2"
}

log "emscripten $EMSDK_VERSION"
[ -d "$EMSDK_DIR/.git" ] || git clone --depth 1 "$EMSDK_GIT" "$EMSDK_DIR"
"$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
"$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION" >/dev/null
set +u
# shellcheck disable=SC1091
source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
set -u
emcc --version | head -n1 | grep -qF "$EMSDK_VERSION" || die "emcc is not version $EMSDK_VERSION"
EMBIN="$(dirname "$(command -v emcc)")"

log "Mesa $MESA_VERSION OSMesa (classic swrast) for wasm"
OSMESA_DIR="$CACHE/osmesa-$MESA_VERSION-em$EMSDK_VERSION"
OSMESA_LIB="$OSMESA_DIR/libOSMesa.a"
if [ -s "$OSMESA_LIB" ]; then
    echo "cached: ${OSMESA_LIB#"$CACHE"/}"
else
    PY="$(venv_python)"
    # setuptools: Mesa 20.3's meson.build still imports distutils (gone from Python 3.12+)
    "$PY" -c 'import mesonbuild, mako, setuptools, distutils.version' 2>/dev/null && [ -x "$CACHE/venv/bin/ninja" ] \
        || "$PY" -m pip install -q meson ninja mako setuptools
    fetch "$MESA_URL" "mesa-$MESA_VERSION.tar.xz"
    MESA_SRC="$WORK/mesa-$MESA_VERSION"
    tar xf "$CACHE/mesa-$MESA_VERSION.tar.xz" -C "$WORK"
    for patch in "$HERE/patches/mesa-$MESA_VERSION"/*.patch; do
        [ -e "$patch" ] || continue
        (cd "$MESA_SRC" && patch -p1 -s < "$patch") || die "could not apply ${patch#"$HERE"/}"
        echo "patch applied: ${patch#"$HERE"/}"
    done
    # -pthread and -fwasm-exceptions (wasm setjmp/longjmp) must match the Boxedwine link below.
    cat > "$WORK/emscripten-cross.txt" <<EOF
[binaries]
c = '$EMBIN/emcc'
cpp = '$EMBIN/em++'
ar = '$EMBIN/emar'
ranlib = '$EMBIN/emranlib'
strip = '$EMBIN/emstrip'
pkg-config = 'false'

[built-in options]
c_args = ['-pthread', '-O3', '-D_GNU_SOURCE', '-fwasm-exceptions']
cpp_args = ['-pthread', '-O3', '-D_GNU_SOURCE', '-fwasm-exceptions']
c_link_args = ['-pthread', '-fwasm-exceptions']
cpp_link_args = ['-pthread', '-fwasm-exceptions']

[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF
    (
        export PATH="$CACHE/venv/bin:$PATH"
        cd "$MESA_SRC"
        meson setup build --cross-file "$WORK/emscripten-cross.txt" --buildtype=release --default-library=static \
            -Dosmesa=classic -Ddri-drivers= -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= \
            -Dglx=disabled -Degl=false -Dgbm=false -Dgles1=false -Dgles2=false -Dshared-glapi=false \
            -Dllvm=disabled -Dshader-cache=false -Dzstd=false -Dlibunwind=disabled -Dvalgrind=disabled \
            -Dbuild-tests=false -Dselinux=false -Dlmsensors=disabled -Ddri3=false -Dglvnd=false -Dopengl=true >/dev/null
        ninja -C build -j"$JOBS" src/mesa/drivers/osmesa/libOSMesa.a
    )
    mkdir -p "$OSMESA_DIR"
    cp "$MESA_SRC/build/src/mesa/drivers/osmesa/libOSMesa.a" "$OSMESA_LIB"
    rm -rf "$MESA_SRC"
fi

log "Boxedwine $BOXEDWINE_TAG from source (multi-threaded, OpenGL via OSMesa, heap 512 MB growing to $MAX_MEMORY_MB MB)"
SRC="$CACHE/boxedwine-$BOXEDWINE_TAG"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$BOXEDWINE_TAG" "$BW_GIT" "$SRC"
# Source fixes for this tag (patches/<tag>/*.patch), each applied once.
for patch in "$HERE/patches/$BOXEDWINE_TAG"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "patch already applied: ${patch#"$HERE"/}"
    else
        git -C "$SRC" apply "$patch" || die "could not apply ${patch#"$HERE"/}"
        echo "patch applied: ${patch#"$HERE"/}"
    fi
done
# Upstream's multiThreaded compile and link settings, plus:
#  - memory growth (the makefile's -s TOTAL_MEMORY=536870912 becomes the initial heap size;
#    -Wno-pthreads-mem-growth: Boxedwine's emulation runs in wasm, which isn't slowed by it)
#  - BOXEDWINE_OPENGL_OSMESA and libOSMesa.a
#  - 4 MB thread stacks: emscripten's default is 64 KB, and Mesa's GLSL compiler overflows
#    that silently (memory corruption) when the game links its shaders
#  - WASM_EH=1 (wasm-exceptions.patch): compile with -fwasm-exceptions, not only link with it.
#    Boxedwine delivers guest page faults to Wine by throwing; without it emscripten compiles
#    every catch block away and the first page fault in the game kills its thread (game freezes)
BUILD_DIR="Build/MultiThreaded-osmesa-wasmeh-em$EMSDK_VERSION"
rm -f "$SRC/project/emscripten/$BUILD_DIR"/boxedwine.{html,js,wasm,worker.js}   # always relink
make -C "$SRC/project/emscripten" -j"$JOBS" \
    BUILD_DIR="$BUILD_DIR" \
    SHELL_FILE=shell.html \
    WASM_EH=1 \
    EXTRA_CPP_FLAGS="-DBOXEDWINE_MULTI_THREADED -pthread -DBOXEDWINE_OPENGL_OSMESA \"-DGLH=<SDL_opengl.h>\"" \
    EXTRA_LD_FLAGS="-pthread -sPTHREAD_POOL_SIZE=32 -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=$((MAX_MEMORY_MB * 1024 * 1024)) -Wno-pthreads-mem-growth -sSTACK_SIZE=4MB -sDEFAULT_PTHREAD_STACK_SIZE=4MB $OSMESA_LIB"
BUILT="$SRC/project/emscripten/$BUILD_DIR"
[ -f "$BUILT/boxedwine.js" ] && [ -f "$BUILT/boxedwine.wasm" ] || die "build finished without boxedwine.js/boxedwine.wasm"
cp "$BUILT/boxedwine.js" "$BUILT/boxedwine.wasm" "$OUT/"
[ ! -f "$BUILT/boxedwine.worker.js" ] || cp "$BUILT/boxedwine.worker.js" "$OUT/"   # older emscripten only
cp "$SRC/license.txt" "$OUT/license.txt"

log "Wine 11 file system from the Boxedwine $BOXEDWINE_VERSION release"
fetch "$BW_RELEASE_URL" "Boxedwine${BOXEDWINE_VERSION}Web.zip"
unzip -p "$CACHE/Boxedwine${BOXEDWINE_VERSION}Web.zip" Wine11/boxedwine.zip > "$OUT/boxedwine.zip"
[ -s "$OUT/boxedwine.zip" ] || die "Wine11/boxedwine.zip not found in the release zip"

log "Extra Wine 11 files from Boxedwine's full file system"
fetch "$WINE_FULL_URL" "TinyCore15Wine11.0.zip"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
unzip -q -o "$CACHE/TinyCore15Wine11.0.zip" "${WINE_EXTRA_FILES[@]}" -d "$STAGE"

log "$GAME_TITLE"
if [ -n "$INSTALLER" ]; then
    cp "$INSTALLER" "$CACHE/$INSTALLER_NAME"
else
    itch_fetch "$ITCH_PAGE" "$ITCH_UPLOAD_ID" "$INSTALLER_NAME"
fi
# The installer is an Advanced Installer bootstrapper: the game is FILES.7z, appended after
# the PE image and listed in the table before the "ADVINSTSFX" footer; the first 512 bytes
# of it are XORed with 0xFF.
python3 - "$CACHE/$INSTALLER_NAME" "$WORK/FILES.7z" <<'PY' || die "could not unpack $INSTALLER_NAME (corrupt download? delete it from the cache)"
import struct, sys
exe, out = sys.argv[1], sys.argv[2]
d = open(exe, "rb").read()
end = d.rfind(b"ADVINSTSFX")
if end < 0:
    sys.exit("no ADVINSTSFX footer: not an Advanced Installer setup")
# table entries: u32 ?, u32 ?, u32 xor flag, u32 size, u32 offset, u32 name length, UTF-16 name
i = max(0, end - 65536)
while i < end - 24:
    _, _, flag, size, off, nlen = struct.unpack_from("<6I", d, i)
    if 0 < nlen < 260 and 0 < size and off + size <= len(d) and i + 24 + 2 * nlen <= end:
        try:
            name = d[i + 24:i + 24 + 2 * nlen].decode("utf-16-le")
        except UnicodeDecodeError:
            name = ""
        if name.upper().endswith("\\FILES.7Z"):
            data = bytearray(d[off:off + size])
            if flag == 2:
                data[:512] = bytes(b ^ 0xFF for b in data[:512])
            if data[:6] != b"7z\xbc\xaf\x27\x1c":
                sys.exit("FILES.7z does not look like a 7z archive")
            open(out, "wb").write(data)
            print("FILES.7z: %d bytes" % size)
            sys.exit(0)
    i += 1
sys.exit("FILES.7z not found in the installer")
PY
mkdir -p "$STAGE/$GAME_DIR"
extract_7z "$WORK/FILES.7z" "$STAGE/$GAME_DIR"
rm -f "$WORK/FILES.7z"
[ -f "$STAGE/$GAME_DIR/$EXE" ] || die "$EXE not found in the installer"
# Unused here: the Direct3D 11 and OpenGL ES renderers (need GPU drivers) and the online
# updater (Rovio's servers are gone; it also needs msi.dll, which isn't in the file system).
rm -f "$STAGE/$GAME_DIR"/{grdx11.dll,grgles2.dll,libEGL.dll,libGLESv2.dll,libgles_cm.dll,updater.exe}
# config.lua: OpenGL renderer that works with Mesa, game size = emulated screen size,
# and fullscreen so the game owns the whole emulated screen (no window frame).
python3 - "$STAGE/$GAME_DIR/config.lua" "$RENDERER" "$GAME_W" "$GAME_H" <<'PY'
import re, sys
path, renderer, w, h = sys.argv[1:]
s = open(path, encoding="latin-1").read()
def setting(s, key, value):
    line = "%s = %s" % (key, value)
    s, n = re.subn(r"(?m)^%s\s*=.*$" % key, line, s)
    return s if n else s.rstrip("\n") + "\n" + line + "\n"
s = setting(s, "renderer", '{ "%s" }' % renderer)
s = setting(s, "width", w)
s = setting(s, "height", h)
s = setting(s, "fullscreen", "true")
open(path, "w", encoding="latin-1").write(s)
PY

# activation/: the game's save folder (AppData\Roaming\Rovio\<game>) right after the
# itch.io key was registered. Registering needs Rovio's activation server, which a web page
# can't reach, so it was done once in a desktop (native) Boxedwine build with internet access,
# using this same Wine file system and these same zips; the game accepts that save here.
if [ -d "$HERE/activation" ]; then
    ROVIO="$STAGE/home/username/.wine/drive_c/users/username/AppData/Roaming/Rovio"
    mkdir -p "$ROVIO"
    cp -a "$HERE/activation/." "$ROVIO/"
    echo "activation: $(cd "$HERE/activation" && ls)"
fi

log "Packing the game (zips under $SPLIT_MB MB)"
GAME_ZIPS="$(python3 - "$STAGE" "$OUT" "$SPLIT_MB" <<'PY'
import os, sys, zipfile
stage, out, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]) * 1024 * 1024
STORED = (".png", ".jpg", ".ogg", ".mp3", ".pvr", ".dds", ".7z", ".zip")
files = []
for root, dirs, names in os.walk(stage):
    dirs.sort()
    for n in sorted(names):
        p = os.path.join(root, n)
        files.append((os.path.relpath(p, stage).replace(os.sep, "/"), p))
zips, cur, size = [], None, 0
def open_zip():
    name = "game-%d.zip" % (len(zips) + 1)
    zips.append(name)
    return zipfile.ZipFile(os.path.join(out, name), "w", allowZip64=False), set()
z, dirs = open_zip()
for arc, p in files:
    fsize = os.path.getsize(p)
    if size and size + fsize > limit * 0.97:      # leave room for headers/directory
        z.close(); z, dirs = open_zip(); size = 0
    parts = arc.split("/")[:-1]
    for k in range(1, len(parts) + 1):            # directory entries, like zip -r
        dname = "/".join(parts[:k]) + "/"
        if dname not in dirs:
            dirs.add(dname); z.writestr(zipfile.ZipInfo(dname, (2013, 1, 1, 0, 0, 0)), b"")
    info = zipfile.ZipInfo(arc, (2013, 1, 1, 0, 0, 0))
    info.external_attr = 0o644 << 16
    method = zipfile.ZIP_STORED if arc.lower().endswith(STORED) else zipfile.ZIP_DEFLATED
    with open(p, "rb") as f:
        data = f.read()
    z.writestr(info, data, compress_type=method, compresslevel=9)
    size += fsize
z.close()
if len(zips) == 1:
    os.rename(os.path.join(out, zips[0]), os.path.join(out, "game.zip")); zips = ["game.zip"]
for n in zips:
    if os.path.getsize(os.path.join(out, n)) >= limit:
        sys.exit("%s is over the size limit, lower SPLIT_MB" % n)
print(" ".join(zips))
PY
)"
echo "game zips: $GAME_ZIPS"

log "Web assets"
cp "$WEB"/index.html "$WEB"/shell.js "$WEB"/coi-serviceworker.js "$OUT/"
ZIPS_JS="\"boxedwine.zip\""
for z in $GAME_ZIPS; do ZIPS_JS="$ZIPS_JS, \"$z\""; done
python3 - "$OUT/shell.js" "$ZIPS_JS" "$RESOLUTION" <<'PY'
import re, sys
path, zips, res = sys.argv[1:]
s = open(path).read()
s = re.sub(r'(?m)^var ZIPS = \[.*?\];', 'var ZIPS = [%s];' % zips, s, count=1)
s = re.sub(r'(?m)^var RESOLUTION = ".*?";', 'var RESOLUTION = "%s";' % res, s, count=1)
open(path, "w").write(s)
PY

rm -rf "$WORK"
log "Done: $OUT"
ls -lh "$OUT"
cat <<EOF

Test locally:  cd dist && python3 -m http.server 8000   then open http://localhost:8000/
Publish:       upload the contents of dist/ to any static host (GitHub Pages works,
               coi-serviceworker.js supplies the headers the multi-threaded build needs).
EOF

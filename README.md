# Angry Birds Classic v3.3.0 in the browser (Boxedwine)

Runs the Windows PC version of Angry Birds Classic v3.3.0 in a web page: Wine inside
[Boxedwine](https://github.com/danoon2/Boxedwine) (an x86 emulator compiled to WebAssembly),
with OpenGL provided by Mesa's software renderer (OSMesa) compiled to wasm as well.

Project layout:

```
build.sh                       downloads, compiles and packs everything into dist/
web/index.html, web/shell.js   the page and the Boxedwine launcher
web/coi-serviceworker.js       cross-origin isolation on hosts without COOP/COEP headers
patches/26R1.0/                Boxedwine source fixes (sound crash, OpenGL through OSMesa, wasm exceptions, GL vertex arrays, no network sockets)
patches/mesa-20.3.5/           Mesa fixes to build OSMesa with emscripten
activation/                    the game's save folder right after registering the key
```

## Build

```
./build.sh                     # -> dist/
cd dist && python3 -m http.server 8000     # then open http://localhost:8000/
```

`build.sh` needs bash, git, make, curl, unzip, python3, flex, bison and 7z (or pip, for py7zr).
It installs emsdk, compiles Mesa's OSMesa and Boxedwine to wasm (20-40 minutes the first time,
cached afterwards), downloads the game installer from
[the itch.io page](https://lsyxnl.itch.io/angry-birds-classic) and unpacks it without running it.
Options are listed at the top of `build.sh`; the useful ones:

- `CACHE=/some/folder` - share the compiled emsdk/Mesa/Boxedwine with the other Angry Birds projects
- `INSTALLER=/path/AngryBirdsInstaller__3.3.0.exe` - use an installer you already have
- `RESOLUTION=1024x768` - game size, one of the emulated display modes (640x480, 800x600, 1024x768, 1280x1024); the games ask for at least 1024x768 (the PC original defaults to 1024x768)
- `RENDERER=gl2` - `gl1` (fixed function) or `gl2` (GLSL shaders)

## Publish

Upload the contents of `dist/` to any static host. GitHub Pages works: `coi-serviceworker.js`
supplies the headers the multi-threaded build needs, and the game is split into zips under
100 MB (GitHub's file size limit).

## Notes

- Speed: the game logic runs in an x86 interpreter and Mesa rasterizes every frame on the CPU,
  so expect a few frames per second, more on a fast multi-core CPU. The first start takes several
  minutes with a black screen while the game loads its data.
- Activated: `activation/` holds the game's save folder (`AppData\Roaming\Rovio\<game>`) right
  after registering the itch.io key `THET-ALEV-LEFR-USWO`, and `build.sh` puts it into the game zip. Registering
  contacts Rovio's activation server, which a web page can't reach, so it was done once in a
  desktop (native) build of the same Boxedwine with internet access, using the same Wine file system
  and game zips as the page. If a browser still has an older unactivated save, open the page once
  with `?reset=1`.
- No network: the page gives the game no internet sockets, so it plays offline (online extras such
  as news or leaderboards just don't load).
- Progress is stored in the browser's IndexedDB. `?sound=false` mutes, `?winedebug=err` shows Wine errors in the console.

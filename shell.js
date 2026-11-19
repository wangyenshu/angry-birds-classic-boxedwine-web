// Minimal launcher for Angry Birds Classic v3.3.0 on the Boxedwine multi-threaded web build.
var ROOT = "/root";                                       // Boxedwine's writable layer, kept in IndexedDB
var ZIPS = ["boxedwine.zip", "game-1.zip", "game-2.zip"];                 // Wine root file system, then the game (build.sh fills this in)
var GAME_DIR = "/home/username/.wine/drive_c/AngryBirds";   // C:\AngryBirds
var EXE = "AngryBirds.exe";
var RESOLUTION = "1024x768";                          // must match width/height in the game's config.lua (build.sh)

var statusEl = document.getElementById("status");
function setStatus(text) { statusEl.textContent = text; }
function param(name) { return new URLSearchParams(location.search).get(name); }

var canvas = document.getElementById("canvas");
canvas.width = Number(RESOLUTION.split("x")[0]);
canvas.height = Number(RESOLUTION.split("x")[1]);

async function download(name) {
    var res = await fetch(name);
    if (!res.ok) throw new Error(name + ": HTTP " + res.status);
    var total = Number(res.headers.get("Content-Length")) || 0;
    var reader = res.body.getReader(), chunks = [], got = 0;
    for (;;) {
        var part = await reader.read();
        if (part.done) break;
        chunks.push(part.value);
        got += part.value.length;
        setStatus("Downloading " + name + ": " + (got >> 20) + (total ? " / " + (total >> 20) : "") + " MB");
    }
    var data = new Uint8Array(got), offset = 0;
    for (var chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
    return data;
}

function emulatorArgs() {
    var args = ["-root", ROOT];
    for (var zip of ZIPS) args.push("-zip", zip);
    args.push("-opengl", "osmesa");   // OpenGL through Mesa's software rasterizer, compiled into boxedwine.wasm
    if (param("sound") === "false") args.push("-nosound");
    args.push("-resolution", RESOLUTION);
    args.push("-env", "WINEDEBUG=" + (param("winedebug") || "-all").replace(/ /g, "+"));   // e.g. ?winedebug=err+wgl
    args.push("-w", GAME_DIR, "/bin/wine", EXE);
    return args;
}

var Module = {
    arguments: [],
    canvas: canvas,
    print: function (text) { console.log(text); },
    printErr: function (text) { console.error(text); },
    setStatus: function (text) { if (text) setStatus(text); },
    preRun: [function () {
        Module.addRunDependency("files");
        FS.mkdir(ROOT);
        FS.mount(IDBFS, { autoPersist: true }, ROOT);
        FS.syncfs(true, async function (err) {
            if (err) console.error("IndexedDB:", err);
            if (param("reset")) {
                // ?reset=1: forget this browser's saved state (progress, settings)
                (function rm(path) {
                    for (var name of FS.readdir(path)) {
                        if (name === "." || name === "..") continue;
                        var p = path + "/" + name;
                        if (FS.isDir(FS.stat(p).mode)) { rm(p); FS.rmdir(p); } else FS.unlink(p);
                    }
                })(ROOT);
            }
            try {
                for (var zip of ZIPS) FS.writeFile("/" + zip, await download(zip));
            } catch (e) {
                setStatus("Error: " + e.message);
                return;
            }
            Module.arguments.push.apply(Module.arguments, emulatorArgs());
            setStatus("Starting Wine... the game takes a few minutes to load, the screen stays black meanwhile");
            Module.removeRunDependency("files");
        });
    }]
};

window.onerror = function (msg) { setStatus("Error: " + msg); };

// The multi-threaded build needs SharedArrayBuffer, i.e. a cross-origin isolated page.
// coi-serviceworker.js provides that on hosts that can't send COOP/COEP headers.
if (window.crossOriginIsolated) {
    sessionStorage.removeItem("coiRetry");
    var script = document.createElement("script");
    script.src = "boxedwine.js";
    document.body.appendChild(script);
} else if (location.protocol === "file:") {
    setStatus("Serve this folder over http(s); it does not work from file://");
} else if (!("serviceWorker" in navigator)) {
    setStatus("This browser can't run the multi-threaded build here (no service workers, e.g. private mode).");
} else {
    setStatus("Waiting for cross-origin isolation (the page reloads once)...");
    navigator.serviceWorker.ready.then(function () {
        // Reload if the page loaded before the service worker took control.
        var tries = Number(sessionStorage.getItem("coiRetry")) || 0;
        if (tries < 3) {
            sessionStorage.setItem("coiRetry", tries + 1);
            location.reload();
        } else {
            setStatus("Cross-origin isolation failed; reload the page or try another browser.");
        }
    });
}

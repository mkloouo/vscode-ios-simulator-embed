import * as cp from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as readline from "readline";
import * as vscode from "vscode";

let activePanel: vscode.WebviewPanel | undefined;
let streamProcess: cp.ChildProcessWithoutNullStreams | undefined;
let lastFramePostedAt = 0;

/** Letterbox of the device LCD inside the streamed window (fractions of window w/h); from helper `MAP:` line. */
type StreamPads = { padLeft: number; padRight: number; padTop: number; padBottom: number };

const zeroPads: StreamPads = { padLeft: 0, padRight: 0, padTop: 0, padBottom: 0 };
let streamPads: StreamPads = { ...zeroPads };

/** Tracks whether the webview has sent touch down (for move/up pairing). */
let panelTouchActive = false;
let panelTouchLastMoveMs = 0;

/** Per-gesture stats for `debugTouchPipeline` summary (pointer down → up/cancel). */
let touchGestureStartMs = 0;
let touchGestureDownNx = 0;
let touchGestureDownNy = 0;
let touchGestureMovesSent = 0;
let touchGestureMovesSkippedThrottle = 0;
let touchGestureMaxDelta = 0;

/** Two quick Home toolbar clicks → double ⌘⇧H in one Simulator activation (app switcher). */
let homeChromeClickCount = 0;
let homeChromeTimer: ReturnType<typeof setTimeout> | undefined;

/** One `ios-sim-helper touch sess` process so down/move/up share a single HID client (drags work). */
let touchSessionChild: cp.ChildProcess | undefined;
let touchSessionStderrBuf = "";

const debugOutputChannel = vscode.window.createOutputChannel("iOS Simulator Embed");

/** Merged env for stream / Indigo touch (bundle id + optional booted UDID). */
function helperEnvForCapture(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  const cfg = vscode.workspace.getConfiguration("ios-simulator-embed");
  const bid = cfg.get<string>("targetBundleId")?.trim();
  if (bid) {
    env.IOS_SIM_HELPER_BUNDLE_ID = bid;
  }
  const udid = cfg.get<string>("simulatorUdid")?.trim();
  if (udid) {
    env.IOS_SIM_UDID = udid;
  }
  if (cfg.get<boolean>("debugMap")) {
    env.IOS_SIM_HELPER_MAP_DEBUG = "1";
  }
  if (cfg.get<boolean>("mapStackVerticalLetterboxOnTop", true)) {
    env.IOS_SIM_HELPER_MAP_TOP_STACK = "1";
  }
  if (cfg.get<boolean>("debugTouchPipeline")) {
    env.IOS_SIM_HELPER_TOUCH_DEBUG = "1";
  }
  const jq = cfg.get<number>("streamJpegQuality");
  if (typeof jq === "number" && Number.isFinite(jq)) {
    const q = Math.min(1, Math.max(0.25, jq));
    env.IOS_SIM_HELPER_JPEG_QUALITY = String(q);
  } else {
    env.IOS_SIM_HELPER_JPEG_QUALITY = "0.62";
  }
  return env;
}

function mapDebugEnabled(): boolean {
  return !!vscode.workspace.getConfiguration("ios-simulator-embed").get<boolean>("debugMap");
}

type StreamPanelInitPayload = {
  debugTouches: boolean;
  streamPads: StreamPads;
  streamLayout: { maxWidthPx: number; maxHeightPx: number };
  streamShowUsageHint: boolean;
};

function streamPanelInitPayload(): StreamPanelInitPayload {
  const cfg = vscode.workspace.getConfiguration("ios-simulator-embed");
  const maxW = cfg.get<number>("streamMaxWidthPx");
  const maxH = cfg.get<number>("streamMaxHeightPx");
  return {
    debugTouches: !!cfg.get("debugTouches"),
    streamPads: { ...streamPads },
    streamLayout: {
      maxWidthPx: typeof maxW === "number" && Number.isFinite(maxW) ? Math.max(0, Math.round(maxW)) : 430,
      maxHeightPx: typeof maxH === "number" && Number.isFinite(maxH) ? Math.max(0, Math.round(maxH)) : 0,
    },
    streamShowUsageHint: !!cfg.get("streamShowUsageHint"),
  };
}

function isMacOSHost(): boolean {
  return process.platform === "darwin";
}

/** AppleScript `delay` in seconds; clamped for stability. */
function appleScriptDelaySeconds(ms: number): string {
  const sec = Math.max(0.02, Math.min(2.5, ms / 1000));
  return sec.toFixed(3);
}

function homeChromeTimingFromConfig() {
  const c = vscode.workspace.getConfiguration("ios-simulator-embed");
  const clamp = (key: string, def: number, lo: number, hi: number) => {
    const v = c.get<number>(key);
    const n = typeof v === "number" && Number.isFinite(v) ? v : def;
    return Math.round(Math.min(hi, Math.max(lo, n)));
  };
  return {
    singleWaitMs: clamp("homeToolbarSingleWaitMs", 260, 80, 900),
    doubleFlushMs: clamp("homeToolbarDoubleFlushMs", 42, 15, 300),
    afterActivateMs: clamp("homeAfterSimulatorActivateMs", 120, 40, 500),
    betweenDoubleKeyMs: clamp("homeBetweenDoubleHomeKeyMs", 200, 100, 600),
    beforeRestoreMs: clamp("homeBeforeRestoreFocusMs", 90, 40, 500),
  };
}

function logMapDiag(message: string, reveal: boolean) {
  debugOutputChannel.appendLine(message);
  if (reveal && mapDebugEnabled()) {
    debugOutputChannel.show(true);
  }
}

function helperPath(context: vscode.ExtensionContext): string {
  const base = path.join(context.extensionPath, "native", "ios-sim-helper");
  const fromBuild = path.join(base, ".build", "release", "ios-sim-helper");
  const fromDist = path.join(base, "dist", "ios-sim-helper");
  if (fs.existsSync(fromBuild)) {
    return fromBuild;
  }
  return fromDist;
}

function ensureHelperBuilt(context: vscode.ExtensionContext): string | undefined {
  const bin = helperPath(context);
  if (!fs.existsSync(bin)) {
    void vscode.window.showErrorMessage(
      "Native helper missing. Run: npm run build:native (needs Xcode Command Line Tools / Swift)."
    );
    return undefined;
  }
  return bin;
}

function stopTouchSession() {
  if (!touchSessionChild || touchSessionChild.killed) {
    touchSessionChild = undefined;
    touchSessionStderrBuf = "";
    return;
  }
  try {
    touchSessionChild.stdin?.write("q\n");
    touchSessionChild.stdin?.end();
  } catch {
    /* ignore */
  }
  touchSessionChild.kill("SIGTERM");
  touchSessionChild = undefined;
  touchSessionStderrBuf = "";
  panelTouchActive = false;
  touchGestureStartMs = 0;
  touchGestureMovesSent = 0;
  touchGestureMovesSkippedThrottle = 0;
  touchGestureMaxDelta = 0;
}

function stopStream() {
  stopTouchSession();
  if (streamProcess && !streamProcess.killed) {
    try {
      streamProcess.stdin.end();
    } catch {
      /* ignore */
    }
    streamProcess.kill("SIGTERM");
  }
  streamProcess = undefined;
}

function panelHtml(webview: vscode.Webview): string {
  const csp = [
    `default-src 'none';`,
    `img-src ${webview.cspSource} data:;`,
    `style-src ${webview.cspSource} 'unsafe-inline';`,
    `script-src 'nonce-streampanel' 'unsafe-inline';`,
  ].join(" ");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <style>
    body { margin: 0; padding: 8px; background: var(--vscode-editor-background); color: var(--vscode-editor-foreground); font-family: var(--vscode-font-family); }
    /* Keeps hint + toolbar + stream the same width as the image (see streamMaxWidthPx). */
    .stream-column { display: block; width: 100%; max-width: 100%; box-sizing: border-box; }
    #chromeBar { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 6px; padding: 6px 8px; margin-bottom: 8px; background: color-mix(in srgb, var(--vscode-editor-foreground) 12%, transparent); border-radius: 6px; width: 100%; max-width: 100%; box-sizing: border-box; }
    .chromeBtn { font: inherit; cursor: pointer; border-radius: 6px; border: 1px solid color-mix(in srgb, var(--vscode-editor-foreground) 25%, transparent); background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground); }
    .chromeBtn:hover { filter: brightness(1.08); }
    .chromeIconBtn { padding: 8px; min-width: 40px; min-height: 40px; display: inline-flex; align-items: center; justify-content: center; line-height: 0; }
    .chromeIconBtn svg { display: block; flex-shrink: 0; }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
    #wrap { position: relative; display: block; width: 100%; max-width: 100%; box-sizing: border-box; }
    #frame { display: block; width: auto; height: auto; max-width: 100%; cursor: pointer; user-select: none; touch-action: none; background: #111; box-sizing: border-box; }
    .hint-compact { font-size: 12px; opacity: 0.8; margin: 0 0 8px 0; line-height: 1.35; }
    #hintDetails { font-size: 12px; margin-bottom: 8px; line-height: 1.35; }
    #hintDetails[hidden] { display: none !important; }
    #hintDetails summary { cursor: pointer; opacity: 0.85; user-select: none; }
    .hint-body { margin-top: 6px; opacity: 0.75; padding-left: 2px; }
    #debugHud { position: absolute; left: 4px; bottom: 4px; margin: 0; padding: 4px 6px; font-size: 10px; line-height: 1.25; font-family: var(--vscode-editor-font-family); background: color-mix(in srgb, var(--vscode-editor-background) 85%, black); color: var(--vscode-editor-foreground); border-radius: 4px; max-width: calc(100% - 8px); pointer-events: none; z-index: 2; white-space: pre-wrap; }
    #debugHud[hidden] { display: none !important; }
  </style>
</head>
<body>
  <div id="streamColumn" class="stream-column">
  <p id="hintCompact" class="hint-compact"></p>
  <details id="hintDetails" hidden>
    <summary>MAP, touch debug, toolbar (optional)</summary>
    <div class="hint-body">
      MAP defaults to <strong>top letterbox only</strong> (<code>mapStackVerticalLetterboxOnTop</code>): LCD bottom-aligned in the capture. Disable for centered vertical fit.
      Debug: <code>debugMap</code>, <code>debugTouches</code>, <code>debugTouchPipeline</code>; command <strong>Touch / MAP debug checklist</strong>. Reopen the panel after MAP / pipeline env changes.
      <code>simulatorUdid</code> if needed. Toolbar: Home (double-click quickly for app switcher), Screenshot, Rotate — host shortcuts via Simulator + Accessibility.
    </div>
  </details>
  <div id="chromeBar" role="toolbar" aria-label="Simulator window actions">
    <button type="button" class="chromeBtn chromeIconBtn" data-action="home" title="Hardware home (⌘⇧H). Click twice within ~0.4s for app switcher (double home). Briefly activates Simulator, then returns focus here.">
      <span class="sr-only">Home</span>
      <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
    </button>
    <button type="button" class="chromeBtn chromeIconBtn" data-action="screenshot" title="Save device screenshot via simctl (device framebuffer, not this stream).">
      <span class="sr-only">Screenshot</span>
      <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg>
    </button>
    <button type="button" class="chromeBtn chromeIconBtn" data-action="rotate" title="Rotate right (⌘→). Briefly activates Simulator, then returns focus here.">
      <span class="sr-only">Rotate</span>
      <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-6.219-8.56"/><path d="M21 3v6h-6"/></svg>
    </button>
  </div>
  <div id="wrap">
    <img id="frame" alt="Simulator stream" draggable="false" />
    <pre id="debugHud" hidden></pre>
  </div>
  </div>
  <script nonce="streampanel">
    const vscode = acquireVsCodeApi();
    const img = document.getElementById('frame');
    const wrap = document.getElementById('wrap');
    const streamColumn = document.getElementById('streamColumn');
    const hintCompact = document.getElementById('hintCompact');
    const hintDetails = document.getElementById('hintDetails');
    const debugHud = document.getElementById('debugHud');
    let activePointer = null;
    let debugTouches = false;
    let streamPads = { padLeft: 0, padRight: 0, padTop: 0, padBottom: 0 };

    function applyStreamLayout(layout) {
      if (!layout || typeof layout !== 'object') return;
      const mw = layout.maxWidthPx;
      const mh = layout.maxHeightPx;
      if (typeof mw === 'number' && mw > 0) {
        const cap = mw + 'px';
        if (streamColumn) streamColumn.style.maxWidth = cap;
        img.style.maxWidth = '100%';
        if (wrap) wrap.style.maxWidth = '100%';
      } else {
        if (streamColumn) streamColumn.style.maxWidth = '100%';
        img.style.maxWidth = '100%';
        if (wrap) wrap.style.maxWidth = '100%';
      }
      if (typeof mh === 'number' && mh > 0) {
        img.style.maxHeight = mh + 'px';
        img.style.objectFit = 'contain';
      } else {
        img.style.maxHeight = '';
        img.style.objectFit = '';
      }
    }

    function applyStreamChrome(init) {
      if (init.streamLayout) applyStreamLayout(init.streamLayout);
      if (hintDetails) {
        const show = !!init.streamShowUsageHint;
        hintDetails.hidden = !show;
        if (!show) hintDetails.open = false;
      }
      if (hintCompact) {
        const w = init.streamLayout && init.streamLayout.maxWidthPx > 0 ? init.streamLayout.maxWidthPx + 'px' : 'full width';
        const h =
          init.streamLayout && init.streamLayout.maxHeightPx > 0
            ? init.streamLayout.maxHeightPx + 'px'
            : 'auto';
        hintCompact.textContent =
          'Stream max ' + w + ' × ' + h + ' (settings: streamMaxWidthPx, streamMaxHeightPx). Enable streamShowUsageHint for MAP/debug notes.';
      }
    }

    document.querySelectorAll('.chromeBtn').forEach((btn) => {
      btn.addEventListener('click', () => {
        const action = btn.getAttribute('data-action');
        if (action) vscode.postMessage({ type: 'chrome', action });
      });
    });

    window.addEventListener('message', (event) => {
      const msg = event.data;
      if (msg && msg.type === 'frame' && typeof msg.dataUrl === 'string') {
        img.src = msg.dataUrl;
      }
      if (msg && msg.type === 'init') {
        debugTouches = !!msg.debugTouches;
        if (msg.streamPads && typeof msg.streamPads === 'object') {
          streamPads = { ...streamPads, ...msg.streamPads };
        }
        applyStreamChrome(msg);
        debugHud.hidden = !debugTouches;
        if (!debugTouches) debugHud.textContent = '';
      }
      if (msg && msg.type === 'streamMap' && msg.pads && typeof msg.pads === 'object') {
        streamPads = { ...streamPads, ...msg.pads };
      }
    });

    function deviceRatios(p) {
      const x0 = p.x / p.w;
      const y0 = p.y / p.h;
      const { padLeft, padRight, padTop, padBottom } = streamPads;
      const innerW = 1 - padLeft - padRight;
      const innerH = 1 - padTop - padBottom;
      let nx = x0, ny = y0;
      if (innerW > 1e-9 && innerH > 1e-9) {
        nx = (x0 - padLeft) / innerW;
        ny = (y0 - padTop) / innerH;
        nx = Math.max(0, Math.min(1, nx));
        ny = Math.max(0, Math.min(1, ny));
      }
      return { x0, y0, nx, ny };
    }

    function updateDebugHud(label, p) {
      if (!debugTouches || !p) return;
      const { x0, y0, nx, ny } = deviceRatios(p);
      const { padLeft, padRight, padTop, padBottom } = streamPads;
      const br = String.fromCharCode(10);
      debugHud.textContent =
        label +
        br +
        'img xy: ' +
        p.x.toFixed(1) +
        ', ' +
        p.y.toFixed(1) +
        '  disp: ' +
        p.w.toFixed(0) +
        '×' +
        p.h.toFixed(0) +
        br +
        'in JPEG: ' +
        x0.toFixed(4) +
        ', ' +
        y0.toFixed(4) +
        br +
        'MAP L,R,T,B: ' +
        padLeft.toFixed(4) +
        ', ' +
        padRight.toFixed(4) +
        ', ' +
        padTop.toFixed(4) +
        ', ' +
        padBottom.toFixed(4) +
        br +
        '→ device: ' +
        nx.toFixed(6) +
        ', ' +
        ny.toFixed(6);
    }

    function relCoords(ev) {
      const r = img.getBoundingClientRect();
      const x = ev.clientX - r.left;
      const y = ev.clientY - r.top;
      if (x < 0 || y < 0 || x > r.width || y > r.height) return null;
      return { x, y, w: r.width, h: r.height, nw: img.naturalWidth, nh: img.naturalHeight };
    }

    /** Same as display rect but clamps to image edges (pointer left the bitmap but we still need a sample). */
    function relCoordsClamped(ev) {
      const r = img.getBoundingClientRect();
      if (!img.naturalWidth || !img.naturalHeight) return null;
      let x = ev.clientX - r.left;
      let y = ev.clientY - r.top;
      x = Math.max(0, Math.min(r.width, x));
      y = Math.max(0, Math.min(r.height, y));
      return { x, y, w: r.width, h: r.height, nw: img.naturalWidth, nh: img.naturalHeight };
    }

    let lastTouchSample = null;

    function finishActivePointer(kind) {
      if (activePointer === null) return;
      const pid = activePointer;
      activePointer = null;
      try { img.releasePointerCapture(pid); } catch (_) {}
      const p = lastTouchSample;
      if (p && p.nw && p.nh) {
        updateDebugHud(kind, p);
        vscode.postMessage({ type: kind, ...p, button: 0 });
      }
      lastTouchSample = null;
    }

    img.addEventListener('pointerdown', (ev) => {
      if (ev.button !== 0) return;
      ev.preventDefault();
      const p = relCoords(ev);
      if (!p || !p.nw || !p.nh) return;
      try { img.setPointerCapture(ev.pointerId); } catch (_) {}
      activePointer = ev.pointerId;
      lastTouchSample = p;
      updateDebugHud('down', p);
      vscode.postMessage({ type: 'touchDown', ...p, button: ev.button });
    });

    img.addEventListener('pointermove', (ev) => {
      if (activePointer === null || ev.pointerId !== activePointer) return;
      let p = relCoords(ev);
      if (!p) {
        p = relCoordsClamped(ev);
      }
      if (!p) return;
      lastTouchSample = p;
      updateDebugHud('move', p);
      vscode.postMessage({ type: 'touchMove', ...p });
    });

    img.addEventListener('pointerup', (ev) => {
      if (ev.pointerId === activePointer) {
        finishActivePointer('touchUp');
      }
    });
    img.addEventListener('pointercancel', (ev) => {
      if (ev.pointerId === activePointer) {
        finishActivePointer('touchCancel');
      }
    });

    img.addEventListener('lostpointercapture', (ev) => {
      if (ev.pointerId === activePointer) {
        finishActivePointer('touchCancel');
      }
    });

    window.addEventListener(
      'pointerup',
      (ev) => {
        if (ev.pointerId === activePointer) {
          finishActivePointer('touchUp');
        }
      },
      true
    );
    window.addEventListener(
      'pointercancel',
      (ev) => {
        if (ev.pointerId === activePointer) {
          finishActivePointer('touchCancel');
        }
      },
      true
    );
    window.addEventListener('blur', () => finishActivePointer('touchCancel'));

    vscode.postMessage({ type: 'panelReady' });
  </script>
</body>
</html>`;
}

function startStream(context: vscode.ExtensionContext, panel: vscode.WebviewPanel) {
  const bin = ensureHelperBuilt(context);
  if (!bin) {
    return;
  }

  stopStream();
  lastFramePostedAt = 0;
  streamPads = { ...zeroPads };
  panelTouchActive = false;
  panelTouchLastMoveMs = 0;

  const child = cp.spawn(bin, ["stream"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: helperEnvForCapture(),
  });
  streamProcess = child;

  const rl = readline.createInterface({ input: child.stderr });
  rl.on("line", (line) => {
    const s = line.trim();
    if (!s) {
      return;
    }
    if (s.startsWith("BOUNDS:")) {
      if (mapDebugEnabled()) {
        try {
          const raw = JSON.parse(s.slice(7)) as Record<string, unknown>;
          logMapDiag(`[MAP] BOUNDS (window frame pt): ${JSON.stringify(raw)}`, false);
        } catch {
          logMapDiag(`[MAP] BOUNDS (unparsed): ${s.slice(0, 200)}`, false);
        }
      }
      return;
    }
    if (s.startsWith("MAP_SKIP:")) {
      try {
        const raw = JSON.parse(s.slice(9)) as Record<string, unknown>;
        logMapDiag(
          `[MAP] helper did not emit MAP line (inset correction disabled): ${JSON.stringify(raw, null, 2)}`,
          true
        );
      } catch {
        logMapDiag(`[MAP] MAP_SKIP (unparsed): ${s.slice(9)}`, true);
      }
      return;
    }
    if (s.startsWith("MAP_DEBUG:")) {
      if (mapDebugEnabled()) {
        try {
          const raw = JSON.parse(s.slice(10)) as Record<string, unknown>;
          logMapDiag(`[MAP] helper debug: ${JSON.stringify(raw, null, 2)}`, true);
        } catch {
          logMapDiag(`[MAP] MAP_DEBUG (unparsed): ${s.slice(10)}`, true);
        }
      }
      return;
    }
    if (s.startsWith("MAP:")) {
      try {
        const raw = JSON.parse(s.slice(4)) as Record<string, unknown>;
        const n = (k: string) => (typeof raw[k] === "number" ? (raw[k] as number) : Number.NaN);
        /** Float noise from the helper can be slightly negative; clamp to [0,1). */
        const sanitizePad = (v: number) =>
          Number.isFinite(v) ? Math.max(0, Math.min(0.999999, v)) : Number.NaN;
        const padLeft = sanitizePad(n("padLeft"));
        const padRight = sanitizePad(n("padRight"));
        const padTop = sanitizePad(n("padTop"));
        const padBottom = sanitizePad(n("padBottom"));
        const finite = [padLeft, padRight, padTop, padBottom].every((v) => Number.isFinite(v));
        const rangeOk = [padLeft, padRight, padTop, padBottom].every((v) => v >= 0 && v < 1);
        const capOk = [padLeft, padRight, padTop, padBottom].every((v) => v <= 0.49);
        const hSum = padLeft + padRight;
        const vSum = padTop + padBottom;
        const sumOk = hSum < 1 && vSum < 1;
        const ok = finite && rangeOk && capOk && sumOk;
        if (ok) {
          streamPads = { padLeft, padRight, padTop, padBottom };
          if (mapDebugEnabled()) {
            logMapDiag(
              `[MAP] applied insets L,R,T,B = ${padLeft.toFixed(6)}, ${padRight.toFixed(6)}, ${padTop.toFixed(6)}, ${padBottom.toFixed(6)}`,
              true
            );
          }
          activePanel?.webview.postMessage({
            type: "streamMap",
            pads: { padLeft, padRight, padTop, padBottom },
          });
        } else {
          const reasons: string[] = [];
          if (!finite) {
            reasons.push("one or more pads are not finite numbers");
          }
          if (!rangeOk) {
            reasons.push("expected each pad in [0,1)");
          }
          if (!capOk) {
            reasons.push("extension rule: each pad must be ≤ 0.49 (reject oversized letterbox)");
          }
          if (!sumOk) {
            reasons.push(
              `horizontal pads sum ${hSum.toFixed(4)} or vertical ${vSum.toFixed(4)} must be < 1`
            );
          }
          logMapDiag(
            `[MAP] received MAP line but extension rejected it — ${reasons.join("; ")}. ` +
              `values: L=${String(raw.padLeft)} R=${String(raw.padRight)} T=${String(raw.padTop)} B=${String(raw.padBottom)}`,
            true
          );
        }
      } catch (e) {
        logMapDiag(`[MAP] JSON parse failed for MAP line: ${String(e)} — raw: ${s.slice(0, 180)}`, true);
      }
      return;
    }
    void vscode.window.showWarningMessage(`Simulator helper: ${line}`);
  });

  let buf = Buffer.alloc(0);
  child.stdout.on("data", (chunk: Buffer) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (len <= 0 || len > 50 * 1024 * 1024) {
        void vscode.window.showErrorMessage("Invalid frame length from helper; stopping.");
        stopStream();
        return;
      }
      if (buf.length < 4 + len) {
        break;
      }
      const jpeg = buf.subarray(4, 4 + len);
      buf = buf.subarray(4 + len);
      const b64 = jpeg.toString("base64");
      // Drop frames if the webview is still busy — keeps the extension host and renderer lighter.
      const now = Date.now();
      if (now - lastFramePostedAt < 16) {
        continue;
      }
      lastFramePostedAt = now;
      panel.webview.postMessage({ type: "frame", dataUrl: `data:image/jpeg;base64,${b64}` });
    }
  });

  child.on("error", (err) => {
    void vscode.window.showErrorMessage(`Simulator stream failed to start: ${String(err)}`);
    stopStream();
  });

  child.on("close", (code, signal) => {
    if (code && code !== 0 && signal !== "SIGTERM") {
      void vscode.window.showInformationMessage(`Simulator stream exited (${code}).`);
    }
    streamProcess = undefined;
  });
}

/** Normalized hit in [0,1]² in **device** space (letterbox removed using `streamPads` from `MAP:`). */
function normalizedHit(
  clientX: number,
  clientY: number,
  dispW: number,
  dispH: number
): { nx: number; ny: number } | undefined {
  if (dispW <= 0 || dispH <= 0) {
    return undefined;
  }
  const x0 = clientX / dispW;
  const y0 = clientY / dispH;
  const { padLeft, padRight, padTop, padBottom } = streamPads;
  const innerW = 1 - padLeft - padRight;
  const innerH = 1 - padTop - padBottom;
  if (innerW <= 1e-9 || innerH <= 1e-9) {
    return {
      nx: Math.max(0, Math.min(1, x0)),
      ny: Math.max(0, Math.min(1, y0)),
    };
  }
  let nx = (x0 - padLeft) / innerW;
  let ny = (y0 - padTop) / innerH;
  nx = Math.max(0, Math.min(1, nx));
  ny = Math.max(0, Math.min(1, ny));
  return { nx, ny };
}

function fmtRat(n: number): string {
  return n.toFixed(6);
}

function touchDebugEnabled(): boolean {
  return !!vscode.workspace.getConfiguration("ios-simulator-embed").get<boolean>("debugTouches");
}

function touchPipelineDebugEnabled(): boolean {
  return !!vscode.workspace.getConfiguration("ios-simulator-embed").get<boolean>("debugTouchPipeline");
}

function resetTouchGestureForDown(hit: { nx: number; ny: number }) {
  touchGestureStartMs = Date.now();
  touchGestureDownNx = hit.nx;
  touchGestureDownNy = hit.ny;
  touchGestureMovesSent = 0;
  touchGestureMovesSkippedThrottle = 0;
  touchGestureMaxDelta = 0;
}

function touchRecordMoveSent(hit: { nx: number; ny: number }) {
  touchGestureMovesSent += 1;
  const dx = hit.nx - touchGestureDownNx;
  const dy = hit.ny - touchGestureDownNy;
  const d = Math.hypot(dx, dy);
  if (d > touchGestureMaxDelta) {
    touchGestureMaxDelta = d;
  }
}

function logTouchDebug(
  phase: string,
  m: { x: number; y: number; w: number; h: number },
  hit: { nx: number; ny: number }
) {
  if (!touchDebugEnabled()) {
    return;
  }
  const x0 = m.x / m.w;
  const y0 = m.y / m.h;
  const { padLeft, padRight, padTop, padBottom } = streamPads;
  debugOutputChannel.appendLine(
    `[touch ${phase}] img (${m.x.toFixed(1)}, ${m.y.toFixed(1)}) / (${m.w.toFixed(1)}×${m.h.toFixed(1)})  ` +
      `inImage (${x0.toFixed(4)}, ${y0.toFixed(4)})  MAP L,R,T,B (${padLeft.toFixed(4)}, ${padRight.toFixed(4)}, ${padTop.toFixed(4)}, ${padBottom.toFixed(4)})  ` +
      `→ device (${hit.nx.toFixed(6)}, ${hit.ny.toFixed(6)})`
  );
}

function logTouchGestureSummary(kind: "up" | "cancel") {
  if (!touchPipelineDebugEnabled() || touchGestureStartMs <= 0) {
    return;
  }
  const dur = Date.now() - touchGestureStartMs;
  const sent = touchGestureMovesSent;
  const skipped = touchGestureMovesSkippedThrottle;
  let hint: string;
  if (sent === 0) {
    hint =
      dur >= 450
        ? "hold / long-press candidate (no moves; recognition delay is app-controlled)"
        : "tap candidate";
  } else {
    hint =
      touchGestureMaxDelta > 0.02
        ? "drag / pan"
        : "small motion (jitter or micro-drag)";
  }
  debugOutputChannel.appendLine(
    `[gesture ${kind}] durationMs=${dur} movesSent=${sent} movesSkippedThrottle=${skipped} maxNormDelta≈${touchGestureMaxDelta.toFixed(5)} → ${hint}`
  );
  if (skipped > sent && sent > 0) {
    debugOutputChannel.appendLine(
      `[gesture ${kind}] note: pointermove is capped at ~60 Hz in the extension (16 ms); skipped events are expected for fast drags.`
    );
  }
  debugOutputChannel.show(true);
}

function ensureTouchSession(bin: string, env: NodeJS.ProcessEnv): boolean {
  if (touchSessionChild && !touchSessionChild.killed) {
    return true;
  }
  stopTouchSession();
  try {
    const child = cp.spawn(bin, ["touch", "sess"], { stdio: ["pipe", "pipe", "pipe"], env });
    touchSessionChild = child;
    touchSessionStderrBuf = "";
    child.stderr?.on("data", (chunk: Buffer) => {
      touchSessionStderrBuf += chunk.toString("utf8");
      let nl: number;
      while ((nl = touchSessionStderrBuf.indexOf("\n")) >= 0) {
        const line = touchSessionStderrBuf.slice(0, nl).trimEnd();
        touchSessionStderrBuf = touchSessionStderrBuf.slice(nl + 1);
        if (line.startsWith("ERR:")) {
          debugOutputChannel.appendLine(`[touch session] ${line}`);
          if (touchDebugEnabled() || touchPipelineDebugEnabled()) {
            debugOutputChannel.show(true);
          }
        } else if (line.startsWith("OK:") && touchPipelineDebugEnabled()) {
          debugOutputChannel.appendLine(`[touch session] ${line}`);
          debugOutputChannel.show(true);
        }
      }
    });
    child.on("error", (e) => {
      void vscode.window.showErrorMessage(`Touch session failed to start: ${String(e)}`);
    });
    child.on("exit", () => {
      touchSessionChild = undefined;
      panelTouchActive = false;
    });
    return true;
  } catch {
    return false;
  }
}

function sendTouchSessionLine(line: string) {
  if (!touchSessionChild?.stdin?.writable) {
    return;
  }
  touchSessionChild.stdin.write(`${line}\n`);
}

function simDeviceArg(): string {
  const u = vscode.workspace.getConfiguration("ios-simulator-embed").get<string>("simulatorUdid")?.trim();
  return u && u.length > 0 ? u : "booted";
}

/** Bundle id of the app that is frontmost now (call before activating Simulator). */
function getFrontmostAppBundleIdSync(): string | undefined {
  try {
    const out = cp.execFileSync(
      "osascript",
      [
        "-e",
        'tell application "System Events" to get bundle identifier of first application process whose frontmost is true',
      ],
      { encoding: "utf8", timeout: 5000 }
    );
    const s = out.trim();
    return s.length > 0 ? s : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Sends a keyboard shortcut while Simulator is briefly activated, then restores the previous front app.
 * Avoids leaving Simulator on top after chrome toolbar actions.
 */
function runSimulatorHostShortcut(systemEventsCommand: string, errorLabel: string) {
  const previousBundleId = getFrontmostAppBundleIdSync();
  const args: string[] = [
    "-e",
    'tell application "Simulator" to activate',
    "-e",
    "delay 0.18",
    "-e",
    `tell application "System Events" to ${systemEventsCommand}`,
  ];
  if (previousBundleId) {
    const esc = previousBundleId.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    args.push("-e", "delay 0.12");
    args.push("-e", `try\ntell application id "${esc}" to activate\nend try`);
  }
  cp.execFile("osascript", args, (err) => {
    if (err) {
      void vscode.window.showErrorMessage(
        `${errorLabel} Grant Accessibility to this app for “System Events”, or run the shortcut in Simulator. ${String(err)}`
      );
    }
  });
}

function flushHomeChromeSchedule() {
  if (homeChromeTimer !== undefined) {
    clearTimeout(homeChromeTimer);
    homeChromeTimer = undefined;
  }
  homeChromeClickCount = 0;
}

/**
 * Sends one or two ⌘⇧H presses in a single Simulator foreground session (required for app switcher).
 */
function runSimulatorHomePresses(presses: 1 | 2) {
  const t = homeChromeTimingFromConfig();
  const previousBundleId = getFrontmostAppBundleIdSync();
  const args: string[] = [
    "-e",
    'tell application "Simulator" to activate',
    "-e",
    `delay ${appleScriptDelaySeconds(t.afterActivateMs)}`,
  ];
  for (let i = 0; i < presses; i++) {
    args.push(
      "-e",
      'tell application "System Events" to keystroke "h" using {command down, shift down}'
    );
    if (i < presses - 1) {
      args.push("-e", `delay ${appleScriptDelaySeconds(t.betweenDoubleKeyMs)}`);
    }
  }
  args.push("-e", `delay ${appleScriptDelaySeconds(t.beforeRestoreMs)}`);
  if (previousBundleId) {
    const esc = previousBundleId.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    args.push("-e", `try\ntell application id "${esc}" to activate\nend try`);
  }
  const errLabel =
    presses === 2
      ? "Double home (app switcher) failed."
      : "Hardware home (⌘⇧H) failed.";
  cp.execFile("osascript", args, (err) => {
    if (err) {
      void vscode.window.showErrorMessage(
        `${errLabel} Grant Accessibility to this app for “System Events”, or run the shortcut in Simulator. ${String(err)}`
      );
    }
  });
}

/** Coalesce toolbar Home clicks: one click after idle → single home; two quick clicks → double home. */
function scheduleSimulatorHomeToolbarClick() {
  const t = homeChromeTimingFromConfig();
  homeChromeClickCount += 1;
  if (homeChromeTimer !== undefined) {
    clearTimeout(homeChromeTimer);
  }
  const delay = homeChromeClickCount >= 2 ? t.doubleFlushMs : t.singleWaitMs;
  homeChromeTimer = setTimeout(() => {
    homeChromeTimer = undefined;
    const presses = (homeChromeClickCount >= 2 ? 2 : 1) as 1 | 2;
    homeChromeClickCount = 0;
    runSimulatorHomePresses(presses);
  }, delay);
}

async function runChromeAction(context: vscode.ExtensionContext, action: string) {
  switch (action) {
    case "screenshot": {
      const dev = simDeviceArg();
      const tmp = path.join(os.tmpdir(), `ios-sim-embed-screenshot-${process.pid}-${Date.now()}.png`);
      try {
        cp.execFileSync("xcrun", ["simctl", "io", dev, "screenshot", tmp, "--type=png"], {
          maxBuffer: 32 * 1024 * 1024,
        });
        const png = fs.readFileSync(tmp);
        const name = `simulator-screenshot-${Date.now()}.png`;
        const folder = vscode.workspace.workspaceFolders?.[0]?.uri;
        const target = folder
          ? vscode.Uri.joinPath(folder, name)
          : vscode.Uri.joinPath(context.globalStorageUri, name);
        if (!folder) {
          try {
            await vscode.workspace.fs.createDirectory(context.globalStorageUri);
          } catch {
            /* directory may already exist */
          }
        }
        await vscode.workspace.fs.writeFile(target, png);
        const pick = await vscode.window.showInformationMessage(
          `Saved simulator screenshot (${dev}).`,
          "Reveal in Finder",
          "Copy path"
        );
        if (pick === "Reveal in Finder") {
          await vscode.commands.executeCommand("revealFileInOS", target);
        } else if (pick === "Copy path") {
          await vscode.env.clipboard.writeText(target.fsPath);
        }
      } catch (e) {
        void vscode.window.showErrorMessage(`simctl screenshot failed: ${String(e)}`);
      } finally {
        try {
          fs.unlinkSync(tmp);
        } catch {
          /* temp may be missing if simctl failed before creating it */
        }
      }
      break;
    }
    case "home": {
      scheduleSimulatorHomeToolbarClick();
      break;
    }
    case "rotate": {
      runSimulatorHostShortcut(
        "key code 124 using command down",
        "Rotate (⌘→) failed."
      );
      break;
    }
    default:
      break;
  }
}

function runTouchMapDebugHelp() {
  debugOutputChannel.clear();
  debugOutputChannel.appendLine("=== iOS Simulator Embed — debug checklist ===");
  debugOutputChannel.appendLine("");
  debugOutputChannel.appendLine("Output panel: View → Output → channel “iOS Simulator Embed”.");
  debugOutputChannel.appendLine("");
  debugOutputChannel.appendLine("Settings (Workspace / User):");
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.debugMap — MAP letterbox, BOUNDS, MAP_SKIP / MAP_DEBUG from stream helper. Reopen streamed panel after toggle."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.debugTouches — coordinates per down/move/up + HUD on the stream image."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.debugTouchPipeline — OK:d|m|u from native HID session, gesture summary on release, throttle skip counts."
  );
  debugOutputChannel.appendLine("• ios-simulator-embed.simulatorUdid — if multiple booted devices or wrong touch target.");
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.targetBundleId — if the stream picks the wrong window (use List capture windows NDJSON)."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.mapStackVerticalLetterboxOnTop — vertical letterbox above LCD vs centered fit."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.streamMaxWidthPx / streamMaxHeightPx — cap the streamed image size in the panel (default width 430px)."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.streamShowUsageHint — expandable MAP/debug help at the top of the stream panel."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.streamJpegQuality — JPEG quality for the stream (reopen panel after change)."
  );
  debugOutputChannel.appendLine(
    "• ios-simulator-embed.homeToolbar* / homeAfter* / homeBetween* / homeBefore* — toolbar Home timing (ms)."
  );
  debugOutputChannel.appendLine("");
  debugOutputChannel.appendLine("Commands:");
  debugOutputChannel.appendLine("• iOS Simulator: List capture windows (debug) — NDJSON of ScreenCaptureKit shareable windows.");
  debugOutputChannel.appendLine("");
  debugOutputChannel.appendLine("Gesture goals vs implementation:");
  debugOutputChannel.appendLine(
    "• Tap — down + up at same spot; use debugTouches to confirm nx,ny and no stray moves (jitter can cancel long-press)."
  );
  debugOutputChannel.appendLine(
    "• Long press — hold without moving; duration until the menu appears is defined by the app / iOS, not the extension."
  );
  debugOutputChannel.appendLine(
    "• Drag — down, many moves (see OK:m vs ERR:), up; pipeline summary shows movesSent and maxNormDelta."
  );
  debugOutputChannel.appendLine(
    "• Toolbar (Home, Screenshot, Rotate) — host Automation: Home supports two quick clicks for app switcher; simctl screenshot via temp file; Rotate ⌘→; needs Accessibility for System Events."
  );
  debugOutputChannel.appendLine(
    "• Notification / Control Center drawers — edge pans from top/bottom; confirm MAP pads (debugMap) so y≈0 / y≈1 hit the bezel area."
  );
  debugOutputChannel.appendLine("");
  debugOutputChannel.appendLine(
    "If OK:m lines are missing but ERR: repeats on move, SimulatorKit may not be building Indigo drag messages on your Xcode version — compare with a known-good simulator OS."
  );
  debugOutputChannel.show(true);
}

function runListWindowsDebug(context: vscode.ExtensionContext) {
  const bin = ensureHelperBuilt(context);
  if (!bin) {
    return;
  }
  debugOutputChannel.clear();
  debugOutputChannel.appendLine(
    "ios-sim-helper list — NDJSON lines, largest windows first. Fields: bundleId, appName, title, windowID, x, y, width, height, area."
  );
  debugOutputChannel.appendLine(
    "Set `ios-simulator-embed.targetBundleId` to the Simulator row’s `bundleId` if the default stream target is wrong."
  );
  debugOutputChannel.appendLine("");
  const child = cp.spawn(bin, ["list"], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });
  let combined = "";
  child.stdout?.on("data", (d: Buffer) => {
    combined += d.toString("utf8");
  });
  child.stderr?.on("data", (d: Buffer) => {
    combined += d.toString("utf8");
  });
  child.on("error", (err) => {
    debugOutputChannel.appendLine(`spawn error: ${String(err)}`);
    debugOutputChannel.show(true);
  });
  child.on("close", (code) => {
    debugOutputChannel.appendLine(combined.trimEnd() || "(no stdout/stderr)");
    if (code !== 0) {
      debugOutputChannel.appendLine(`(exit code ${code})`);
    }
    debugOutputChannel.show(true);
  });
}

export function activate(context: vscode.ExtensionContext) {
  context.subscriptions.push(debugOutputChannel);

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!activePanel) {
        return;
      }
      if (
        e.affectsConfiguration("ios-simulator-embed.debugTouches") ||
        e.affectsConfiguration("ios-simulator-embed.streamMaxWidthPx") ||
        e.affectsConfiguration("ios-simulator-embed.streamMaxHeightPx") ||
        e.affectsConfiguration("ios-simulator-embed.streamShowUsageHint")
      ) {
        activePanel.webview.postMessage({ type: "init", ...streamPanelInitPayload() });
      }
      if (e.affectsConfiguration("ios-simulator-embed.debugMap")) {
        debugOutputChannel.appendLine(
          "[MAP] `debugMap` changed — stop and reopen the streamed panel so the capture helper restarts with MAP_DEBUG env and fresh stderr lines."
        );
        if (mapDebugEnabled()) {
          debugOutputChannel.show(true);
        }
      }
      if (e.affectsConfiguration("ios-simulator-embed.mapStackVerticalLetterboxOnTop")) {
        debugOutputChannel.appendLine(
          "[MAP] `mapStackVerticalLetterboxOnTop` changed — reopen the stream panel so ios-sim-helper restarts with updated IOS_SIM_HELPER_MAP_TOP_STACK."
        );
        if (mapDebugEnabled()) {
          debugOutputChannel.show(true);
        }
      }
      if (e.affectsConfiguration("ios-simulator-embed.debugTouchPipeline")) {
        debugOutputChannel.appendLine(
          "[touch] `debugTouchPipeline` changed — next touch starts a new session with IOS_SIM_HELPER_TOUCH_DEBUG; or stop/reopen the stream panel."
        );
        debugOutputChannel.show(true);
      }
      if (e.affectsConfiguration("ios-simulator-embed.streamJpegQuality")) {
        debugOutputChannel.appendLine(
          "[stream] `streamJpegQuality` changed — stop and reopen the streamed panel so the capture helper restarts with IOS_SIM_HELPER_JPEG_QUALITY."
        );
        debugOutputChannel.show(true);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ios-simulator-embed.openPanel", () => {
      if (!isMacOSHost()) {
        void vscode.window.showErrorMessage(
          "iOS Simulator stream requires macOS (ScreenCaptureKit and Simulator)."
        );
        return;
      }
      if (activePanel) {
        activePanel.reveal(vscode.ViewColumn.Two);
        return;
      }

      const panel = vscode.window.createWebviewPanel(
        "iosSimulatorStream",
        "iOS Simulator (stream)",
        vscode.ViewColumn.Two,
        { enableScripts: true, retainContextWhenHidden: true }
      );
      activePanel = panel;
      panel.webview.html = panelHtml(panel.webview);

      panel.webview.onDidReceiveMessage(
        (msg) => {
          if (!msg || typeof msg !== "object") {
            return;
          }
          const m = msg as Record<string, unknown>;

          if (m.type === "panelReady") {
            panel.webview.postMessage({ type: "init", ...streamPanelInitPayload() });
            return;
          }

          if (m.type === "chrome" && typeof m.action === "string") {
            void runChromeAction(context, m.action);
            return;
          }

          const mt = m.type;
          if (mt !== "touchDown" && mt !== "touchMove" && mt !== "touchUp" && mt !== "touchCancel") {
            return;
          }
          if (
            typeof m.x !== "number" ||
            typeof m.y !== "number" ||
            typeof m.w !== "number" ||
            typeof m.h !== "number"
          ) {
            return;
          }
          const px = m.x;
          const py = m.y;
          const pw = m.w;
          const ph = m.h;
          if (![px, py, pw, ph].every((n) => Number.isFinite(n))) {
            return;
          }
          const bin = ensureHelperBuilt(context);
          if (!bin) {
            return;
          }
          const env = helperEnvForCapture();
          const hit = normalizedHit(px, py, pw, ph);
          if (!hit || !Number.isFinite(hit.nx) || !Number.isFinite(hit.ny)) {
            return;
          }
          const coords = { x: px, y: py, w: pw, h: ph };

          if (m.type === "touchDown" && m.button === 0) {
            if (!ensureTouchSession(bin, env)) {
              void vscode.window.showErrorMessage("Could not start HID touch session; rebuild the native helper (npm run build:native).");
              return;
            }
            panelTouchActive = true;
            panelTouchLastMoveMs = 0;
            resetTouchGestureForDown(hit);
            logTouchDebug("down", coords, hit);
            sendTouchSessionLine(`d ${fmtRat(hit.nx)} ${fmtRat(hit.ny)}`);
            return;
          }
          if (m.type === "touchMove" && panelTouchActive) {
            const now = Date.now();
            if (now - panelTouchLastMoveMs < 16) {
              touchGestureMovesSkippedThrottle += 1;
              return;
            }
            panelTouchLastMoveMs = now;
            touchRecordMoveSent(hit);
            logTouchDebug("move", coords, hit);
            sendTouchSessionLine(`m ${fmtRat(hit.nx)} ${fmtRat(hit.ny)}`);
            return;
          }
          if ((m.type === "touchUp" || m.type === "touchCancel") && panelTouchActive) {
            panelTouchActive = false;
            logTouchDebug(m.type === "touchUp" ? "up" : "cancel", coords, hit);
            logTouchGestureSummary(m.type === "touchUp" ? "up" : "cancel");
            sendTouchSessionLine(`u ${fmtRat(hit.nx)} ${fmtRat(hit.ny)}`);
          }
        },
        undefined,
        context.subscriptions
      );

      startStream(context, panel);

      panel.onDidDispose(() => {
        stopStream();
        activePanel = undefined;
        panelTouchActive = false;
      });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ios-simulator-embed.stopPanel", () => {
      stopStream();
      activePanel?.dispose();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ios-simulator-embed.listWindows", () => {
      if (!isMacOSHost()) {
        void vscode.window.showErrorMessage("List capture windows requires macOS.");
        return;
      }
      runListWindowsDebug(context);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("ios-simulator-embed.debugHelp", () => {
      runTouchMapDebugHelp();
    })
  );
}

export function deactivate() {
  flushHomeChromeSchedule();
  stopStream();
}

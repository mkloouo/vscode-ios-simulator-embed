import * as cp from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as readline from "readline";
import * as vscode from "vscode";

type Bounds = { x: number; y: number; width: number; height: number };

let activePanel: vscode.WebviewPanel | undefined;
let streamProcess: cp.ChildProcessWithoutNullStreams | undefined;
let latestBounds: Bounds | undefined;
let lastFramePostedAt = 0;

const debugOutputChannel = vscode.window.createOutputChannel("iOS Simulator Embed");

/** Merged env for stream/click so the helper can filter by bundle ID. */
function helperEnvForCapture(): NodeJS.ProcessEnv {
  const id = vscode.workspace
    .getConfiguration("ios-simulator-embed")
    .get<string>("targetBundleId")
    ?.trim();
  if (id) {
    return { ...process.env, IOS_SIM_HELPER_BUNDLE_ID: id };
  }
  return { ...process.env };
}

function helperPath(context: vscode.ExtensionContext): string {
  return path.join(
    context.extensionPath,
    "native",
    "ios-sim-helper",
    ".build",
    "release",
    "ios-sim-helper"
  );
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

function stopStream() {
  if (streamProcess && !streamProcess.killed) {
    try {
      streamProcess.stdin.end();
    } catch {
      /* ignore */
    }
    streamProcess.kill("SIGTERM");
  }
  streamProcess = undefined;
  latestBounds = undefined;
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
    #wrap { position: relative; display: inline-block; max-width: 100%; }
    #frame { display: block; max-width: 100%; height: auto; cursor: pointer; user-select: none; touch-action: none; background: #111; }
    #hint { font-size: 12px; opacity: 0.75; margin-bottom: 8px; }
  </style>
</head>
<body>
  <div id="hint">Streamed Simulator (Screen Recording + Accessibility). Left-click: the system cursor briefly moves to the Simulator and back so taps register.</div>
  <div id="wrap">
    <img id="frame" alt="Simulator stream" draggable="false" />
  </div>
  <script nonce="streampanel">
    const vscode = acquireVsCodeApi();
    const img = document.getElementById('frame');

    window.addEventListener('message', (event) => {
      const msg = event.data;
      if (msg && msg.type === 'frame' && typeof msg.dataUrl === 'string') {
        img.src = msg.dataUrl;
      }
    });

    function relCoords(ev) {
      const r = img.getBoundingClientRect();
      const x = ev.clientX - r.left;
      const y = ev.clientY - r.top;
      if (x < 0 || y < 0 || x > r.width || y > r.height) return null;
      return { x, y, w: r.width, h: r.height, nw: img.naturalWidth, nh: img.naturalHeight };
    }

    img.addEventListener('pointerdown', (ev) => {
      ev.preventDefault();
      const p = relCoords(ev);
      if (!p || !p.nw || !p.nh) return;
      vscode.postMessage({ type: 'pointerDown', ...p, button: ev.button });
    });
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

  const child = cp.spawn(bin, ["stream"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: helperEnvForCapture(),
  });
  streamProcess = child;

  const rl = readline.createInterface({ input: child.stderr });
  rl.on("line", (line) => {
    if (line.startsWith("BOUNDS:")) {
      try {
        const json = line.slice("BOUNDS:".length);
        latestBounds = JSON.parse(json) as Bounds;
      } catch {
        /* ignore */
      }
    } else if (line.trim()) {
      void vscode.window.showWarningMessage(`Simulator helper: ${line}`);
    }
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
      if (now - lastFramePostedAt < 66) {
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

function mapClickToQuartz(
  bounds: Bounds,
  clientX: number,
  clientY: number,
  dispW: number,
  dispH: number
): { x: number; y: number } | undefined {
  if (dispW <= 0 || dispH <= 0) {
    return undefined;
  }
  const lx = (clientX / dispW) * bounds.width;
  const lyFromTop = (clientY / dispH) * bounds.height;
  // Same space as `SCWindow.frame` / `NSEvent.mouseLocation` / `CGEvent` (global **points**, bottom-left origin).
  const qx = bounds.x + lx;
  const qy = bounds.y + bounds.height - lyFromTop;
  return { x: qx, y: qy };
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
    vscode.commands.registerCommand("ios-simulator-embed.openPanel", () => {
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
          if (msg?.type !== "pointerDown" || msg.button !== 0) {
            return;
          }
          const b = latestBounds;
          const bin = ensureHelperBuilt(context);
          if (!b || !bin) {
            return;
          }
          const pt = mapClickToQuartz(b, msg.x, msg.y, msg.w, msg.h);
          if (!pt) {
            return;
          }
          cp.spawn(bin, ["click", String(pt.x), String(pt.y)], {
            stdio: "ignore",
            detached: true,
            env: helperEnvForCapture(),
          }).unref();
        },
        undefined,
        context.subscriptions
      );

      startStream(context, panel);

      panel.onDidDispose(() => {
        stopStream();
        activePanel = undefined;
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
      runListWindowsDebug(context);
    })
  );
}

export function deactivate() {
  stopStream();
}

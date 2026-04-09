/**
 * USB HID keyboard usage IDs (page 0x07) for Indigo / SimDeviceLegacyHIDClient.
 * Lines sent to `ios-sim-helper touch sess`: kp (press), kd (down), ku (up).
 */

export type WebKeyFields = {
  key: string;
  code: string;
  repeat: boolean;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
};

const HID_LEFT_CTRL = 224;
const HID_LEFT_SHIFT = 225;
const HID_LEFT_ALT = 226;
const HID_LEFT_GUI = 227;

/** `ev.code` → HID usage (unshifted physical key). */
const CODE_TO_HID: Record<string, number> = {
  KeyA: 4,
  KeyB: 5,
  KeyC: 6,
  KeyD: 7,
  KeyE: 8,
  KeyF: 9,
  KeyG: 10,
  KeyH: 11,
  KeyI: 12,
  KeyJ: 13,
  KeyK: 14,
  KeyL: 15,
  KeyM: 16,
  KeyN: 17,
  KeyO: 18,
  KeyP: 19,
  KeyQ: 20,
  KeyR: 21,
  KeyS: 22,
  KeyT: 23,
  KeyU: 24,
  KeyV: 25,
  KeyW: 26,
  KeyX: 27,
  KeyY: 28,
  KeyZ: 29,
  Digit1: 30,
  Digit2: 31,
  Digit3: 32,
  Digit4: 33,
  Digit5: 34,
  Digit6: 35,
  Digit7: 36,
  Digit8: 37,
  Digit9: 38,
  Digit0: 39,
  Enter: 40,
  NumpadEnter: 40,
  Escape: 41,
  Backspace: 42,
  Tab: 43,
  Space: 44,
  Minus: 45,
  Equal: 46,
  BracketLeft: 47,
  BracketRight: 48,
  Backslash: 49,
  Semicolon: 51,
  Quote: 52,
  Backquote: 53,
  Comma: 54,
  Period: 55,
  Slash: 56,
  CapsLock: 57,
  F1: 58,
  F2: 59,
  F3: 60,
  F4: 61,
  F5: 62,
  F6: 63,
  F7: 64,
  F8: 65,
  F9: 66,
  F10: 67,
  F11: 68,
  F12: 69,
  Insert: 73,
  Home: 74,
  PageUp: 75,
  Delete: 76,
  End: 77,
  PageDown: 78,
  ArrowRight: 79,
  ArrowLeft: 80,
  ArrowDown: 81,
  ArrowUp: 82,
  NumpadDivide: 84,
  NumpadMultiply: 85,
  NumpadSubtract: 86,
  NumpadAdd: 87,
  Numpad1: 89,
  Numpad2: 90,
  Numpad3: 91,
  Numpad4: 92,
  Numpad5: 93,
  Numpad6: 94,
  Numpad7: 95,
  Numpad8: 96,
  Numpad9: 97,
  Numpad0: 98,
  NumpadDecimal: 99,
};

function kp(usage: number): string {
  return `kp ${usage}`;
}

/**
 * Wrap inner `kp` lines with modifier down/up.
 * Press: ⌘ → Ctrl → Alt → Shift (GUI first, Mac-idiomatic for chords).
 * Release: exact reverse (required for multi-modifier shortcuts like ⌃⌘Z).
 */
function wrapModifiers(inner: string[], ev: WebKeyFields): string[] {
  const mods: number[] = [];
  if (ev.metaKey) {
    mods.push(HID_LEFT_GUI);
  }
  if (ev.ctrlKey) {
    mods.push(HID_LEFT_CTRL);
  }
  if (ev.altKey) {
    mods.push(HID_LEFT_ALT);
  }
  if (ev.shiftKey) {
    mods.push(HID_LEFT_SHIFT);
  }
  const down = mods.map((m) => `kd ${m}`);
  const up = [...mods].reverse().map((m) => `ku ${m}`);
  return [...down, ...inner, ...up];
}

/**
 * Session stdin lines for one key event from the webview (Indigo HID, no AppleScript).
 */
export function hidSessionLinesForWebKey(ev: WebKeyFields): string[] {
  const k = ev.key;
  if (k === "Shift" || k === "Control" || k === "Alt" || k === "Meta") {
    return [];
  }
  if (k === "Unidentified" || k === "Process") {
    return [];
  }

  const usage = CODE_TO_HID[ev.code];
  if (usage !== undefined) {
    return wrapModifiers([kp(usage)], ev);
  }

  if (k.length === 1) {
    const cp = k.codePointAt(0);
    if (cp === undefined || cp > 0x7f) {
      return [];
    }
    const ch = k;
    if (ch >= "a" && ch <= "z") {
      return wrapModifiers([kp(4 + (ch.charCodeAt(0) - 97))], ev);
    }
    if (ch >= "A" && ch <= "Z") {
      const u = 4 + (ch.charCodeAt(0) - 65);
      if (ev.shiftKey) {
        return wrapModifiers([kp(u)], ev);
      }
      return wrapModifiers([kp(u)], { ...ev, shiftKey: true });
    }
    if (ch >= "0" && ch <= "9") {
      const digitUsage = ch === "0" ? 39 : 29 + (ch.charCodeAt(0) - 48);
      return wrapModifiers([kp(digitUsage)], ev);
    }
    if (ch === " ") {
      return wrapModifiers([kp(44)], ev);
    }
  }

  return [];
}

/** Typed text: ASCII letters, digits, space; other chars skipped. */
export function hidSessionLinesForTextBatch(text: string): string[] {
  const lines: string[] = [];
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    if (cp === undefined || cp > 0x7f) {
      continue;
    }
    if (ch >= "a" && ch <= "z") {
      lines.push(kp(4 + (ch.charCodeAt(0) - 97)));
      continue;
    }
    if (ch >= "A" && ch <= "Z") {
      const u = 4 + (ch.charCodeAt(0) - 65);
      lines.push(`kd ${HID_LEFT_SHIFT}`, kp(u), `ku ${HID_LEFT_SHIFT}`);
      continue;
    }
    if (ch >= "0" && ch <= "9") {
      lines.push(kp(ch === "0" ? 39 : 29 + (ch.charCodeAt(0) - 48)));
      continue;
    }
    if (ch === " ") {
      lines.push(kp(44));
    }
  }
  return lines;
}

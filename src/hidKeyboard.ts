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
  /** Non-US \ and | (ISO layouts). */
  IntlBackslash: 100,
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

function shiftChord(usage: number): string[] {
  return [`kd ${HID_LEFT_SHIFT}`, kp(usage), `ku ${HID_LEFT_SHIFT}`];
}

function altChord(usage: number): string[] {
  return [`kd ${HID_LEFT_ALT}`, kp(usage), `ku ${HID_LEFT_ALT}`];
}

/** True if these stdin lines already press Shift (avoid double with ev.shiftKey). */
function linesIncludeShiftDown(lines: string[]): boolean {
  return lines.includes(`kd ${HID_LEFT_SHIFT}`);
}

/** True if these lines already press Alt (avoid double with ev.altKey). */
function linesIncludeAltDown(lines: string[]): boolean {
  return lines.includes(`kd ${HID_LEFT_ALT}`);
}

/** Strip modifier flags that are already encoded inside `lines` (shift-chord / option-chord). */
function webKeyWithoutRedundantChordModifiers(lines: string[], ev: WebKeyFields): WebKeyFields {
  return {
    ...ev,
    shiftKey: linesIncludeShiftDown(lines) ? false : ev.shiftKey,
    altKey: linesIncludeAltDown(lines) ? false : ev.altKey,
  };
}

/**
 * US QWERTY: one character → HID lines (may include shift/alt inside).
 * ASCII 32–126; TAB/LF; null if unsupported.
 */
export function hidLinesForAsciiChar(ch: string): string[] | null {
  const cp = ch.codePointAt(0);
  if (cp === undefined) {
    return null;
  }
  if (cp === 9) {
    return [kp(43)];
  }
  if (cp === 10) {
    return [kp(40)];
  }
  if (cp < 32 || cp > 126) {
    return null;
  }

  if (ch >= "a" && ch <= "z") {
    return [kp(4 + (ch.charCodeAt(0) - 97))];
  }
  if (ch >= "A" && ch <= "Z") {
    return shiftChord(4 + (ch.charCodeAt(0) - 65));
  }
  if (ch >= "0" && ch <= "9") {
    return [kp(ch === "0" ? 39 : 29 + (ch.charCodeAt(0) - 48))];
  }

  const shiftNum: Record<string, number> = {
    "!": 30,
    "@": 31,
    "#": 32,
    $: 33,
    "%": 34,
    "^": 35,
    "&": 36,
    "*": 37,
    "(": 38,
    ")": 39,
  };
  if (shiftNum[ch] !== undefined) {
    return shiftChord(shiftNum[ch]);
  }

  switch (ch) {
    case " ":
      return [kp(44)];
    case "`":
      return [kp(53)];
    case "~":
      return shiftChord(53);
    case "-":
      return [kp(45)];
    case "_":
      return shiftChord(45);
    case "=":
      return [kp(46)];
    case "+":
      return shiftChord(46);
    case "[":
      return [kp(47)];
    case "{":
      return shiftChord(47);
    case "]":
      return [kp(48)];
    case "}":
      return shiftChord(48);
    case "\\":
      return [kp(49)];
    case "|":
      return shiftChord(49);
    case ";":
      return [kp(51)];
    case ":":
      return shiftChord(51);
    case "'":
      return [kp(52)];
    case '"':
      return shiftChord(52);
    case ",":
      return [kp(54)];
    case "<":
      return shiftChord(54);
    case ".":
      return [kp(55)];
    case ">":
      return shiftChord(55);
    case "/":
      return [kp(56)];
    case "?":
      return shiftChord(56);
    default:
      return null;
  }
}

/**
 * Latin-1 / common symbols not in ASCII (layout approximations, US Mac–oriented).
 */
function hidLinesForLatin1Char(ch: string): string[] {
  const cp = ch.codePointAt(0);
  if (cp === undefined) {
    return [];
  }
  // £ — Option+3 on typical US Mac keyboard
  if (cp === 0xa3) {
    return altChord(32);
  }
  // § — Option+6 on many Mac layouts (varies by region)
  if (cp === 0xa7) {
    return altChord(35);
  }
  return [];
}

/** Iterate Unicode scalar values (handles astral planes for batch paste). */
function forEachCodePoint(text: string, fn: (ch: string) => void): void {
  for (let i = 0; i < text.length; ) {
    const cp = text.codePointAt(i);
    if (cp === undefined) {
      break;
    }
    fn(String.fromCodePoint(cp));
    i += cp > 0xffff ? 2 : 1;
  }
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

  const ascii = hidLinesForAsciiChar(k);
  if (ascii !== null && ascii.length > 0) {
    return wrapModifiers(ascii, webKeyWithoutRedundantChordModifiers(ascii, ev));
  }

  const latin = hidLinesForLatin1Char(k);
  if (latin.length > 0) {
    return wrapModifiers(latin, webKeyWithoutRedundantChordModifiers(latin, ev));
  }

  return [];
}

/** Typed / pasted text: US QWERTY punctuation, TAB/LF, and a few Latin-1 symbols. */
export function hidSessionLinesForTextBatch(text: string): string[] {
  const lines: string[] = [];
  forEachCodePoint(text, (ch) => {
    const a = hidLinesForAsciiChar(ch);
    if (a !== null && a.length > 0) {
      lines.push(...a);
      return;
    }
    lines.push(...hidLinesForLatin1Char(ch));
  });
  return lines;
}

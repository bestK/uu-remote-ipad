'use strict';
/* backboardd HID agent: touch injection via BKHIDSystemInterface.injectHIDEvent:.
   Coordinates are normalized 0..1. */
const STATE = { sender: null, held: false, mode: 0 };

function findExp(n) {
  try { return Module.getGlobalExportByName(n); } catch (e) {}
  const mods = ['/System/Library/Frameworks/IOKit.framework/IOKit',
                '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'];
  for (const p of mods) { try { return Module.load(p).getExportByName(n); } catch (e) {} }
  return null;
}
const absTime = new NativeFunction(findExp('mach_absolute_time'), 'uint64', []);

function discoverSender() {
  try {
    const inst = ObjC.classes.BKHIDSystemInterface.sharedInstance();
    const cache = inst.senderCache();
    const d = cache.senderIDToSenderInfo();
    const keys = d.allKeys();
    let touch = null, multi = null;
    for (let i = 0; i < keys.count(); i++) {
      const k = keys.objectAtIndex_(i);
      const v = String(d.objectForKey_(k));
      if (/primaryUsagePage:0xd\b/.test(v) && /primaryUsage:0x1\b/.test(v)) touch = k;
      if (/AppleMultitouchDevice/.test(v) && !multi) multi = k;
    }
    const chosen = touch || multi;
    if (chosen) return uint64(chosen.toString());
  } catch (e) {}
  return uint64('0x100000761');
}

let HID = null;
function ensureHid() {
  if (HID) return HID;
  const CreateParent = new NativeFunction(findExp('IOHIDEventCreateDigitizerEvent'), 'pointer',
    ['pointer', ['uint32','uint32'], 'int','uint32','uint32','uint32','uint32','double','double','double','double','double','int','int','int']);
  const CreateFinger = new NativeFunction(findExp('IOHIDEventCreateDigitizerFingerEvent'), 'pointer',
    ['pointer', ['uint32','uint32'], 'uint32','uint32','uint32','double','double','double','double','double','uint8','uint8','uint32']);
  const Append = new NativeFunction(findExp('IOHIDEventAppendEvent'), 'void', ['pointer','pointer']);
  const SetInt = new NativeFunction(findExp('IOHIDEventSetIntegerValue'), 'void', ['pointer','uint32','int']);
  const SetIntOpt = findExp('IOHIDEventSetIntegerValueWithOptions')
    ? new NativeFunction(findExp('IOHIDEventSetIntegerValueWithOptions'), 'void', ['pointer','uint32','int','int']) : null;
  const SetFloat = new NativeFunction(findExp('IOHIDEventSetFloatValue'), 'void', ['pointer','uint32','double']);
  const SetSender = new NativeFunction(findExp('IOHIDEventSetSenderID'), 'void', ['pointer','uint64']);
  const CreateClient = new NativeFunction(findExp('IOHIDEventSystemClientCreate'), 'pointer', ['pointer']);
  const Dispatch = new NativeFunction(findExp('IOHIDEventSystemClientDispatchEvent'), 'void', ['pointer','pointer']);
  const Rel = new NativeFunction(findExp('CFRelease'), 'void', ['pointer']);
  HID = { CreateParent, CreateFinger, Append, SetInt, SetIntOpt, SetFloat, SetSender, Dispatch, Rel, client: CreateClient(ptr(0)) };
  return HID;
}

function pingUserEvent() {
  try {
    const t = ObjC.classes.BKUserEventTimer.sharedInstance();
    if (t['- userEventOccurredOnDisplay:']) t.userEventOccurredOnDisplay_(ptr(0));
    else if (t['- userEventOccurred']) t.userEventOccurred();
  } catch (e) {}
}

function inject(event) {
  const h = ensureHid();
  pingUserEvent();
  if (STATE.mode !== 1) {
    try {
      const C = ObjC.classes.BKHIDSystemInterface;
      const inst = C && C.sharedInstance();
      if (inst && inst['- injectHIDEvent:']) { inst.injectHIDEvent_(event); return true; }
    } catch (e) {}
  }
  h.Dispatch(h.client, event);
  return false;
}

function post(mask, range, touch, nx, ny) {
  const h = ensureHid();
  if (!STATE.sender) STATE.sender = discoverSender();
  const t = absTime();
  const stamp = [t.and(0xffffffff).toNumber(), t.shr(32).toNumber()];
  const parent = h.CreateParent(ptr(0), stamp, 3, 99, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  if (parent.isNull()) throw new Error('no parent');
  h.SetInt(parent, 0xb0019, 1);
  h.SetInt(parent, 0x4, 1);
  if (h.SetIntOpt) {
    h.SetIntOpt(parent, 0xb0019, 1, -268435456);
    h.SetIntOpt(parent, 0x4, 1, -268435456);
    h.SetIntOpt(parent, 0xb0007, mask === 4 ? 4 : 35, -268435456);
    h.SetIntOpt(parent, 0xb0008, touch, -268435456);
    h.SetIntOpt(parent, 0xb0009, touch, -268435456);
  }
  const child = h.CreateFinger(ptr(0), stamp, 1, 3, mask, nx, ny, 0, 0, 0, range, touch, 0);
  if (child.isNull()) { h.Rel(parent); throw new Error('no finger'); }
  h.SetFloat(child, 0xb0014, 0.04);
  h.SetFloat(child, 0xb0015, 0.04);
  h.Append(parent, child);
  h.SetInt(parent, 0xb0007, 0x23);
  h.SetInt(parent, 0xb0008, 1);
  h.SetInt(parent, 0xb0009, 1);
  h.SetSender(parent, STATE.sender);
  inject(parent);
  h.Rel(parent);
}

// ---- keyboard --------------------------------------------------------------
// A keyboard event needs a keyboard sender; the touch sender only carries digitizer events.
const KB = { sender: null, forced: null };
function discoverKeyboardSender() {
  if (KB.forced) return uint64(String(KB.forced));
  try {
    const inst = ObjC.classes.BKHIDSystemInterface.sharedInstance();
    const d = inst.senderCache().senderIDToSenderInfo();
    const keys = d.allKeys();
    let keyboard = null, generic = null;
    for (let i = 0; i < keys.count(); i++) {
      const k = keys.objectAtIndex_(i);
      const v = String(d.objectForKey_(k));
      if (/primaryUsagePage:0x7\b/.test(v) && /primaryUsage:0x6\b/.test(v)) keyboard = k;
      if (/primaryUsagePage:0x1\b/.test(v) && /primaryUsage:0x6\b/.test(v) && !generic) generic = k;
    }
    if (keyboard) return uint64(keyboard.toString());
    if (generic) return uint64(generic.toString());
  } catch (e) {}
  // No physical keyboard is paired: the accessibility senders are what the system
  // accepts for synthesized key events.
  try {
    const d = ObjC.classes.BKHIDSystemInterface.sharedInstance().senderCache().senderIDToSenderInfo();
    const keys = d.allKeys();
    for (let i = 0; i < keys.count(); i++) {
      const k = keys.objectAtIndex_(i);
      if (/BKHIDAccessibilitySender/.test(String(d.objectForKey_(k)))) return uint64(k.toString());
    }
  } catch (e) {}
  return STATE.sender || discoverSender();
}

function postKey(usage, down) {
  const h = ensureHid();
  if (!KB.sender) KB.sender = discoverKeyboardSender();
  const create = new NativeFunction(findExp('IOHIDEventCreateKeyboardEvent'), 'pointer',
    ['pointer', 'uint64', 'uint32', 'uint32', 'uint8', 'uint32']);
  const event = create(ptr(0), absTime(), 0x07, usage, down ? 1 : 0, 0);
  if (event.isNull()) throw new Error('no keyboard event');
  h.SetSender(event, KB.sender);
  inject(event);
  h.Rel(event);
}

rpc.exports = {
  key: function (usage, down, sender) {
    if (sender !== undefined && sender !== null && String(sender) !== '0') { KB.forced = String(sender); KB.sender = null; }
    postKey(usage, down ? 1 : 0);
    return 'ok';
  },
  senders: function () {
    const out = [];
    try {
      const d = ObjC.classes.BKHIDSystemInterface.sharedInstance().senderCache().senderIDToSenderInfo();
      const keys = d.allKeys();
      for (let i = 0; i < keys.count() && i < 60; i++) {
        const k = keys.objectAtIndex_(i);
        out.push(String(k) + ' => ' + String(d.objectForKey_(k)).slice(0, 120));
      }
    } catch (e) { out.push('error ' + e); }
    return out.join(' | ');
  },
  kbinfo: function () {
    const info = { hasCreate: !!findExp('IOHIDEventCreateKeyboardEvent'), created: false, err: '', sender: '' };
    try { info.sender = String(KB.sender || discoverKeyboardSender()); } catch (e) { info.err = 'sender ' + e; }
    try {
      const h = ensureHid();
      const create = new NativeFunction(findExp('IOHIDEventCreateKeyboardEvent'), 'pointer',
        ['pointer', 'uint64', 'uint32', 'uint32', 'uint8', 'uint32']);
      const event = create(ptr(0), absTime(), 0x07, 0x04, 1, 0);
      info.created = !event.isNull();
      if (info.created) h.Rel(event);
    } catch (e) { info.err += ' create ' + e; }
    return info;
  },
  probe: function () {
    return { proc: Process.name, sender: String(STATE.sender || discoverSender()), bkhid: (function () {
      try { const i = ObjC.classes.BKHIDSystemInterface.sharedInstance(); return !!(i && i['- injectHIDEvent:']); } catch (e) { return String(e); }
    })() };
  },
  down: function (x, y) { post(3, 1, 1, x, y); STATE.held = true; return 'ok'; },
  move: function (x, y) { if (!STATE.held) { post(3, 1, 1, x, y); STATE.held = true; } post(4, 1, 1, x, y); return 'ok'; },
  up: function (x, y) { post(2, 0, 0, x, y); STATE.held = false; return 'ok'; },
  tap: function (x, y) { post(3, 1, 1, x, y); Thread.sleep(0.04); post(2, 0, 0, x, y); STATE.held = false; return 'ok'; },
  swipe: function (x1, y1, x2, y2, ms) {
    const n = Math.max(2, Math.min(60, Math.round((ms || 300) / 16)));
    post(3, 1, 1, x1, y1); STATE.held = true;
    for (let i = 1; i <= n; i++) { Thread.sleep(0.016); const k = i / n; post(4, 1, 1, x1 + (x2 - x1) * k, y1 + (y2 - y1) * k); }
    post(2, 0, 0, x2, y2); STATE.held = false; return 'ok';
  },
  home: function () { return this.swipe(0.5, 0.995, 0.5, 0.55, 260); },
  appswitcher: function () {
    post(3, 1, 1, 0.5, 0.995); STATE.held = true;
    for (let i = 1; i <= 24; i++) { Thread.sleep(0.016); post(4, 1, 1, 0.5, 0.995 - 0.32 * i / 24); }
    Thread.sleep(0.15);
    post(2, 0, 0, 0.5, 0.675); STATE.held = false; return 'ok';
  }
};

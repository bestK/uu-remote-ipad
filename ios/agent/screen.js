'use strict';
/* SpringBoard screen capture agent. All UIKit work is scheduled on the main queue. */
function findExp(n) {
  try { return Module.getGlobalExportByName(n); } catch (e) {}
  const mods = ['/System/Library/Frameworks/UIKit.framework/UIKit',
                '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
                '/System/Library/Frameworks/ImageIO.framework/ImageIO',
                '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'];
  for (const p of mods) { try { return Module.load(p).getExportByName(n); } catch (e) {} }
  return null;
}
const FRAME_PATH = '/var/mobile/Library/Caches/uu-frame.jpg';
const uiCg = new NativeFunction(findExp('UICreateCGImageFromIOSurface'), 'pointer', ['pointer']);
const CFStr = new NativeFunction(findExp('CFStringCreateWithCString'), 'pointer', ['pointer', 'pointer', 'uint32']);
const destCreate = new NativeFunction(findExp('CGImageDestinationCreateWithData'), 'pointer', ['pointer', 'pointer', 'long', 'pointer']);
const destAdd = new NativeFunction(findExp('CGImageDestinationAddImage'), 'void', ['pointer', 'pointer', 'pointer']);
const destFin = new NativeFunction(findExp('CGImageDestinationFinalize'), 'bool', ['pointer']);
const CGRelease = new NativeFunction(findExp('CGImageRelease'), 'void', ['pointer']);
const CFRelease = new NativeFunction(findExp('CFRelease'), 'void', ['pointer']);
const uti = CFStr(ptr(0), Memory.allocUtf8String('public.jpeg'), 0x08000100);
const qKey = CFStr(ptr(0), Memory.allocUtf8String('kCGImageDestinationLossyCompressionQuality'), 0x08000100);

function onMain(fn, ms) {
  const box = { done: false, val: null, err: null };
  ObjC.schedule(ObjC.mainQueue, function () {
    // Frida's main-queue blocks have no autorelease pool; without one every
    // NSData/NSDictionary/NSString created here leaks (~0.5 MB per frame).
    let pool = null;
    try { pool = ObjC.classes.NSAutoreleasePool.alloc().init(); } catch (e) {}
    try { box.val = fn(); } catch (e) { box.err = String(e); }
    try { if (pool) pool.drain(); } catch (e) {}
    box.done = true;
  });
  const end = Date.now() + (ms || 2000);
  while (!box.done && Date.now() < end) Thread.sleep(0.004);
  if (!box.done) throw new Error('main timeout');
  if (box.err) throw new Error(box.err);
  return box.val;
}

// Streaming counts as user attention: push auto-lock back while frames are being taken. A periodic
// reset (not a disable assertion) cannot outlive the host if it dies mid-session.
let lastIdleReset = 0;
function holdAwake() {
  if (Date.now() - lastIdleReset < 5000) return;
  lastIdleReset = Date.now();
  try { ObjC.classes.SBIdleTimerGlobalCoordinator.sharedInstance().resetIdleTimer(); } catch (e) {}
}

function capture(q) {
  return onMain(function () {
    // The lock screen is captured like any other screen so the viewer can enter the passcode.
    // Waking a blanked panel is the host's job (ios_platform::wake_display).
    holdAwake();
    const surf = ObjC.classes.UIWindow.createScreenIOSurface();
    if (!surf || surf.isNull()) throw new Error('no surface');
    const cg = uiCg(surf);
    if (cg.isNull()) { CFRelease(surf); throw new Error('no cgimage'); }
    const md = ObjC.classes.NSMutableData.data();
    const opts = ObjC.classes.NSMutableDictionary.dictionary();
    opts.setObject_forKey_(ObjC.classes.NSNumber.numberWithDouble_(q || 0.55), qKey);
    const dest = destCreate(md.handle, uti, 1, ptr(0));
    if (dest.isNull()) { CGRelease(cg); CFRelease(surf); throw new Error('no jpeg destination'); }
    destAdd(dest, cg, opts.handle);
    destFin(dest);
    // The destination retains the CGImage and through it the ~22 MB screen IOSurface; leaking it
    // exhausted SpringBoard within ~20 s of streaming (createScreenIOSurface then returns nil).
    CFRelease(dest);
    const n = parseInt(String(md.length()), 10);
    const buf = md.bytes().readByteArray(n);
    CGRelease(cg);
    CFRelease(surf);
    return buf;
  }, 3000);
}


rpc.exports = {
  // Frames go through a file, not send(): a 0.5 MB frida payload every frame exhausts
  // SpringBoard's memory within a minute. The host (root) reads the real path.
  capture: function (q) {
    const buf = capture(q);
    const file = new File(FRAME_PATH, 'wb');
    file.write(buf);
    file.flush();
    file.close();
    return buf.byteLength;
  },
  // Cycles to the next input source: the job of the Globe key on a hardware keyboard. Walks the
  // enabled sources in their own order (skipping the emoji keyboard, which a remote typist never
  // wants) and returns the new identifier, a locale, not user data.
  nextinputmode: function () {
    return onMain(function () {
      const m = ObjC.classes.UIKeyboardInputModeController.sharedInputModeController();
      const current = String(m.currentInputMode().identifier());
      let ids = [];
      try {
        const list = m.enabledInputModeIdentifiers();
        for (let i = 0; i < list.count(); i++) ids.push(String(list.objectAtIndex_(i)));
      } catch (e) {}
      // One entry per language: the same language can be installed twice (Pinyin and Pinyin10).
      const seen = {};
      ids = ids.filter(function (id) {
        if (id.indexOf('emoji') === 0) return false;
        const language = id.split('@')[0];
        if (seen[language]) return false;
        seen[language] = true;
        return true;
      });
      if (ids.length < 2) throw new Error('only one input source');
      const at = ids.indexOf(current);
      const next = ids[(at + 1) % ids.length];
      const modes = m.inputModesFromIdentifiers_(ObjC.classes.NSArray.arrayWithObject_(next));
      const target = modes.count() ? modes.objectAtIndex_(0) : null;
      if (!target) throw new Error('input source not found');
      m.setCurrentInputMode_(target);
      try { m.updateCurrentInputMode_(target); } catch (e) {}
      return next;
    });
  },
  wake: function () {
    return onMain(function () {
      // turnOnScreenFully alone no longer lights the panel on iPadOS 16+.
      try { ObjC.classes.SpringBoard.sharedApplication().resetIdleTimerAndUndim(); } catch (e) {}
      const b = ObjC.classes.SBBacklightController.sharedInstance();
      try { b.turnOnScreenFullyWithBacklightSource_(0); } catch (e) {}
      return String(b.screenIsOn());
    });
  },
  lock: function () {
    return onMain(function () {
      const b = ObjC.classes.SBBacklightController.sharedInstance();
      if (b['- setBacklightState:source:animated:completion:']) b.setBacklightState_source_animated_completion_(0, 0, true, ptr(0));
      return 'ok';
    });
  },
  screenon: function () {
    return onMain(function () {
      return String(ObjC.classes.SBBacklightController.sharedInstance().screenIsOn());
    });
  },
  locked: function () {
    return onMain(function () {
      try { return String(ObjC.classes.SBLockScreenManager.sharedInstance().isUILocked()); } catch (e) { return 'false'; }
    });
  },
  unlock: function (passcode) {
    return onMain(function () {
      const l = ObjC.classes.SBLockScreenManager.sharedInstance();
      if (!l['- attemptUnlockWithPasscode:finishUIUnlock:completion:']) throw new Error('unlock unsupported');
      l.attemptUnlockWithPasscode_finishUIUnlock_completion_(String(passcode), true, ptr(0));
      return 'ok';
    });
  },
  info: function () {
    return onMain(function () {
      const s = ObjC.classes.UIScreen.mainScreen();
      const b = s.bounds();
      const sz = b[1] || b.size;
      const w = sz[0] !== undefined ? sz[0] : sz.width;
      const h = sz[1] !== undefined ? sz[1] : sz.height;
      return { width: w, height: h, scale: s.nativeScale() };
    });
  }
};

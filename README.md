# tTimers 0.25: Linux/Proton fix for Phoenix

A modified copy of [tTimers](https://github.com/ThornyFFXI/tTimers) by Thorny,
version 0.25 as installed by the Phoenix launcher. Two files change. Both are
display and input fixes; no tracking, timing, or packet logic was changed.

Review the changes in one place: the first commit is the unmodified addon,
the second commit is the whole diff.

## Why

On Linux (Phoenix launcher, GE-Proton11-5, DXVK), loading tTimers kills the
game. The window opens but never draws. The main thread dies with a stack
overflow (`warn:seh:dispatch_exception stack overflow` in the Proton log)
right after tTimers loads `gdifonts/gdifonttexture.dll`, its GDI text
rendering library. With every other default addon the game runs fine.

The known Wine workaround from
[tTimers issue #19](https://github.com/ThornyFFXI/tTimers/issues/19),
installing native gdiplus with winetricks, does not help here: native
gdiplus was already installed in the prefix (`"*gdiplus"="native"`) when
the crash was reproduced. That issue was about garbled text; this one is a
crash.

## Changes

### 1. `gdifonts/include.lua`: draw text without the DLL

The original file loads `gdifonttexture.dll` through LuaJIT FFI and uses it to
render text into textures. The replacement keeps the same API (the functions
tTimers calls are unchanged) but draws with Ashita's built-in font objects
(`AshitaCore:GetFontManager()`) instead. The DLL is never loaded.

- Labels, countdowns and tooltips use Ashita font objects with the
  `ManualRender` draw flag, so they draw only when tTimers asks, as before.
- The reposition drag handle is a small "MOVE" font object on a filled
  background.
- Objects tTimers stops drawing (expired timers) are hidden each frame and
  freed after a few seconds.

Cosmetic differences: rounded corners and gradients are not drawn, and font
sizes differ slightly from the GDI renderer.

### 2. `timergroup.lua`: mouse position scaling

Mouse events arrive in window coordinates, but timers are drawn in backbuffer
coordinates. When the game renders at a higher resolution than its window
(here 3840x2160 in a 2560x1440 window), clicks and hover missed by that ratio,
so the reposition handles could not be grabbed and tooltips showed for the
wrong timer. `HandleMouse` now scales the mouse position by
backbuffer size / window client size before hit testing. When the sizes match,
the scale is 1 and behavior is unchanged.

## Not changed

Timer tracking (buffs, debuffs, recasts, custom timers), durations, packet
handling, commands, and settings are all as distributed. The original's
outgoing requests in `durations/data.lua` (packets 0x61 and 0xC0) are
untouched, and the changes add no new packets or commands.

## License

tTimers and gdifonts are MIT licensed by ThornyFFXI; see `ttimers/LICENSE`
and `ttimers/gdifonts/LICENSE`. These changes are offered under the same
license.

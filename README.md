# tTimers 0.25: Linux/Proton fix for Phoenix

A modified copy of [tTimers](https://github.com/ThornyFFXI/tTimers) by Thorny,
version 0.25 as installed by the Phoenix launcher. Most changes are display
and input fixes; one makes the debuff tracker see AoE targets. No timing
logic was changed and no packets are sent.

Review the changes in one place: the first commit is the unmodified addon,
so `git diff 24fe218` shows everything changed since.

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
tTimers calls are unchanged) but draws with ImGui instead. The DLL is never
loaded.

- Labels, countdowns and tooltips are added to ImGui's foreground draw list
  with Ashita's own ImGui font, on the frames tTimers renders them. Nothing
  is kept between frames, so there is nothing to free or hide. The
  foreground list is drawn last, so text sits on top of the bars.
- Outlines are the text drawn one pixel around itself in the outline color.
  Bold is the text drawn again one pixel to the right.
- The reposition drag handle is a filled rounded box.

Earlier versions used Ashita font objects. Drawing them by hand with the
`ManualRender` flag crashed the game while zoning (a call into a freed
Direct3D object in DXVK's `d3d8.dll`), and letting Ashita draw them put the
text under the bars. Loading a font file with `AddFontFromFileTTF` while the
game ran also crashed DXVK, so the skin's font family is ignored.

Cosmetic differences: gradients are not drawn, every skin uses the same
font, and text is wider than the GDI renderer's (see change 4).

### 2. `timergroup.lua`: mouse position scaling

Mouse events arrive in window coordinates, but timers are drawn in backbuffer
coordinates. When the game renders at a higher resolution than its window
(here 3840x2160 in a 2560x1440 window), clicks and hover missed by that ratio,
so the reposition handles could not be grabbed and tooltips showed for the
wrong timer. `HandleMouse` now scales the mouse position by
backbuffer size / window client size before hit testing. When the sizes match,
the scale is 1 and behavior is unchanged.

### 3. `trackers/debuff.lua`: debuffs on AoE targets

The server reports an AoE spell's main target with the long message ("<caster>
casts <spell>. <target> is <status>.", 236) and every other target with a
short one ("<target> is <status>.", 277). The tracker only knew the long
forms, so Horde Lullaby, Sleepga and the like timed the main target only.
The short forms 277, 278 (receives the effect) and 264 (takes damage, e.g.
Diaga) now count too.

### 4. `resources/renderers/classic.lua`: labels stop before the timer

The classic renderer places the label and the countdown at fixed spots and
never shortens the label. With the wider ImGui font, long debuff labels such
as `Foe Requiem IV[Wight+1]` ran under the countdown. The countdown is now
measured first, and the label is cut to fit the space left of it with a
16 pixel gap (times the panel scale), ending in `..`. The fitted text is
cached until the label or the space changes.

## Not changed

Buff, recast and custom timer tracking, durations, packet
handling, commands, and settings are all as distributed. The original's
outgoing requests in `durations/data.lua` (packets 0x61 and 0xC0) are
untouched, and the changes add no new packets or commands.

## License

tTimers and gdifonts are MIT licensed by ThornyFFXI; see `ttimers/LICENSE`
and `ttimers/gdifonts/LICENSE`. These changes are offered under the same
license.

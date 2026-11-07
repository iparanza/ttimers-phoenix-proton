--[[
Replacement for Thorny's gdifonts include.lua (original saved as
include.lua.orig). The original loads gdifonttexture.dll, which kills the
game with a stack overflow under Proton. This version keeps the same API but
draws with ImGui, so no DLL is loaded.

gdifonts draws immediately: an object shows only on frames where render() is
called. ImGui works the same way, so render() adds the text to ImGui's
foreground draw list and nothing is kept between frames. The foreground list
is drawn last, on top of tTimers' bars.

Earlier versions used Ashita font objects. Drawing them by hand with the
ManualRender flag crashed the game while zoning (a call into a freed Direct3D
object inside DXVK's d3d8.dll). Letting Ashita draw them put the text under
the bars. Drawing an Ashita primitive by hand also crashed.
--]]

local imgui = require('imgui');

local OUTLINE_STEPS = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1,  0 },            { 1,  0 },
    { -1,  1 }, { 0,  1 }, { 1,  1 },
};
local BG_PAD     = 3;    -- pixels of background around tooltip text
local SIZE_SCALE = 4 / 3; -- skin heights are points; ImGui sizes are pixels

-- All text uses Ashita's own ImGui font. Adding font files with
-- AddFontFromFileTTF while the game was running crashed DXVK (a read of
-- freed memory on its dxvk-cs thread), likely when the font texture was
-- rebuilt.

-- gdifonts colors are 0xAARRGGBB. ImGui packs colors as 0xAABBGGRR. Built
-- with arithmetic, not bit ops, so the result stays a positive number.
local function to_imgui_color(argb)
    local a = math.floor(argb / 0x1000000) % 0x100;
    local r = math.floor(argb / 0x10000) % 0x100;
    local g = math.floor(argb / 0x100) % 0x100;
    local b = argb % 0x100;
    return a * 0x1000000 + b * 0x10000 + g * 0x100 + r;
end

-- Width and height of text drawn at the given pixel size.
local function text_size(text, size)
    local w, h = imgui.CalcTextSize(text);
    local ratio = size / imgui.GetFontSize();
    return w * ratio, h * ratio;
end

-- Shared shim behavior. Setters store state; render() draws it.
local base = {};
base.__index = base;

function base:set_position_x(x) self.state.x = x; end
function base:set_position_y(y) self.state.y = y; end
function base:set_visible(v) self.state.visible = v; end
function base:set_z_order(z) end
function base:get_texture() return nil; end
function base:release() end

-- Font objects.
local font = setmetatable({}, { __index = base });
font.__index = font;

local function new_font(settings)
    settings = settings or {};
    local bg = settings.background or {};
    return setmetatable({
        state = {
            height        = settings.font_height or 10,
            color         = settings.font_color or 0xFFFFFFFF,
            outline       = settings.outline_color or 0xFF000000,
            outlineWidth  = settings.outline_width or 0,
            alignment     = settings.font_alignment or 0,
            flags         = settings.font_flags or 0,
            text          = '',
            x             = settings.position_x or 0,
            y             = settings.position_y or 0,
            visible       = settings.visible ~= false,
            bgVisible     = bg.visible == true,
            bgColor       = bg.fill_color or 0xFF000000,
            bgRounding    = bg.corner_rounding or 0,
        },
    }, font);
end

function font:set_font_height(h) self.state.height = h; end
function font:set_font_family(f) end
function font:set_font_color(c) self.state.color = c; end
function font:set_font_flags(f) self.state.flags = f; end
function font:set_font_alignment(a) self.state.alignment = a; end
function font:set_outline_color(c) self.state.outline = c; end
function font:set_outline_width(w) self.state.outlineWidth = w; end
function font:set_text(t) self.state.text = t or ''; end
function font:set_opacity(o) end
function font:set_box_width(w) end
function font:set_box_height(h) end
function font:set_bg_overlap(o) end
function font:set_gradient_color(c) end
function font:set_gradient_style(s) end
function font:get_background() return {}; end
function font:set_background(settings)
    settings = settings or {};
    self.state.bgVisible = settings.visible == true;
    self.state.bgColor = settings.fill_color or self.state.bgColor;
end

local function text_px(s) return math.floor(s.height * SIZE_SCALE + 0.5); end

function font:get_text_size()
    local s = self.state;
    return text_size(s.text, text_px(s));
end

function font:render(sprite)
    local s = self.state;
    if (not s.visible) or (s.text == '') then
        return;
    end
    local list = imgui.GetForegroundDrawList();
    if (list == nil) then
        return;
    end

    local face = imgui.GetFont();
    local size = text_px(s);
    local w, h = text_size(s.text, size);

    -- Alignment 1 centers the text on x, 2 puts its right edge at x.
    local x = s.x;
    if (s.alignment == 1) then
        x = x - (w / 2);
    elseif (s.alignment == 2) then
        x = x - w;
    end
    local y = s.y;

    if (s.bgVisible) then
        list:AddRectFilled({ x - BG_PAD, y - BG_PAD }, { x + w + BG_PAD, y + h + BG_PAD },
            to_imgui_color(s.bgColor), s.bgRounding);
    end

    -- ImGui text has no outline, so draw the text in the outline color one
    -- pixel around the real position first. Wider outlines smeared small
    -- text, so any outline width draws as one pixel.
    if (s.outlineWidth > 0) then
        local oc = to_imgui_color(s.outline);
        for _, step in ipairs(OUTLINE_STEPS) do
            list:AddText(face, size, { x + step[1], y + step[2] }, oc, s.text);
        end
    end

    local color = to_imgui_color(s.color);
    list:AddText(face, size, { x, y }, color, s.text);
    -- Flag 0x01 is bold: draw it again one pixel to the right.
    if (bit.band(s.flags, 0x01) ~= 0) then
        list:AddText(face, size, { x + 1, y }, color, s.text);
    end
end

-- Rect objects (the drag handle), drawn as a filled rounded box.
local rect = setmetatable({}, { __index = base });
rect.__index = rect;

local function new_rect(settings)
    settings = settings or {};
    return setmetatable({
        state = {
            width        = settings.width or 0,
            height       = settings.height or 0,
            fill         = settings.fill_color or 0xFFFFFFFF,
            outline      = settings.outline_color or 0xFF000000,
            outlineWidth = settings.outline_width or 0,
            rounding     = settings.corner_rounding or 0,
            x            = settings.position_x or 0,
            y            = settings.position_y or 0,
            visible      = settings.visible ~= false,
        },
    }, rect);
end

function rect:set_width(w) self.state.width = w; end
function rect:set_height(h) self.state.height = h; end
function rect:set_fill_color(c) self.state.fill = c; end
function rect:set_outline_color(c) self.state.outline = c; end
function rect:set_outline_width(w) self.state.outlineWidth = w; end
function rect:set_corner_rounding(r) self.state.rounding = r; end
function rect:set_gradient_color(c) end
function rect:set_gradient_style(s) end

function rect:render(sprite)
    local s = self.state;
    if (not s.visible) or (s.width <= 0) or (s.height <= 0) then
        return;
    end
    local list = imgui.GetForegroundDrawList();
    if (list == nil) then
        return;
    end
    local a = { s.x, s.y };
    local b = { s.x + s.width, s.y + s.height };
    list:AddRectFilled(a, b, to_imgui_color(s.fill), s.rounding);
    if (s.outlineWidth > 0) then
        list:AddRect(a, b, to_imgui_color(s.outline), s.rounding, 0, s.outlineWidth);
    end
end

local exports = {};

function exports:create_object(settings, manual) return new_font(settings); end
function exports:create_rect(settings, manual) return new_rect(settings); end
function exports:destroy_object(object) end
function exports:destroy_interface() end
function exports:get_font_available(fontName) return true; end
function exports:disable_texture_dump() end
function exports:dump_frame(path) end
function exports:enable_texture_dump(path) end
function exports:render() end
function exports:set_auto_render(enabled) end

return exports;

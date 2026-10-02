--[[
Replacement for Thorny's gdifonts include.lua (original saved as
include.lua.orig). The original loads gdifonttexture.dll, which kills the
game with a stack overflow under Proton. This version keeps the same API but
draws through Ashita's own font and primitive objects, so no DLL is loaded.

gdifonts draws immediately: an object shows only on frames where render() is
called. Ashita objects are retained, so each one is drawn with the
ManualRender flag, and a per-frame sweep hides any object that render() was
not called on. Objects unused for a few seconds are deleted and rebuilt on
the next render().
--]]

local MANUAL_RENDER = 0x20; -- FontDrawFlags.ManualRender
local OUTLINED      = 0x10; -- FontDrawFlags.Outlined
local RIGHT         = 0x08; -- FontDrawFlags.RightJustified
local CENTER_X      = 0x02; -- FontDrawFlags.CenterX
local DELETE_AFTER  = 3;    -- seconds unused before the Ashita object is freed

local aliasCount = 0;
local frame      = 0;
local active     = {}; -- shim objects that currently own an Ashita object

local function next_alias(kind)
    aliasCount = aliasCount + 1;
    return string.format('__ttimers_%s_%d', kind, aliasCount);
end

-- Shared shim behavior. Setters store state; render() pushes changed state to
-- the Ashita object and draws it.
local base = {};
base.__index = base;

function base:set_position_x(x) self.state.x = x; end
function base:set_position_y(y) self.state.y = y; end
function base:set_visible(v) self.state.visible = v; end
function base:set_z_order(z) end
function base:get_texture() return nil; end

function base:touch()
    if (self.obj == nil) then
        self.obj = self:create();
        self.applied = {};
        active[self] = true;
    end
    self.lastFrame = frame;
    self.lastClock = os.clock();
end

-- Calls setter(obj, value) only when value differs from what was last applied.
function base:apply(key, setter, value)
    if (self.applied[key] ~= value) then
        self.applied[key] = value;
        setter(self.obj, value);
    end
end

function base:release()
    if (self.obj ~= nil) then
        self:delete();
        self.obj = nil;
        active[self] = nil;
    end
end

-- Font objects.
local font = setmetatable({}, { __index = base });
font.__index = font;

local function new_font(settings)
    settings = settings or {};
    local bg = settings.background or {};
    return setmetatable({
        alias = next_alias('font'),
        state = {
            family        = settings.font_family or 'Arial',
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
        },
    }, font);
end

function font:create()
    local obj = AshitaCore:GetFontManager():Create(self.alias);
    obj:SetLocked(true);
    obj:SetCanFocus(false);
    obj:SetAutoResize(true);
    return obj;
end

function font:delete()
    AshitaCore:GetFontManager():Delete(self.alias);
end

function font:set_font_height(h) self.state.height = h; end
function font:set_font_family(f) self.state.family = f; end
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

-- Not used by the classic renderer; size is unknown until the object exists.
function font:get_text_size()
    return 0, 0;
end

local function set_bg_visible(obj, v) obj:GetBackground():SetVisible(v); end
local function set_bg_color(obj, c) obj:GetBackground():SetColor(c); end

function font:render(sprite)
    local s = self.state;
    if (not s.visible) or (s.text == '') then
        return;
    end
    self:touch();

    local drawFlags = MANUAL_RENDER;
    if (s.outlineWidth > 0) then
        drawFlags = bit.bor(drawFlags, OUTLINED);
    end
    if (s.alignment == 1) then
        drawFlags = bit.bor(drawFlags, CENTER_X);
    elseif (s.alignment == 2) then
        drawFlags = bit.bor(drawFlags, RIGHT);
    end

    local obj = self.obj;
    self:apply('family', obj.SetFontFamily, s.family);
    self:apply('height', obj.SetFontHeight, math.floor(s.height));
    self:apply('bold', obj.SetBold, bit.band(s.flags, 0x01) ~= 0);
    self:apply('italic', obj.SetItalic, bit.band(s.flags, 0x02) ~= 0);
    self:apply('color', obj.SetColor, s.color);
    self:apply('outline', obj.SetColorOutline, s.outline);
    self:apply('drawFlags', obj.SetDrawFlags, drawFlags);
    self:apply('right', obj.SetRightJustified, s.alignment == 2);
    self:apply('text', obj.SetText, s.text);
    self:apply('x', obj.SetPositionX, s.x);
    self:apply('y', obj.SetPositionY, s.y);
    self:apply('visible', obj.SetVisible, true);
    self:apply('bgVisible', set_bg_visible, s.bgVisible);
    self:apply('bgColor', set_bg_color, s.bgColor);

    obj:Render();
end

-- Rect objects (the drag handle). Drawing an Ashita primitive manually crashed
-- the game (access violation), so the handle is a font object showing "MOVE"
-- on a filled background. It is roughly, not exactly, width x height; tTimers
-- computes the clickable area itself.
local rect = setmetatable({}, { __index = base });
rect.__index = rect;

local function new_rect(settings)
    settings = settings or {};
    local r = setmetatable({
        state = {
            width   = settings.width or 0,
            height  = settings.height or 0,
            fill    = settings.fill_color or 0xFFFFFFFF,
            x       = settings.position_x or 0,
            y       = settings.position_y or 0,
            visible = settings.visible ~= false,
        },
    }, rect);
    r.label = new_font({
        font_family   = 'Arial',
        font_flags    = 0x01,
        outline_width = 1,
        background    = { visible = true, fill_color = r.state.fill },
    });
    return r;
end

function rect:set_width(w) self.state.width = w; end
function rect:set_height(h) self.state.height = h; end
function rect:set_fill_color(c) self.state.fill = c; end
function rect:set_outline_color(c) end
function rect:set_outline_width(w) end
function rect:set_corner_rounding(r) end
function rect:set_gradient_color(c) end
function rect:set_gradient_style(s) end
function rect:release() self.label:release(); end

function rect:render(sprite)
    local s = self.state;
    if (not s.visible) or (s.width <= 0) or (s.height <= 0) then
        return;
    end
    local label = self.label;
    label:set_text('MOVE');
    label:set_font_height(math.max(6, s.width / 4.5));
    label:set_background({ visible = true, fill_color = s.fill });
    label:set_position_x(s.x);
    label:set_position_y(s.y);
    label:render(sprite);
end

-- Hide objects that were not rendered since the last sweep, and free the ones
-- unused for a while. Works whether this runs before or after tTimers' own
-- d3d_present handler in a frame.
ashita.events.register('d3d_present', '__ttimers_gdi_sweep', function ()
    local now = os.clock();
    for obj in pairs(active) do
        if (now - obj.lastClock > DELETE_AFTER) then
            obj:release();
        elseif (obj.lastFrame < frame) and (obj.applied.visible ~= false) then
            obj.applied.visible = false;
            obj.obj:SetVisible(false);
        end
    end
    frame = frame + 1;
end);

local exports = {};

function exports:create_object(settings, manual) return new_font(settings); end
function exports:create_rect(settings, manual) return new_rect(settings); end
function exports:destroy_object(object) if object then object:release(); end end
function exports:destroy_interface()
    for obj in pairs(active) do
        obj:release();
    end
end
function exports:get_font_available(fontName) return true; end
function exports:disable_texture_dump() end
function exports:dump_frame(path) end
function exports:enable_texture_dump(path) end
function exports:render() end
function exports:set_auto_render(enabled) end

return exports;

pub const gtk = @import("gtk4");
const gdk = @import("gdk4");
const cairo = @import("cairo1");

/// Built-in vector artwork: independent of installed icon themes and SVG loaders.
pub fn mouseIcon() *gtk.DrawingArea {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(48);
    area.setContentHeight(48);
    area.as(gtk.Widget).setHalign(.center);
    area.as(gtk.Widget).addCssClass("eyebrow");
    named(area, "PRO X2 SUPERSTRIKE mouse");
    area.setDrawFunc(drawMouse, null, null);
    return area;
}

fn drawMouse(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    var color: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&color);
    cr.save();
    defer cr.restore();
    const size: f64 = @floatFromInt(@min(width, height));
    cr.translate((@as(f64, @floatFromInt(width)) - size) / 2, (@as(f64, @floatFromInt(height)) - size) / 2);
    cr.scale(size / 48, size / 48);
    cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, color.f_alpha);
    cr.setLineWidth(2);
    cr.setLineCap(.round);
    cr.moveTo(10, 20);
    cr.curveTo(10, 9, 15, 4, 24, 4);
    cr.curveTo(33, 4, 38, 9, 38, 20);
    cr.lineTo(38, 29);
    cr.curveTo(38, 39, 33, 44, 24, 44);
    cr.curveTo(15, 44, 10, 39, 10, 29);
    cr.closePath();
    cr.stroke();
    cr.moveTo(24, 4);
    cr.lineTo(24, 11);
    cr.moveTo(24, 19);
    cr.lineTo(24, 24);
    cr.moveTo(10, 24);
    cr.lineTo(38, 24);
    cr.stroke();
    cr.setLineWidth(4);
    cr.moveTo(24, 13);
    cr.lineTo(24, 17);
    cr.stroke();
}

pub fn box(orientation: gtk.Orientation, spacing: c_int) *gtk.Box {
    return gtk.Box.new(orientation, spacing);
}
pub fn label(text: [:0]const u8, class: ?[:0]const u8) *gtk.Label {
    const value = gtk.Label.new(text);
    value.setXalign(0);
    value.setWrap(1);
    value.setWrapMode(.word_char);
    if (class) |c| value.as(gtk.Widget).addCssClass(c);
    return value;
}
pub fn button(text: [:0]const u8, class: ?[:0]const u8) *gtk.Button {
    const value = gtk.Button.newWithLabel(text);
    if (class) |c| value.as(gtk.Widget).addCssClass(c);
    return value;
}
pub fn margins(widget: *gtk.Widget, amount: c_int) void {
    widget.setMarginStart(amount);
    widget.setMarginEnd(amount);
    widget.setMarginTop(amount);
    widget.setMarginBottom(amount);
}
pub fn append(parent: *gtk.Box, child: anytype) void {
    parent.append(child.as(gtk.Widget));
}
pub fn clear(parent: *gtk.Box) void {
    while (parent.as(gtk.Widget).getFirstChild()) |child| parent.remove(child);
}
pub fn expand(widget: anytype) void {
    widget.as(gtk.Widget).setHexpand(1);
}
pub fn sensitive(widget: anytype, value: bool) void {
    widget.as(gtk.Widget).setSensitive(@intFromBool(value));
}
pub fn named(widget: anytype, text: [:0]const u8) void {
    widget.as(gtk.Widget).setTooltipText(text);
    widget.as(gtk.Accessible).updateProperty(.label, text.ptr, @as(c_int, -1));
}

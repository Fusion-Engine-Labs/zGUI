pub const types = @import("ui/core/types.zig");
pub const style = @import("ui/core/style.zig");
pub const theme = @import("ui/theme.zig");
pub const widgets = @import("ui/widgets/widgets.zig");
pub const events = @import("ui/platform/events.zig");

const ui_context = @import("ui/core/ui_context.zig");
const ui_events = @import("ui/core/events.zig");

pub const Ui = ui_context.Ui;
pub const BeginFrame = ui_context.BeginFrame;
pub const UiStats = ui_context.UiStats;
pub const InputCapture = ui_context.InputCapture;
pub const Interaction = ui_context.Interaction;
pub const Event = ui_events.Event;
pub const EventHandler = ui_events.EventHandler;
pub const Activation = ui_events.Activation;
pub const ActivationSource = ui_events.ActivationSource;
pub const NodeId = types.NodeId;
pub const TextureHandle = types.TextureHandle;
pub const Vec2 = types.Vec2;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const ColorPicker = widgets.ColorPicker;
pub const ColorPickerOptions = widgets.ColorPickerOptions;

test {
    // Re-exports are only analyzed when something names them, so reference the
    // whole surface here; without this a decl aliasing a missing symbol
    // compiles fine until a consumer first touches it.
    @import("std").testing.refAllDecls(@This());

    _ = @import("ui/core/types.zig");
    _ = @import("ui/core/tree.zig");
    _ = @import("ui/core/layout.zig");
    _ = @import("ui/core/input.zig");
    _ = @import("ui/core/ui_context.zig");
    _ = @import("ui/widgets/virtual_list.zig");
    _ = @import("ui/docking/dock_view.zig");
}

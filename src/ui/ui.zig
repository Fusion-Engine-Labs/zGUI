const types = @import("core/types.zig");
const style = @import("core/style.zig");
const dirty = @import("core/dirty.zig");
const node = @import("core/node.zig");
const tree = @import("core/tree.zig");
const app = @import("core/ui_context.zig");
const text = @import("core/text.zig");
pub const theme = @import("theme.zig");

const events = @import("core/events.zig");

const draw_data = @import("render/draw_data.zig");
const batcher = @import("render/batcher.zig");
const font_atlas = @import("render/font_atlas.zig");
const opengl_renderer = @import("render/opengl_renderer.zig");

const dock_manager = @import("docking/dock_manager.zig");
const dock_space = @import("docking/dock_space.zig");
const window = @import("windowing/window.zig");

pub const widgets = @import("widgets/widgets.zig");

pub const Vec2 = types.Vec2;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const NodeId = types.NodeId;
pub const WindowId = types.WindowId;
pub const DockNodeId = types.DockNodeId;
pub const TextureHandle = types.TextureHandle;
pub const invalid_node = types.invalid_node;
pub const invalid_window = types.invalid_window;

pub const Size = style.Size;
pub const LayoutDirection = style.LayoutDirection;
pub const Overflow = style.Overflow;
pub const Edges = style.Edges;
pub const CornerRadii = style.CornerRadii;
pub const Style = style.Style;
pub const Theme = theme.Theme;
pub const Palette = theme.Palette;
pub const Metrics = theme.Metrics;
pub const ColorRole = theme.ColorRole;
pub const RadiusRole = theme.RadiusRole;
pub const StyleOptions = theme.StyleOptions;
pub const TextOptions = theme.TextOptions;

pub const Ui = app.Ui;
pub const BeginFrame = app.BeginFrame;
pub const UiStats = app.UiStats;
pub const InputCapture = app.InputCapture;
pub const Interaction = app.Interaction;

pub const PlatformEvent = events.PlatformEvent;
pub const MouseButton = events.MouseButton;
pub const Key = events.Key;
pub const Clipboard = events.Clipboard;
pub const Event = events.Event;
pub const EventHandler = events.EventHandler;
pub const Activation = events.Activation;
pub const ActivationSource = events.ActivationSource;

pub const TextMetrics = text.TextMetrics;
pub const FontAtlas = font_atlas.FontAtlas;
pub const OpenGlRenderer = opengl_renderer.OpenGlRenderer;
pub const DockManager = dock_manager.DockManager;
pub const DockSpace = dock_space.DockSpace;
pub const DockSpaceOptions = dock_space.DockSpaceOptions;
pub const DockSpaceResult = dock_space.DockSpaceResult;
pub const DockWindowId = dock_space.DockWindowId;
pub const WindowFlags = window.WindowFlags;
pub const CursorKind = events.CursorKind;
pub const TextField = widgets.TextField;
pub const TextFieldOptions = widgets.TextFieldOptions;
pub const TextFieldResult = widgets.TextFieldResult;
pub const TextInputMode = widgets.TextInputMode;
pub const Checkbox = widgets.Checkbox;
pub const Slider = widgets.Slider;
pub const SliderOptions = widgets.SliderOptions;
pub const NumericField = widgets.NumericField;
pub const NumericOptions = widgets.NumericOptions;
pub const NumericResult = widgets.NumericResult;
pub const Collapsible = widgets.Collapsible;
pub const CollapsibleOptions = widgets.CollapsibleOptions;
pub const SelectionList = widgets.SelectionList;
pub const SelectionListOptions = widgets.SelectionListOptions;
pub const SelectionListSearchOptions = widgets.SelectionListSearchOptions;
pub const Modal = widgets.Modal;
pub const ColorPicker = widgets.ColorPicker;
pub const ColorPickerOptions = widgets.ColorPickerOptions;
pub const ColorPickerPanel = widgets.ColorPickerPanel;
pub const ColorPickerPanelOptions = widgets.ColorPickerPanelOptions;

const toolbar_mod = @import("toolbar.zig");

/// A tab bar is a horizontal panel — the same thing a toolbar is. The two names
/// exist for the reader, not for two behaviours.
pub const tabBar = toolbar_mod.toolbar;

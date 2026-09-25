//! Messages source decoding, fixture dispatch, and native macOS capabilities.

pub const MessagesDb = @import("adapter/MessagesDb.zig");
pub const body_parts = @import("adapter/body_parts.zig");
pub const contacts = @import("adapter/contacts.zig");
pub const decoder = @import("adapter/decoder.zig");
pub const enrichment_probe = @import("adapter/enrichment_probe.zig");
pub const fake = @import("adapter/fake.zig");
pub const link_preview = @import("adapter/link_preview.zig");
pub const macos = @import("adapter/macos.zig");
pub const plist = @import("adapter/plist.zig");
pub const reactions = @import("adapter/reactions.zig");

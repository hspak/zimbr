//! Defense in depth for a faulty or compromised relay. Keep these limits
//! independent of rendering and apply them before committing received records.
const std = @import("std");
const t = @import("../protocol/types.zig");
pub const max_record_bytes = 512 * 1024;
pub const max_section_items = 4096;
pub const max_expanded_bytes = 8 * 1024 * 1024;

pub fn message(value: t.Message) !void {
    if (value.text) |text| {
        if (text.len > t.max_body or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRecord;
    }
    if (value.id.len == 0 or value.id.len > 1024 or value.conversation_id.len == 0 or value.conversation_id.len > 1024) return error.InvalidRecord;
    if (value.attachments.len > max_section_items or (if (value.parts) |items| items.len else 0) > max_section_items or
        (if (value.link_previews) |items| items.len else 0) > max_section_items or (if (value.reactions) |items| items.len else 0) > max_section_items) return error.InvalidRecord;
}

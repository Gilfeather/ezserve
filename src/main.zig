const std = @import("std");
const args = @import("args.zig");
const server = @import("server.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const config = try args.parseArgs(allocator);

    // Use ultra-high-performance single-thread poller
    try server.ultraPollerMain(allocator, config);
}

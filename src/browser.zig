const std = @import("std");
const builtin = @import("builtin");

// Cross-platform browser opening
pub fn openBrowser(url: []const u8, allocator: std.mem.Allocator) !void {
    const command = switch (builtin.target.os.tag) {
        .macos => "open",
        .linux => "xdg-open", 
        .windows => "start",
        else => return error.UnsupportedPlatform,
    };
    
    const args = if (builtin.target.os.tag == .windows)
        [_][]const u8{ "cmd", "/c", "start", url }
    else
        [_][]const u8{ command, url };
    
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    // Don't wait for the browser to finish
    _ = child.spawn() catch |err| {
        std.log.warn("Failed to open browser: {}", .{err});
        return;
    };
    
    std.log.info("Browser opened: {s}", .{url});
}
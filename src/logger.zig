const std = @import("std");
const builtin = @import("builtin");

// Ultra-fast logging - NO std.log.info bottleneck!
pub fn logAccess(method: []const u8, path: []const u8, status: u16, content_length: usize, addr: std.net.Address, log_json: bool, _: std.mem.Allocator) !void {
    // PERFORMANCE MODE: Skip only non-JSON logging in release mode
    // JSON logging is always available when explicitly requested
    if (builtin.mode == .ReleaseFast and !log_json) {
        return; // Skip only standard logging in release mode
    }

    // Fast timestamp and IP formatting
    const timestamp = std.time.timestamp();

    // Ultra-fast IP formatting - avoid allocation for IPv4
    var ip_buf: [16]u8 = undefined;
    const client_ip = switch (addr.any.family) {
        std.posix.AF.INET => blk: {
            const ipv4 = addr.in;
            // Direct bit manipulation - fastest possible
            const a = @as(u8, @truncate((ipv4.sa.addr >> 0) & 0xff));
            const b = @as(u8, @truncate((ipv4.sa.addr >> 8) & 0xff));
            const c = @as(u8, @truncate((ipv4.sa.addr >> 16) & 0xff));
            const d = @as(u8, @truncate((ipv4.sa.addr >> 24) & 0xff));
            break :blk try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d });
        },
        else => "unknown",
    };

    if (log_json) {
        // Optimized JSON output for production use
        var log_buf: [512]u8 = undefined;
        const log_entry = try std.fmt.bufPrint(&log_buf, "{{\"timestamp\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"content_length\":{d},\"client_ip\":\"{s}\"}}", .{ timestamp, method, path, status, content_length, client_ip });
        // Use stderr for unbuffered output (production logs)
        const stderr = std.io.getStdErr().writer();
        stderr.print("{s}\n", .{log_entry}) catch {};
    } else {
        // Standard compact format (development only unless --log=json specified)
        const stderr = std.io.getStdErr().writer();
        stderr.print("{s} {s} {d} {d} {s}\n", .{ client_ip, method, status, content_length, path }) catch {};
    }
}

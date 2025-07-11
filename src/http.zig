const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const logger = @import("logger.zig");

pub const Config = lib.Config;
pub const ResponseInfo = lib.ResponseInfo;
pub const getMimeType = lib.getMimeType;

const FILE_READ_BUF_SIZE = 131072; // 128KB buffer for maximum throughput

// Handle individual HTTP request - ZERO-ALLOCATION parsing
pub fn handleRequest(reader: anytype, writer: anytype, addr: std.net.Address, config: Config, req_allocator: std.mem.Allocator) !bool {
    // Pre-allocated buffers - NO dynamic allocation!
    var req_line_buf: [8192]u8 = undefined;
    var header_buf: [4096]u8 = undefined;
    var req_line_len: usize = 0;
    var found_req_line = false;

    // --- Robust HTTP request line reading with retries ---
    var retry_count: u8 = 0;
    while (!found_req_line and retry_count < 20) {
        const n = reader.read(req_line_buf[req_line_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                std.time.sleep(10_000); // 10μs wait for data
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (req_line_len == 0) {
                try writer.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
                return false;
            }
            break; // EOF
        }
        req_line_len += n;

        // Check for newline (end of request line)
        if (std.mem.indexOfScalar(u8, req_line_buf[0..req_line_len], '\n')) |idx| {
            found_req_line = true;
            req_line_len = idx + 1;
            break;
        }

        if (req_line_len >= req_line_buf.len) break; // Buffer full
    }

    if (!found_req_line) {
        try writer.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        return false;
    }

    // Parse request line
    const req_line = req_line_buf[0..req_line_len];
    const clean_line = std.mem.trim(u8, req_line, " \r\n\t");
    var it = std.mem.splitScalar(u8, clean_line, ' ');
    const method = std.mem.trim(u8, it.next() orelse "", " \r\n\t");
    const path = std.mem.trim(u8, it.next() orelse "/", " \r\n\t");

    // --- Robust header reading with retries ---
    var header_len: usize = 0;
    var header_retry_count: u8 = 0;
    while (header_len < header_buf.len and header_retry_count < 10) {
        const n = reader.read(header_buf[header_len..]) catch |err| {
            if (err == error.WouldBlock) {
                header_retry_count += 1;
                std.time.sleep(10_000); // 10μs wait for data
                continue;
            }
            break; // Other errors, use what we have
        };
        if (n == 0) break; // EOF
        header_len += n;

        // Check for end of headers
        if (std.mem.indexOf(u8, header_buf[0..header_len], "\r\n\r\n") != null or
            std.mem.indexOf(u8, header_buf[0..header_len], "\n\n") != null)
        {
            break; // Complete headers received
        }
    }

    // --- Parse headers for keep-alive and range detection ---
    var keep_alive = false;
    var range_start: ?usize = null;
    var range_end: ?usize = null;

    if (header_len > 0) {
        const headers = header_buf[0..header_len];

        // Check for Connection: keep-alive
        if (std.mem.indexOf(u8, headers, "Connection: keep-alive") != null or std.mem.indexOf(u8, headers, "connection: keep-alive") != null) {
            keep_alive = true;
        }

        // Parse Range header for partial content support
        if (std.mem.indexOf(u8, headers, "Range: bytes=")) |range_pos| {
            const range_line_start = range_pos + "Range: bytes=".len;
            const range_line_end = std.mem.indexOfScalarPos(u8, headers, range_line_start, '\r') orelse
                std.mem.indexOfScalarPos(u8, headers, range_line_start, '\n') orelse headers.len;
            const range_spec = headers[range_line_start..range_line_end];

            // Parse simple "start-end" format
            if (std.mem.indexOf(u8, range_spec, "-")) |dash_pos| {
                const start_str = std.mem.trim(u8, range_spec[0..dash_pos], " ");
                const end_str = std.mem.trim(u8, range_spec[dash_pos + 1 ..], " ");

                if (start_str.len > 0) {
                    range_start = std.fmt.parseInt(usize, start_str, 10) catch null;
                }
                if (end_str.len > 0) {
                    range_end = std.fmt.parseInt(usize, end_str, 10) catch null;
                }
            }
        }
    }

    // --- Process request ---
    var status_code: u16 = 200;
    var content_length: usize = 0;
    const is_get = std.mem.eql(u8, method, "GET");
    const is_head = std.mem.eql(u8, method, "HEAD");
    const is_options = std.mem.eql(u8, method, "OPTIONS");

    if (is_get or is_head) {
        const request_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        const resp_info = try handleFileRequest(writer, config, request_path, is_head, range_start, range_end, req_allocator);
        status_code = resp_info.status;
        content_length = resp_info.content_length;
    } else if (is_options and config.cors) {
        // Handle CORS preflight requests
        const cors_response = "HTTP/1.1 200 OK\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: *\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n\r\n";
        try writer.writeAll(cors_response);
        status_code = 200;
        content_length = 0;
    } else {
        var method_not_allowed_buf: [256]u8 = undefined;
        const allow_methods = if (config.cors) "GET, HEAD, OPTIONS" else "GET, HEAD";
        const method_not_allowed = try std.fmt.bufPrint(&method_not_allowed_buf, "HTTP/1.1 405 Method Not Allowed\r\nAllow: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{allow_methods});
        try writer.writeAll(method_not_allowed);
        status_code = 405;
        content_length = 0;
    }

    try logger.logAccess(method, path, status_code, content_length, addr, config.log_json, req_allocator);
    return keep_alive;
}

pub fn handleFileRequest(writer: anytype, config: Config, path: []const u8, is_head: bool, range_start: ?usize, range_end: ?usize, allocator: std.mem.Allocator) !ResponseInfo {
    var file_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.root, path });
    defer allocator.free(file_path);

    // Quick path check - optimize common case
    const needs_index = std.mem.endsWith(u8, file_path, "/");
    if (needs_index) {
        if (config.no_dirlist) {
            return sendError(writer, 403, "Forbidden");
        }
        const old_path = file_path;
        file_path = try std.fmt.allocPrint(allocator, "{s}index.html", .{old_path});
        allocator.free(old_path);
    }

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Check for SPA fallback
            if (config.single_page) {
                return serveSpaFallback(writer, config, is_head, null, null, allocator);
            }
            // Check if directory without listing
            if (isDirectory(file_path) and config.no_dirlist) {
                return sendError(writer, 403, "Forbidden");
            }
            return sendError(writer, 404, "Not Found");
        },
        else => return sendError(writer, 500, "Internal Server Error"),
    };
    defer file.close();

    // Get file size for streaming
    const file_stat = try file.stat();
    const file_size = file_stat.size;
    const content_type = getMimeType(file_path);

    // Handle Range requests for partial content
    var actual_start: usize = 0;
    var actual_end: usize = file_size - 1;
    var status_code: u16 = 200;
    var is_partial = false;

    if (range_start != null or range_end != null) {
        is_partial = true;
        status_code = 206; // Partial Content

        if (range_start) |start| {
            actual_start = @min(start, file_size - 1);
        }
        if (range_end) |end| {
            actual_end = @min(end, file_size - 1);
        }
        // If only end specified (suffix-byte-range), calculate start
        if (range_start == null and range_end != null) {
            const suffix_length = @min(range_end.?, file_size);
            actual_start = file_size - suffix_length;
            actual_end = file_size - 1;
        }
    }

    const content_length = actual_end - actual_start + 1;

    // Build complete HTTP/1.1 headers with Range support
    var header_buf: [2048]u8 = undefined;
    const server_header = "Server: ezserve/0.2.0\r\n";
    const cors_header = if (config.cors) "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n" else "";
    const accept_ranges = "Accept-Ranges: bytes\r\n";

    const header = if (is_partial)
        try std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\n{s}{s}{s}Cache-Control: public, max-age=3600\r\nETag: \"{d}-{d}\"\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nConnection: close\r\n\r\n", .{ server_header, cors_header, accept_ranges, file_size, file_stat.mtime, content_type, content_length, actual_start, actual_end, file_size })
    else
        try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n{s}{s}{s}Cache-Control: public, max-age=3600\r\nETag: \"{d}-{d}\"\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ server_header, cors_header, accept_ranges, file_size, file_stat.mtime, content_type, content_length });

    // Send headers
    try writeAllNonBlocking(writer, header);

    // Ultra-optimized file streaming with Range support
    if (!is_head) {
        // Seek to start position for range requests
        if (is_partial and actual_start > 0) {
            try file.seekTo(actual_start);
        }

        // Use buffer to reduce syscall count
        var buf: [FILE_READ_BUF_SIZE]u8 = undefined;
        var total_sent: usize = 0;
        var remaining = content_length;

        while (total_sent < content_length and remaining > 0) {
            const bytes_to_read = @min(buf.len, remaining);
            const bytes_read = file.read(buf[0..bytes_to_read]) catch |err| {
                if (err == error.WouldBlock) {
                    // 非同期I/Oならイベント待ちにする（ここではbreakでOK）
                    break;
                }
                return err;
            };
            if (bytes_read == 0) break; // EOF

            try writeAllNonBlocking(writer, buf[0..bytes_read]);
            total_sent += bytes_read;
            remaining -= bytes_read;
        }
    }

    return ResponseInfo{ .status = status_code, .content_length = content_length };
}

// Helper functions for cleaner code
fn sendError(writer: anytype, status: u16, message: []const u8) !ResponseInfo {
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, message, message.len, message });
    try writer.writeAll(response);
    return ResponseInfo{ .status = status, .content_length = message.len };
}

fn serveSpaFallback(writer: anytype, config: Config, is_head: bool, _: ?usize, _: ?usize, allocator: std.mem.Allocator) !ResponseInfo {
    // SPA fallback: Range requests not supported, always return full file
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{config.root});
    defer allocator.free(index_path);

    const index_file = std.fs.cwd().openFile(index_path, .{}) catch {
        return sendError(writer, 404, "Not Found");
    };
    defer index_file.close();

    const file_stat = try index_file.stat();
    const file_size = file_stat.size;

    // Build complete headers with caching
    var header_buf: [1024]u8 = undefined;
    const server_header = "Server: ezserve/0.2.0\r\n";
    const cors_header = if (config.cors) "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n" else "";

    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n{s}{s}Cache-Control: public, max-age=3600\r\nETag: \"{d}-{d}\"\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ server_header, cors_header, file_size, file_stat.mtime, file_size });

    try writeAllNonBlocking(writer, header);

    // Ultra-optimized streaming - larger buffer
    if (!is_head) {
        var buf: [FILE_READ_BUF_SIZE]u8 = undefined;
        var total_sent: usize = 0;
        while (total_sent < file_size) {
            const bytes_read = index_file.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    break;
                }
                return err;
            };
            if (bytes_read == 0) break;
            try writeAllNonBlocking(writer, buf[0..bytes_read]);
            total_sent += bytes_read;
            if (total_sent >= file_size) break;
        }
    }

    return ResponseInfo{ .status = 200, .content_length = file_size };
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    defer dir.close();
    return true;
}

// writeAllNonBlocking function - optimized for speed
pub fn writeAllNonBlocking(writer: anytype, buf: []const u8) !void {
    return writer.writeAll(buf);
}

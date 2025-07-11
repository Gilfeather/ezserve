const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const logger = @import("logger.zig");

pub const Config = lib.Config;
pub const ResponseInfo = lib.ResponseInfo;
pub const getMimeType = lib.getMimeType;

const FILE_READ_BUF_SIZE = 16384; // 16KB buffer size

// Handle individual HTTP request - ZERO-ALLOCATION parsing
pub fn handleRequest(reader: anytype, writer: anytype, addr: std.net.Address, config: Config, req_allocator: std.mem.Allocator) !bool {
    // Pre-allocated buffers - NO dynamic allocation!
    var req_line_buf: [8192]u8 = undefined;
    var header_buf: [4096]u8 = undefined;
    var req_line_len: usize = 0;
    var found_req_line = false;
    
    // --- Edge-triggered reading: Keep reading until request line found ---
    while (!found_req_line) {
        const n = reader.read(req_line_buf[req_line_len..]) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(10_000); // 10μs backoff
                continue; // Retry read
            }
            return err;
        };
        if (n == 0) break; // EOF
        req_line_len += n;
        // Check for newline (end of request line)
        if (std.mem.indexOfScalar(u8, req_line_buf[0..req_line_len], '\n')) |idx| {
            found_req_line = true;
            req_line_len = idx + 1;
        }
        if (req_line_len == req_line_buf.len) break; // Buffer limit
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
    
    // --- Edge-triggered reading: Keep reading headers until end found ---
    var found_headers_end = false;
    var header_len: usize = 0;
    while (!found_headers_end) {
        const n = reader.read(header_buf[header_len..]) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        header_len += n;
        // Check for end of headers (\r\n\r\n or \n\n)
        if (std.mem.indexOf(u8, header_buf[0..header_len], "\r\n\r\n") != null or std.mem.indexOf(u8, header_buf[0..header_len], "\n\n") != null) {
            found_headers_end = true;
        }
        if (header_len == header_buf.len) break;
    }
    
    // --- Parse headers for keep-alive detection ---
    var keep_alive = false;
    if (header_len > 0) {
        const headers = header_buf[0..header_len];
        if (std.mem.indexOf(u8, headers, "Connection: keep-alive") != null or std.mem.indexOf(u8, headers, "connection: keep-alive") != null) {
            keep_alive = true;
        }
    }
    
    // --- Process request ---
    var status_code: u16 = 200;
    var content_length: usize = 0;
    const is_get = std.mem.eql(u8, method, "GET");
    const is_head = std.mem.eql(u8, method, "HEAD");
    
    if (is_get or is_head) {
        const request_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        const resp_info = try handleFileRequest(writer, config, request_path, is_head, req_allocator);
        status_code = resp_info.status;
        content_length = resp_info.content_length;
    } else {
        try writer.writeAll("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
        status_code = 405;
        content_length = 0;
    }
    
    try logger.logAccess(method, path, status_code, content_length, addr, config.log_json, req_allocator);
    return keep_alive;
}

pub fn handleFileRequest(writer: anytype, config: Config, path: []const u8, is_head: bool, allocator: std.mem.Allocator) !ResponseInfo {
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
                return serveSpaFallback(writer, config, is_head, allocator);
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
    
    // Build headers in buffer
    var header_buf: [1024]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, 
        "HTTP/1.1 200 OK\r\n{s}Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ if (config.cors) "Access-Control-Allow-Origin: *\r\n" else "", content_type, file_size }
    );

    // Send headers
    try writeAllNonBlocking(writer, header);
    
    // Ultra-optimized file streaming - larger buffer + sendfile-style optimization
    if (!is_head) {
        // Use buffer to reduce syscall count
        var buf: [FILE_READ_BUF_SIZE]u8 = undefined;
        var total_sent: usize = 0;
        while (total_sent < file_size) {
            const bytes_read = file.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    // 非同期I/Oならイベント待ちにする（ここではbreakでOK）
                    break;
                }
                return err;
            };
            if (bytes_read == 0) break; // EOF
            try writeAllNonBlocking(writer, buf[0..bytes_read]);
            total_sent += bytes_read;
            if (total_sent >= file_size) break;
        }
    }
    
    return ResponseInfo{ .status = 200, .content_length = file_size };
}

// Helper functions for cleaner code
fn sendError(writer: anytype, status: u16, message: []const u8) !ResponseInfo {
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, 
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n{s}", 
        .{ status, message, message.len, message }
    );
    try writer.writeAll(response);
    return ResponseInfo{ .status = status, .content_length = message.len };
}

fn serveSpaFallback(writer: anytype, config: Config, is_head: bool, allocator: std.mem.Allocator) !ResponseInfo {
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{config.root});
    defer allocator.free(index_path);
    
    const index_file = std.fs.cwd().openFile(index_path, .{}) catch {
        return sendError(writer, 404, "Not Found");
    };
    defer index_file.close();
    
    const file_stat = try index_file.stat();
    const file_size = file_stat.size;
    
    // Build headers
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 200 OK\r\n{s}Content-Type: text/html\r\nContent-Length: {d}\r\n\r\n",
        .{ if (config.cors) "Access-Control-Allow-Origin: *\r\n" else "", file_size }
    );
    
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

// writeAllNonBlocking function
pub fn writeAllNonBlocking(writer: anytype, buf: []const u8) !void {
    var remaining = buf;
    while (remaining.len > 0) {
        const n = writer.write(remaining) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(10_000); // 10μs backoff
                continue;
            }
            return err;
        };
        remaining = remaining[n..];
    }
}
const std = @import("std");
const lib = @import("lib.zig");

pub const Config = lib.Config;
pub const ResponseInfo = lib.ResponseInfo;
pub const getMimeType = lib.getMimeType;
pub const initMimeMap = lib.initMimeMap;

fn handleFileRequest(writer: anytype, config: Config, path: []const u8, is_head: bool, allocator: std.mem.Allocator) !ResponseInfo {
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
        "HTTP/1.1 200 OK\r\n{s}Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ if (config.cors) "Access-Control-Allow-Origin: *\r\n" else "", content_type, file_size }
    );
    
    // Send headers
    try writer.writeAll(header);
    
    // Stream file content (no readToEndAlloc!)
    if (!is_head) {
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try file.readAll(&buf);
            if (bytes_read == 0) break;
            try writer.writeAll(buf[0..bytes_read]);
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
    
    try writer.writeAll(header);
    
    // Stream content
    if (!is_head) {
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try index_file.readAll(&buf);
            if (bytes_read == 0) break;
            try writer.writeAll(buf[0..bytes_read]);
        }
    }
    
    return ResponseInfo{ .status = 200, .content_length = file_size };
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    defer dir.close();
    return true;
}


fn logAccess(method: []const u8, path: []const u8, status: u16, content_length: usize, addr: std.net.Address, log_json: bool, _: std.mem.Allocator) !void {
    const timestamp = std.time.timestamp();
    
    // Optimize IP formatting - avoid allocation for IPv4
    var ip_buf: [16]u8 = undefined;
    const client_ip = switch (addr.any.family) {
        std.posix.AF.INET => blk: {
            const ipv4 = addr.in;
            break :blk try std.fmt.bufPrint(&ip_buf, "{}.{}.{}.{}", .{
                (ipv4.sa.addr >> 0) & 0xff,
                (ipv4.sa.addr >> 8) & 0xff,
                (ipv4.sa.addr >> 16) & 0xff,
                (ipv4.sa.addr >> 24) & 0xff,
            });
        },
        else => "unknown",
    };
    
    if (log_json) {
        // Use bufPrint instead of allocPrint for JSON logs
        var log_buf: [512]u8 = undefined;
        const log_entry = try std.fmt.bufPrint(&log_buf, 
            "{{\"timestamp\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"content_length\":{d},\"client_ip\":\"{s}\"}}", 
            .{ timestamp, method, path, status, content_length, client_ip }
        );
        std.log.info("{s}", .{log_entry});
    } else {
        // Direct formatting without allocations
        std.log.info("{s} {s} {d} {d} {s}", .{ client_ip, method, status, content_length, path });
    }
}

fn printHelp() void {
    const help_text =
        \\ezserve - Ultra-lightweight HTTP static file server
        \\
        \\USAGE:
        \\    ezserve [OPTIONS]
        \\
        \\OPTIONS:
        \\    --port <number>     Port to listen on (default: 8000)
        \\    --bind <address>    Bind address (default: 127.0.0.1)
        \\    --root <path>       Root directory to serve (default: .)
        \\    --cors              Enable CORS headers
        \\    --single-page       SPA mode - fallback to index.html on 404
        \\    --no-dirlist        Disable directory listing
        \\    --log=json          Output access logs in JSON format
        \\    --watch             File watching mode (TODO)
        \\    --help, -h          Show this help message
        \\
        \\EXAMPLES:
        \\    ezserve                              # Serve current directory on port 8000
        \\    ezserve --port 3000 --cors           # Development server with CORS
        \\    ezserve --bind 0.0.0.0 --port 80     # Production server on all interfaces
        \\    ezserve --single-page --no-dirlist   # SPA deployment mode
        \\    ezserve --root ./dist --log=json     # Serve build directory with JSON logs
        \\
        \\For more information, visit: https://github.com/tomas/ezserve
        \\
    ;
    std.log.info("{s}", .{help_text});
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};

    // Simple argument parsing
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = std.fmt.parseInt(u16, args[i+1], 10) catch {
                std.log.err("Invalid port number: {s}", .{args[i+1]});
                std.log.err("Port must be a number between 1 and 65535", .{});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            config.root = args[i+1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            config.bind = args[i+1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--single-page")) {
            config.single_page = true;
        } else if (std.mem.eql(u8, args[i], "--cors")) {
            config.cors = true;
        } else if (std.mem.eql(u8, args[i], "--no-dirlist")) {
            config.no_dirlist = true;
        } else if (std.mem.eql(u8, args[i], "--log=json")) {
            config.log_json = true;
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            config.watch = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.log.err("Unknown option: {s}", .{args[i]});
            std.log.err("Use --help to see available options", .{});
            std.process.exit(1);
        } else {
            std.log.err("Unexpected argument: {s}", .{args[i]});
            std.log.err("Use --help to see usage information", .{});
            std.process.exit(1);
        }
    }

    return config;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const config = try parseArgs(allocator);

    // Use optimized event-driven approach with thread pool
    try eventDrivenMain(allocator, config);
}

// Event-driven implementation using I/O multiplexing
fn eventDrivenMain(_: std.mem.Allocator, config: Config) !void {
    // Start server with shared allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const shared_allocator = gpa.allocator();
    
    // Parse bind address
    const bind_addr = try std.net.Address.parseIp4(config.bind, config.port);
    
    var server = bind_addr.listen(.{
        .reuse_address = true,
    }) catch |err| {
        switch (err) {
            error.AddressInUse => {
                std.log.err("Error: Port {d} is already in use", .{config.port});
                std.log.err("Try a different port with --port <number>", .{});
                return;
            },
            error.PermissionDenied => {
                std.log.err("Error: Permission denied to bind to port {d}", .{config.port});
                std.log.err("Try using a port above 1024 or run with sudo", .{});
                return;
            },
            else => {
                std.log.err("Error starting server: {}", .{err});
                return;
            },
        }
    };
    defer server.deinit();
    std.log.info("ezserve: http://{s}:{d} root={s} (event-driven)", .{config.bind, config.port, config.root});

    // Create a thread pool for handling connections
    const num_threads = @max(1, std.Thread.getCpuCount() catch 4);
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = shared_allocator,
        .n_jobs = num_threads,
    });
    defer pool.deinit();
    
    // Event-driven accept loop with async connection spawning
    while (true) {
        const conn = try server.accept();
        
        // Spawn connection handler in thread pool
        try pool.spawn(handleConnectionInPool, .{ conn, config, shared_allocator });
    }
}

// Connection handler for thread pool
fn handleConnectionInPool(conn: std.net.Server.Connection, config: Config, shared_allocator: std.mem.Allocator) void {
    defer conn.stream.close();
    
    // Use arena for this connection - reuse pattern
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();
    
    handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
        std.log.err("Error handling pooled request: {}", .{err});
    };
}

// Fallback synchronous implementation
fn mainSync(_: std.mem.Allocator, config: Config) !void {
    // Start server with shared allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const shared_allocator = gpa.allocator();
    
    // Parse bind address
    const bind_addr = try std.net.Address.parseIp4(config.bind, config.port);
    
    var server = bind_addr.listen(.{
        .reuse_address = true,
    }) catch |err| {
        switch (err) {
            error.AddressInUse => {
                std.log.err("Error: Port {d} is already in use", .{config.port});
                std.log.err("Try a different port with --port <number>", .{});
                return;
            },
            error.PermissionDenied => {
                std.log.err("Error: Permission denied to bind to port {d}", .{config.port});
                std.log.err("Try using a port above 1024 or run with sudo", .{});
                return;
            },
            else => {
                std.log.err("Error starting server: {}", .{err});
                return;
            },
        }
    };
    defer server.deinit();
    std.log.info("ezserve: http://{s}:{d} root={s} (sync mode)", .{config.bind, config.port, config.root});

    // Determine number of worker threads (CPU cores)
    const num_threads = @max(1, std.Thread.getCpuCount() catch 4);
    std.log.info("Starting {} worker threads", .{num_threads});
    
    // Create worker threads with pre-allocated arenas
    const threads = try shared_allocator.alloc(std.Thread, num_threads);
    defer shared_allocator.free(threads);
    
    var should_stop = std.atomic.Value(bool).init(false);
    
    // Start worker threads
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ &server, config, shared_allocator, &should_stop });
    }
    
    // Wait for threads to complete (never happens in normal operation)
    for (threads) |thread| {
        thread.join();
    }
}

// High-performance worker thread - no ThreadPool overhead
fn workerThread(server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool)) void {
    // Pre-allocate arena for reuse across requests
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
    defer arena.deinit();
    
    while (!should_stop.load(.monotonic)) {
        // Accept connection directly in worker thread
        const conn = server.accept() catch |err| {
            std.log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        defer conn.stream.close();
        
        // Reset arena instead of deinit/init - much faster!
        _ = arena.reset(.free_all);
        const req_allocator = arena.allocator();
        
        handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
            std.log.err("Error handling request: {}", .{err});
        };
    }
}

// Handle individual HTTP request
fn handleRequest(reader: anytype, writer: anytype, addr: std.net.Address, config: Config, req_allocator: std.mem.Allocator) !void {
    // Read request line - use dynamic allocation but with larger limit
    const req_line = reader.readUntilDelimiterOrEofAlloc(req_allocator, '\n', 8192) catch |err| {
        std.log.err("Error reading request line: {}", .{err});
        return;
    } orelse return;
    
    // Fast path parsing - avoid string copies when possible
    const clean_line = std.mem.trim(u8, req_line, " \r\n\t");
    var it = std.mem.splitScalar(u8, clean_line, ' ');
    const method = std.mem.trim(u8, it.next() orelse "", " \r\n\t");
    const path = std.mem.trim(u8, it.next() orelse "/", " \r\n\t");
    
    // Skip headers efficiently
    while (true) {
        const h = reader.readUntilDelimiterOrEofAlloc(req_allocator, '\n', 8192) catch break;
        if (h) |header_line| {
            if (std.mem.trimRight(u8, header_line, "\r\n").len == 0) break;
        } else break;
    }
    
    var status_code: u16 = 200;
    var content_length: usize = 0;
    
    // Optimized method check - reduce comparisons
    const is_get = std.mem.eql(u8, method, "GET");
    const is_head = std.mem.eql(u8, method, "HEAD");
    
    if (is_get or is_head) {
        const request_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        const resp_info = try handleFileRequest(writer, config, request_path, is_head, req_allocator);
        status_code = resp_info.status;
        content_length = resp_info.content_length;
    } else {
        // Use writeAll instead of print for static response
        try writer.writeAll("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
        status_code = 405;
        content_length = 0;
    }
    
    try logAccess(method, path, status_code, content_length, addr, config.log_json, req_allocator);
} 
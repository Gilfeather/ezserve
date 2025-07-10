const std = @import("std");
const lib = @import("lib.zig");

pub const Config = lib.Config;
pub const ResponseInfo = lib.ResponseInfo;
pub const getMimeType = lib.getMimeType;
pub const initMimeMap = lib.initMimeMap;

fn handleFileRequest(writer: anytype, config: Config, path: []const u8, is_head: bool, allocator: std.mem.Allocator) !ResponseInfo {
    
    var file_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.root, path });
    defer allocator.free(file_path);
    
    if (std.mem.endsWith(u8, file_path, "/")) {
        if (config.no_dirlist) {
            try writer.print("HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\n\r\nForbidden", .{});
            return ResponseInfo{ .status = 403, .content_length = 9 };
        }
        const old_path = file_path;
        file_path = try std.fmt.allocPrint(allocator, "{s}index.html", .{old_path});
        allocator.free(old_path);
    }
    
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Check if it's a directory
            const is_dir = blk: {
                var dir = std.fs.cwd().openDir(file_path, .{}) catch |dir_err| {
                    if (dir_err == error.FileNotFound) break :blk false;
                    break :blk false;
                };
                dir.close();
                break :blk true;
            };
            
            if (is_dir and config.no_dirlist) {
                try writer.print("HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\n\r\nForbidden", .{});
                return ResponseInfo{ .status = 403, .content_length = 9 };
            }
            
            if (config.single_page) {
                const index_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{config.root});
                defer allocator.free(index_path);
                
                const index_file = std.fs.cwd().openFile(index_path, .{}) catch {
                    try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found", .{});
                    return ResponseInfo{ .status = 404, .content_length = 9 };
                };
                defer index_file.close();
                
                const content = try index_file.readToEndAlloc(allocator, 1024 * 1024);
                defer allocator.free(content);
                
                try writer.print("HTTP/1.1 200 OK\r\n", .{});
                if (config.cors) try writer.print("Access-Control-Allow-Origin: *\r\n", .{});
                try writer.print("Content-Type: text/html\r\nContent-Length: {d}\r\n\r\n", .{content.len});
                if (!is_head) try writer.print("{s}", .{content});
                return ResponseInfo{ .status = 200, .content_length = content.len };
            }
        }
        
        try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found", .{});
        return ResponseInfo{ .status = 404, .content_length = 9 };
    };
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    
    const content_type = getMimeType(file_path);
    
    try writer.print("HTTP/1.1 200 OK\r\n", .{});
    if (config.cors) try writer.print("Access-Control-Allow-Origin: *\r\n", .{});
    try writer.print("Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ content_type, content.len });
    if (!is_head) try writer.print("{s}", .{content});
    return ResponseInfo{ .status = 200, .content_length = content.len };
}


fn logAccess(method: []const u8, path: []const u8, status: u16, content_length: usize, addr: std.net.Address, log_json: bool, allocator: std.mem.Allocator) !void {
    
    const timestamp = std.time.timestamp();
    const client_ip = switch (addr.any.family) {
        std.posix.AF.INET => blk: {
            const ipv4 = addr.in;
            break :blk try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
                (ipv4.sa.addr >> 0) & 0xff,
                (ipv4.sa.addr >> 8) & 0xff,
                (ipv4.sa.addr >> 16) & 0xff,
                (ipv4.sa.addr >> 24) & 0xff,
            });
        },
        else => try std.fmt.allocPrint(allocator, "unknown", .{}),
    };
    defer allocator.free(client_ip);
    
    if (log_json) {
        const log_entry = try std.fmt.allocPrint(allocator, "{{\"timestamp\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"content_length\":{d},\"client_ip\":\"{s}\"}}", .{
            timestamp,
            method,
            path,
            status,
            content_length,
            client_ip,
        });
        defer allocator.free(log_entry);
        std.log.info("{s}", .{log_entry});
    } else {
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
    std.log.info("ezserve: http://{s}:{d} root={s}", .{config.bind, config.port, config.root});

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        var reader = conn.stream.reader();
        
        // Use arena allocator for request parsing (resets after each request)
        var arena = std.heap.ArenaAllocator.init(shared_allocator);
        defer arena.deinit();
        const req_allocator = arena.allocator();
        
        // Read first line (request line) with dynamic allocation
        const req_line = reader.readUntilDelimiterOrEofAlloc(req_allocator, '\n', 8192) catch |err| {
            std.log.err("Error reading request line: {}", .{err});
            continue;
        };
        if (req_line) |line| {
            // Remove newline and carriage return
            const clean_line = std.mem.trim(u8, line, " \r\n\t");
            // Split by space
            var it = std.mem.splitScalar(u8, clean_line, ' ');
            const method_raw = it.next() orelse "";
            const path_raw = it.next() orelse "/";
            _ = it.next() orelse "";
            
            
            // Copy method and path to owned memory using arena allocator
            const method = try req_allocator.dupe(u8, std.mem.trim(u8, method_raw, " \r\n\t"));
            const path = try req_allocator.dupe(u8, std.mem.trim(u8, path_raw, " \r\n\t"));
            
            // Skip headers until empty line with dynamic allocation
            while (true) {
                const h = reader.readUntilDelimiterOrEofAlloc(req_allocator, '\n', 8192) catch |err| {
                    std.log.err("Error reading header: {}", .{err});
                    break;
                };
                if (h) |header_line| {
                    if (std.mem.trimRight(u8, header_line, "\r\n").len == 0) break;
                } else break;
            }
            
            var status_code: u16 = 200;
            var content_length: usize = 0;
            
            // File serving functionality
            if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
                const request_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
                const is_head = std.mem.eql(u8, method, "HEAD");
                const resp_info = try handleFileRequest(conn.stream.writer(), config, request_path, is_head, req_allocator);
                status_code = resp_info.status;
                content_length = resp_info.content_length;
            } else {
                try conn.stream.writer().print(
                    "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n",
                    .{}
                );
                status_code = 405;
                content_length = 0;
            }
            
            try logAccess(method, path, status_code, content_length, conn.address, config.log_json, req_allocator);
        }
    }
} 
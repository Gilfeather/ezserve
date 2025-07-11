const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");

pub const Config = lib.Config;
pub const ResponseInfo = lib.ResponseInfo;
pub const getMimeType = lib.getMimeType;
pub const initMimeMap = lib.initMimeMap;

const FILE_READ_BUF_SIZE = 16384; // 16KB, 必要に応じて32KBや64KBに調整可

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
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n{s}Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ if (config.cors) "Access-Control-Allow-Origin: *\r\n" else "", content_type, file_size });

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
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, message, message.len, message });
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
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n{s}Content-Type: text/html\r\nContent-Length: {d}\r\n\r\n", .{ if (config.cors) "Access-Control-Allow-Origin: *\r\n" else "", file_size });

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

// Ultra-fast logging - NO std.log.info bottleneck!
fn logAccess(method: []const u8, path: []const u8, status: u16, content_length: usize, addr: std.net.Address, log_json: bool, _: std.mem.Allocator) !void {
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
            config.port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                std.log.err("Invalid port number: {s}", .{args[i + 1]});
                std.log.err("Port must be a number between 1 and 65535", .{});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            config.root = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            config.bind = args[i + 1];
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

    // Use ultra-high-performance single-thread poller
    try ultraPollerMain(allocator, config);
}

// ULTRA-HIGH-PERFORMANCE SINGLE-THREAD POLLER - NO HASHMAP, NO OVERHEAD!
fn ultraPollerMain(_: std.mem.Allocator, config: Config) !void {
    // Start server with optimized allocator
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

    // Set server socket to non-blocking mode
    const flags = try std.posix.fcntl(server.stream.handle, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(server.stream.handle, std.posix.F.SETFL, flags | 0x0004); // O_NONBLOCK
    std.log.info("ezserve: http://{s}:{d} root={s} (ultra-poller)", .{ config.bind, config.port, config.root });

    // Initialize ultra poller - NO HASHMAP!
    var ultra_poller = try UltraPoller.init(shared_allocator);
    defer ultra_poller.deinit();

    // Add server socket
    try ultra_poller.addServer(server.stream.handle);

    // Single-thread event loop - ultimate performance
    try ultra_poller.eventLoop(&server, config, shared_allocator);
}

// ULTRA POLLER - Zero overhead, maximum performance
const UltraPoller = struct {
    allocator: std.mem.Allocator,
    poller_fd: i32,
    server_fd: i32,

    // Pre-allocated Arena for all requests - reuse via reset()
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const poller_fd = switch (@import("builtin").target.os.tag) {
            .macos => try initKqueue(),
            .linux => try initEpoll(),
            else => return error.UnsupportedPlatform,
        };

        return Self{
            .allocator = allocator,
            .poller_fd = poller_fd,
            .server_fd = -1,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        _ = std.posix.close(self.poller_fd);
    }

    // macOS kqueue implementation
    fn initKqueue() !i32 {
        const kq = std.posix.system.kqueue();
        if (kq < 0) return error.KqueueCreateFailed;
        return @intCast(kq);
    }

    // Linux epoll implementation
    fn initEpoll() !i32 {
        const epfd = std.posix.system.epoll_create1(std.posix.SOCK.CLOEXEC);
        if (epfd < 0) return error.EpollCreateFailed;
        return @intCast(epfd);
    }

    pub fn addServer(self: *Self, server_fd: i32) !void {
        self.server_fd = server_fd;

        switch (@import("builtin").target.os.tag) {
            .macos => try self.addKqueueServer(server_fd),
            .linux => try self.addEpollServer(server_fd),
            else => return error.UnsupportedPlatform,
        }
    }

    // macOS kqueue server registration
    fn addKqueueServer(self: *Self, fd: i32) !void {
        const EVFILT_READ: i16 = -1;
        const EV_ADD: u16 = 0x0001;
        const EV_ENABLE: u16 = 0x0004;

        var changelist: [1]std.posix.system.Kevent = undefined;
        changelist[0] = std.posix.system.Kevent{
            .ident = @intCast(fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        var eventlist: [1]std.posix.system.Kevent = undefined;
        const result = std.posix.system.kevent(self.poller_fd, &changelist, 1, &eventlist, 0, null);
        if (result < 0) return error.KqueueAddEventFailed;
    }

    // Linux epoll server registration
    fn addEpollServer(self: *Self, fd: i32) !void {
        const EPOLLIN: u32 = 0x001;
        const EPOLLET: u32 = 0x80000000; // Edge-triggered
        const EPOLL_CTL_ADD: i32 = 1;

        var event = std.posix.system.epoll_event{
            .events = EPOLLIN | EPOLLET,
            .data = .{ .fd = fd },
        };

        const result = std.posix.system.epoll_ctl(self.poller_fd, EPOLL_CTL_ADD, fd, &event);
        if (result < 0) return error.EpollAddEventFailed;
    }

    pub fn eventLoop(self: *Self, server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator) !void {
        _ = shared_allocator; // Use arena instead

        while (true) {
            switch (@import("builtin").target.os.tag) {
                .macos => try self.kqueueEventLoop(server, config),
                .linux => try self.epollEventLoop(server, config),
                else => return error.UnsupportedPlatform,
            }
        }
    }

    // macOS kqueue event loop - ULTRA FAST
    fn kqueueEventLoop(self: *Self, server: *std.net.Server, config: Config) !void {
        var eventlist: [1024]std.posix.system.Kevent = undefined;

        // Short timeout for responsiveness
        var timeout = std.posix.system.timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
        var changelist: [1]std.posix.system.Kevent = undefined;
        const num_events = std.posix.system.kevent(self.poller_fd, &changelist, 0, &eventlist, 1024, &timeout);

        if (num_events < 0) return error.KqueueWaitFailed;
        if (num_events == 0) return; // Timeout

        for (eventlist[0..@intCast(num_events)]) |event| {
            const fd: i32 = @intCast(event.ident);

            if (fd == self.server_fd) {
                // Accept and immediately handle connections
                try self.handleAcceptAndProcess(server, config);
            }
        }
    }

    // Linux epoll event loop - ULTRA FAST
    fn epollEventLoop(self: *Self, server: *std.net.Server, config: Config) !void {
        var events: [1024]std.posix.system.epoll_event = undefined;

        // Short timeout for responsiveness
        const num_events = std.posix.system.epoll_wait(self.poller_fd, &events, 1024, 10); // 10ms

        if (num_events < 0) return error.EpollWaitFailed;
        if (num_events == 0) return; // Timeout

        for (events[0..@intCast(num_events)]) |event| {
            const fd = event.data.fd;

            if (fd == self.server_fd) {
                // Accept and immediately handle connections
                try self.handleAcceptAndProcess(server, config);
            }
        }
    }

    // Accept + Process in single operation - NO THREAD OVERHEAD
    fn handleAcceptAndProcess(self: *Self, server: *std.net.Server, config: Config) !void {
        while (true) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => break, // No more connections
                else => return err,
            };
            defer conn.stream.close();

            // Reset arena for this request - ULTRA FAST!
            _ = self.arena.reset(.free_all);
            const req_allocator = self.arena.allocator();

            // keep-alive
            while (true) {
                const keep_alive = handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
                    if (builtin.mode != .ReleaseFast) {
                        std.log.err("Error handling ultra request: {}", .{err});
                    }
                    break;
                };
                if (!keep_alive) break;
            }
        }
    }
};

// writeAllNonBlocking関数を追加
fn writeAllNonBlocking(writer: anytype, buf: []const u8) !void {
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

// Custom high-performance poller implementation
fn customPollerMain(_: std.mem.Allocator, config: Config) !void {
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

    // Set server socket to non-blocking mode
    const flags = try std.posix.fcntl(server.stream.handle, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(server.stream.handle, std.posix.F.SETFL, flags | 0x0004); // O_NONBLOCK = 0x0004
    std.log.info("ezserve: http://{s}:{d} root={s} (custom poller)", .{ config.bind, config.port, config.root });

    // Initialize custom poller
    var poller = try CustomPoller.init(shared_allocator);
    defer poller.deinit();

    // Add server socket to poller
    try poller.addSocket(server.stream.handle, .accept);

    // Start worker threads for handling connections
    const num_threads = @max(1, std.Thread.getCpuCount() catch 4);
    std.log.info("Starting {} worker threads with custom poller", .{num_threads});

    const threads = try shared_allocator.alloc(std.Thread, num_threads);
    defer shared_allocator.free(threads);

    var should_stop = std.atomic.Value(bool).init(false);

    // Start worker threads
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, pollerWorkerThread, .{ &poller, config, shared_allocator, &should_stop });
    }

    // Main event loop
    try poller.eventLoop(&server, config, shared_allocator, &should_stop);

    // Wait for threads to complete
    for (threads) |thread| {
        thread.join();
    }
}

// Event types
const EventType = enum {
    accept,
    read,
    write,
};

// Connection tracking
const PollerConnection = struct {
    fd: i32,
    event_type: EventType,
    data: ?*anyopaque = null,
};

// Custom Poller implementation for maximum performance
const CustomPoller = struct {
    allocator: std.mem.Allocator,
    poller_fd: i32,
    connections: std.AutoHashMap(i32, PollerConnection),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const poller_fd = switch (@import("builtin").target.os.tag) {
            .macos => try initKqueue(),
            .linux => try initEpoll(),
            else => return error.UnsupportedPlatform,
        };

        return Self{
            .allocator = allocator,
            .poller_fd = poller_fd,
            .connections = std.AutoHashMap(i32, PollerConnection).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.connections.deinit();
        _ = std.posix.close(self.poller_fd);
    }

    // macOS kqueue implementation
    fn initKqueue() !i32 {
        const kq = std.posix.system.kqueue();
        if (kq < 0) return error.KqueueCreateFailed;
        return @intCast(kq);
    }

    // Linux epoll implementation
    fn initEpoll() !i32 {
        const epfd = std.posix.system.epoll_create1(std.posix.SOCK.CLOEXEC);
        if (epfd < 0) return error.EpollCreateFailed;
        return @intCast(epfd);
    }

    pub fn addSocket(self: *Self, fd: i32, event_type: EventType) !void {
        const conn = PollerConnection{
            .fd = fd,
            .event_type = event_type,
        };

        try self.connections.put(fd, conn);

        switch (@import("builtin").target.os.tag) {
            .macos => try self.addKqueueEvent(fd, event_type),
            .linux => try self.addEpollEvent(fd, event_type),
            else => return error.UnsupportedPlatform,
        }
    }

    // macOS kqueue event registration
    fn addKqueueEvent(self: *Self, fd: i32, event_type: EventType) !void {
        const EVFILT_READ: i16 = -1;
        const EVFILT_WRITE: i16 = -2;
        const EV_ADD: u16 = 0x0001;
        const EV_ENABLE: u16 = 0x0004;

        const filter = switch (event_type) {
            .accept, .read => EVFILT_READ,
            .write => EVFILT_WRITE,
        };

        // Use proper kevent struct
        var changelist: [1]std.posix.system.Kevent = undefined;
        changelist[0] = std.posix.system.Kevent{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = EV_ADD | EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        var eventlist: [1]std.posix.system.Kevent = undefined;
        const result = std.posix.system.kevent(self.poller_fd, &changelist, 1, &eventlist, 0, null);
        if (result < 0) return error.KqueueAddEventFailed;
    }

    // Linux epoll event registration
    fn addEpollEvent(self: *Self, fd: i32, event_type: EventType) !void {
        const EPOLLIN: u32 = 0x001;
        const EPOLLOUT: u32 = 0x004;
        const EPOLLET: u32 = 0x80000000; // Edge-triggered
        const EPOLL_CTL_ADD: i32 = 1;

        const events = switch (event_type) {
            .accept, .read => EPOLLIN | EPOLLET,
            .write => EPOLLOUT | EPOLLET,
        };

        var event = std.posix.system.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };

        const result = std.posix.system.epoll_ctl(self.poller_fd, EPOLL_CTL_ADD, fd, &event);
        if (result < 0) return error.EpollAddEventFailed;
    }

    pub fn eventLoop(self: *Self, server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool)) !void {
        const max_events = 64;

        while (!should_stop.load(.monotonic)) {
            switch (@import("builtin").target.os.tag) {
                .macos => try self.kqueueEventLoop(server, config, shared_allocator, max_events),
                .linux => try self.epollEventLoop(server, config, shared_allocator, max_events),
                else => return error.UnsupportedPlatform,
            }
        }
    }

    // macOS kqueue event loop
    fn kqueueEventLoop(self: *Self, server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator, max_events: u32) !void {
        var eventlist: [64]std.posix.system.Kevent = undefined;

        // Wait for events with 1 second timeout
        var timeout = std.posix.system.timespec{ .sec = 1, .nsec = 0 };
        var changelist: [1]std.posix.system.Kevent = undefined;
        const num_events = std.posix.system.kevent(self.poller_fd, &changelist, 0, &eventlist, @intCast(max_events), &timeout);

        if (num_events < 0) return error.KqueueWaitFailed;
        if (num_events == 0) return; // Timeout

        for (eventlist[0..@intCast(num_events)]) |event| {
            const fd: i32 = @intCast(event.ident);

            if (fd == server.stream.handle) {
                // Server socket - accept new connections
                try self.handleAccept(server, shared_allocator);
            } else {
                // Client socket - handle request
                try self.handleConnection(fd, config, shared_allocator);
            }
        }
    }

    // Linux epoll event loop
    fn epollEventLoop(self: *Self, server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator, max_events: u32) !void {
        var events: [64]std.posix.system.epoll_event = undefined;

        // Wait for events with 1 second timeout
        const num_events = std.posix.system.epoll_wait(self.poller_fd, &events, @intCast(max_events), 1000);

        if (num_events < 0) return error.EpollWaitFailed;
        if (num_events == 0) return; // Timeout

        for (events[0..@intCast(num_events)]) |event| {
            const fd = event.data.fd;

            if (fd == server.stream.handle) {
                // Server socket - accept new connections
                try self.handleAccept(server, shared_allocator);
            } else {
                // Client socket - handle request
                try self.handleConnection(fd, config, shared_allocator);
            }
        }
    }

    fn handleAccept(self: *Self, server: *std.net.Server, shared_allocator: std.mem.Allocator) !void {
        while (true) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => break, // No more connections
                else => return err,
            };

            // Set connection to non-blocking
            const conn_flags = try std.posix.fcntl(conn.stream.handle, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(conn.stream.handle, std.posix.F.SETFL, conn_flags | 0x0004); // O_NONBLOCK = 0x0004

            // Add to poller for read events
            try self.addSocket(conn.stream.handle, .read);

            // Store connection data
            const conn_data = try shared_allocator.create(std.net.Server.Connection);
            conn_data.* = conn;

            if (self.connections.getPtr(conn.stream.handle)) |connection| {
                connection.data = conn_data;
            }
        }
    }

    fn handleConnection(self: *Self, fd: i32, config: Config, shared_allocator: std.mem.Allocator) !void {
        const connection = self.connections.get(fd) orelse return;

        if (connection.data) |data| {
            const conn_data: *std.net.Server.Connection = @ptrCast(@alignCast(data));

            // OPTIMIZED: Direct handling without arena allocation overhead
            // Use stack-based allocation for small requests
            var stack_buffer: [16384]u8 = undefined; // 16KB stack buffer
            var fba = std.heap.FixedBufferAllocator.init(&stack_buffer);
            const req_allocator = fba.allocator();

            handleRequest(conn_data.stream.reader(), conn_data.stream.writer(), conn_data.address, config, req_allocator) catch |err| {
                if (builtin.mode != .ReleaseFast) {
                    std.log.err("Error handling polled request: {}", .{err});
                }
            };

            // Clean up connection
            conn_data.stream.close();
            shared_allocator.destroy(conn_data);
            _ = self.connections.remove(fd);
        }
    }
};

// Worker thread for poller
fn pollerWorkerThread(poller: *CustomPoller, config: Config, shared_allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool)) void {
    _ = poller;
    _ = config;
    _ = shared_allocator;
    _ = should_stop;

    // Worker threads will handle connection processing
    // Main event loop handles accept/read/write events
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
    std.log.info("ezserve: http://{s}:{d} root={s} (event-driven)", .{ config.bind, config.port, config.root });

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
    std.log.info("ezserve: http://{s}:{d} root={s} (sync mode)", .{ config.bind, config.port, config.root });

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

// Handle individual HTTP request - ZERO-ALLOCATION parsing
fn handleRequest(reader: anytype, writer: anytype, addr: std.net.Address, config: Config, req_allocator: std.mem.Allocator) !bool {
    // Pre-allocated buffers - NO dynamic allocation!
    var req_line_buf: [8192]u8 = undefined;
    var header_buf: [4096]u8 = undefined;
    var req_line_len: usize = 0;
    var found_req_line = false;
    // --- エッジトリガー対応: リクエストラインをWouldBlockまで繰り返しread ---
    while (!found_req_line) {
        const n = reader.read(req_line_buf[req_line_len..]) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(10_000); // 10μs backoff
                continue; // 次のread試行へ
            }
            return err;
        };
        if (n == 0) break; // EOF
        req_line_len += n;
        // 改行が来たらリクエストライン終端
        if (std.mem.indexOfScalar(u8, req_line_buf[0..req_line_len], '\n')) |idx| {
            found_req_line = true;
            req_line_len = idx + 1;
        }
        if (req_line_len == req_line_buf.len) break; // バッファ上限
    }
    if (!found_req_line) {
        try writer.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        return false;
    }
    // リクエストラインをパース
    const req_line = req_line_buf[0..req_line_len];
    const clean_line = std.mem.trim(u8, req_line, " \r\n\t");
    var it = std.mem.splitScalar(u8, clean_line, ' ');
    const method = std.mem.trim(u8, it.next() orelse "", " \r\n\t");
    const path = std.mem.trim(u8, it.next() orelse "/", " \r\n\t");
    // --- エッジトリガー対応: ヘッダもWouldBlockまで繰り返しread ---
    var found_headers_end = false;
    var header_len: usize = 0;
    while (!found_headers_end) {
        const n = reader.read(header_buf[header_len..]) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        header_len += n;
        // 連続した\r\n\r\nまたは\n\nでヘッダ終端
        if (std.mem.indexOf(u8, header_buf[0..header_len], "\r\n\r\n") != null or std.mem.indexOf(u8, header_buf[0..header_len], "\n\n") != null) {
            found_headers_end = true;
        }
        if (header_len == header_buf.len) break;
    }
    // --- ヘッダ読み込み後にkeep-alive判定 ---
    var keep_alive = false;
    // ヘッダバッファからConnection: keep-aliveを探す
    if (header_len > 0) {
        const headers = header_buf[0..header_len];
        if (std.mem.indexOf(u8, headers, "Connection: keep-alive") != null or std.mem.indexOf(u8, headers, "connection: keep-alive") != null) {
            keep_alive = true;
        }
    }
    // --- 以降は従来通り ---
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
    try logAccess(method, path, status_code, content_length, addr, config.log_json, req_allocator);
    return keep_alive;
}

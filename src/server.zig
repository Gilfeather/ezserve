const std = @import("std");
const builtin = @import("builtin");
const poller = @import("poller.zig");

const Config = @import("lib.zig").Config;

// Ultra-high-performance multi-threaded poller
pub fn ultraPollerMain(_: std.mem.Allocator, config: Config) !void {
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

    // Initialize ultra poller
    var ultra_poller = try poller.UltraPoller.init(shared_allocator);
    defer ultra_poller.deinit();

    // Add server socket
    try ultra_poller.addServer(server.stream.handle);

    // Multi-threaded event loop for maximum performance
    try ultra_poller.multiThreadEventLoop(&server, config, shared_allocator);
}

// Fallback synchronous implementation for compatibility
pub fn mainSync(_: std.mem.Allocator, config: Config) !void {
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
    std.log.info("ezserve: http://{s}:{d} root={s} (optimized sync mode)", .{ config.bind, config.port, config.root });

    // Use configured or optimal number of threads
    const num_threads = if (config.threads) |t|
        @max(1, t) // Ensure at least 1 thread
    else
        @max(1, std.Thread.getCpuCount() catch 4); // Default: auto-detect all cores
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

// High-performance worker thread - blocking I/O for reliability
fn workerThread(server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool)) void {
    const http = @import("http.zig");

    // Pre-allocate arena for reuse across requests
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
    defer arena.deinit();

    while (!should_stop.load(.monotonic)) {
        // Accept connection with blocking I/O - no errors
        const conn = server.accept() catch |err| {
            // Only log if not stopping
            if (!should_stop.load(.monotonic)) {
                std.log.err("Failed to accept connection: {}", .{err});
            }
            continue;
        };
        defer conn.stream.close();

        // Reset arena instead of deinit/init - much faster!
        _ = arena.reset(.free_all);
        const req_allocator = arena.allocator();

        // Handle request with blocking I/O
        _ = http.handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
            if (builtin.mode != .ReleaseFast) {
                std.log.err("Error handling request: {}", .{err});
            }
        };
    }
}

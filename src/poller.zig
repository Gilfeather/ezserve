const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

const Config = @import("lib.zig").Config;

// Connection queue for worker threads
const ConnectionQueue = struct {
    mutex: std.Thread.Mutex = .{},
    connections: std.ArrayList(std.net.Server.Connection),
    condition: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator) ConnectionQueue {
        return ConnectionQueue{
            .connections = std.ArrayList(std.net.Server.Connection).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionQueue) void {
        self.connections.deinit();
    }

    pub fn push(self: *ConnectionQueue, conn: std.net.Server.Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.append(conn);
        self.condition.signal();
    }

    pub fn pop(self: *ConnectionQueue) ?std.net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.connections.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        return self.connections.orderedRemove(0);
    }

    pub fn tryPop(self: *ConnectionQueue) ?std.net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.items.len == 0) return null;
        return self.connections.orderedRemove(0);
    }
};

// ULTRA POLLER - Zero overhead, maximum performance
pub const UltraPoller = struct {
    allocator: std.mem.Allocator,
    poller_fd: i32,
    server_fd: i32,

    // Pre-allocated Arena for all requests - reuse via reset()
    arena: std.heap.ArenaAllocator,

    // Connection queue for worker threads
    conn_queue: ConnectionQueue,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Starting initialization", .{});

        // Initialize each component step by step to isolate the issue
        var result: Self = undefined;
        result.allocator = allocator;
        result.server_fd = -1;

        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Basic fields set", .{});

        // Initialize connection queue first (simpler)
        result.conn_queue = ConnectionQueue.init(allocator);
        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Connection queue created", .{});

        // Initialize arena allocator
        result.arena = std.heap.ArenaAllocator.init(allocator);
        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Arena allocator created", .{});

        // Initialize poller fd last (most likely to fail)
        result.poller_fd = switch (@import("builtin").target.os.tag) {
            .macos => try initKqueue(),
            .linux => try initEpoll(),
            else => return error.UnsupportedPlatform,
        };

        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Poller fd created: {}", .{result.poller_fd});
        if (builtin.mode == .Debug) std.log.debug("UltraPoller.init: Initialization completed successfully", .{});
        return result;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.conn_queue.deinit();
        _ = std.posix.close(self.poller_fd);
    }

    // macOS kqueue implementation
    fn initKqueue() !i32 {
        const kq = std.posix.system.kqueue();
        if (kq < 0) {
            std.log.err("kqueue() failed with fd: {}", .{kq});
            return error.KqueueCreateFailed;
        }
        if (builtin.mode == .Debug) std.log.debug("kqueue created with fd: {}", .{kq});
        return @intCast(kq);
    }

    // Linux epoll implementation
    fn initEpoll() !i32 {
        const epfd = std.posix.system.epoll_create1(std.posix.SOCK.CLOEXEC);
        if (epfd < 0) {
            std.log.err("epoll_create1() failed with fd: {}", .{epfd});
            return error.EpollCreateFailed;
        }
        if (builtin.mode == .Debug) std.log.debug("epoll created with fd: {}", .{epfd});
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
        if (result < 0) {
            std.log.err("kevent() add server failed: fd={}, result={}", .{ fd, result });
            return error.KqueueAddEventFailed;
        }
        if (builtin.mode == .Debug) std.log.debug("kqueue server fd {} added successfully", .{fd});
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
        if (result < 0) {
            std.log.err("epoll_ctl() add server failed: fd={}, result={}", .{ fd, result });
            return error.EpollAddEventFailed;
        }
        if (builtin.mode == .Debug) std.log.debug("epoll server fd {} added successfully", .{fd});
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

    // Multi-threaded event loop with single-threaded accept pattern
    pub fn multiThreadEventLoop(self: *Self, server: *std.net.Server, config: Config, shared_allocator: std.mem.Allocator) !void {
        // Use configured or optimal number of threads
        const num_threads = if (config.threads) |t|
            @max(1, t) // Ensure at least 1 thread
        else
            @min(std.Thread.getCpuCount() catch 4, 8); // Default: auto-detect, max 8 for safety
        std.log.info("Starting {} worker threads with queue-based architecture", .{num_threads});

        const threads = try shared_allocator.alloc(std.Thread, num_threads);
        defer shared_allocator.free(threads);

        var should_stop = std.atomic.Value(bool).init(false);

        // Start worker threads - they will process connections from queue
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, queueWorkerThread, .{ &self.conn_queue, config, shared_allocator, &should_stop });
        }

        // Main thread ONLY handles accept() - no competition!
        while (!should_stop.load(.monotonic)) {
            switch (@import("builtin").target.os.tag) {
                .macos => self.kqueueAcceptLoop(server) catch {},
                .linux => self.epollAcceptLoop(server) catch {},
                else => return error.UnsupportedPlatform,
            }
        }

        // Signal stop and wait for threads
        should_stop.store(true, .monotonic);
        self.conn_queue.condition.broadcast(); // Wake all waiting workers
        for (threads) |thread| {
            thread.join();
        }
    }

    // Accept-only loops for queue-based architecture
    fn kqueueAcceptLoop(self: *Self, server: *std.net.Server) !void {
        var eventlist: [1024]std.posix.system.Kevent = undefined;

        // Short timeout for responsiveness
        var timeout = std.posix.system.timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
        var changelist: [1]std.posix.system.Kevent = undefined;
        const num_events = std.posix.system.kevent(self.poller_fd, &changelist, 0, &eventlist, 1024, &timeout);

        if (num_events < 0) return error.KqueueWaitFailed;
        if (num_events == 0) return; // Timeout

        if (num_events > 0 and num_events <= 1024) {
            for (eventlist[0..@intCast(num_events)]) |event| {
                const fd: i32 = @intCast(event.ident);

                if (fd == self.server_fd) {
                    // Accept connections and queue them
                    self.acceptAndQueue(server) catch |err| {
                        if (builtin.mode == .Debug) std.log.debug("acceptAndQueue failed: {}", .{err});
                    };
                }
            }
        } else {
            if (builtin.mode == .Debug) std.log.debug("Invalid event count: {}", .{num_events});
        }
    }

    fn epollAcceptLoop(self: *Self, server: *std.net.Server) !void {
        var events: [1024]std.posix.system.epoll_event = undefined;

        // Short timeout for responsiveness
        const num_events = std.posix.system.epoll_wait(self.poller_fd, &events, 1024, 10); // 10ms

        if (num_events < 0) return error.EpollWaitFailed;
        if (num_events == 0) return; // Timeout

        if (num_events > 0 and num_events <= 1024) {
            for (events[0..@intCast(num_events)]) |event| {
                const fd = event.data.fd;

                if (fd == self.server_fd) {
                    // Accept connections and queue them
                    self.acceptAndQueue(server) catch |err| {
                        if (builtin.mode == .Debug) std.log.debug("acceptAndQueue failed: {}", .{err});
                    };
                }
            }
        } else {
            if (builtin.mode == .Debug) std.log.debug("Invalid event count: {}", .{num_events});
        }
    }

    // Accept connections and add to queue for workers
    fn acceptAndQueue(self: *Self, server: *std.net.Server) !void {
        // Accept multiple connections per event for better throughput
        var conn_count: u32 = 0;
        while (conn_count < 32) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => break, // No more connections
                error.ConnectionAborted, error.ConnectionResetByPeer => {
                    if (builtin.mode == .Debug) std.log.debug("Connection error during accept: {}", .{err});
                    continue;
                },
                else => {
                    std.log.err("Unexpected accept error: {}", .{err});
                    return err;
                },
            };
            conn_count += 1;

            // Set socket timeout for robust I/O
            self.setSocketTimeout(conn.stream.handle) catch {};

            // Add to queue for workers
            self.conn_queue.push(conn) catch |err| {
                // If queue is full, close connection
                conn.stream.close();
                if (builtin.mode != .ReleaseFast) {
                    std.log.err("Failed to queue connection: {}", .{err});
                }
            };
        }
    }

    // Set socket timeout for robust I/O
    fn setSocketTimeout(self: *Self, socket_fd: std.posix.socket_t) !void {
        _ = self; // suppress unused parameter warning

        const timeout = std.posix.timeval{
            .sec = 2, // 2 second timeout for faster error detection
            .usec = 0,
        };

        // Set receive timeout
        _ = std.posix.setsockopt(socket_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Set send timeout
        _ = std.posix.setsockopt(socket_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
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

        if (num_events > 0 and num_events <= 1024) {
            for (eventlist[0..@intCast(num_events)]) |event| {
                const fd: i32 = @intCast(event.ident);

                if (fd == self.server_fd) {
                    // Accept and immediately handle connections
                    self.handleAcceptAndProcess(server, config) catch |err| {
                        if (builtin.mode == .Debug) std.log.debug("handleAcceptAndProcess failed: {}", .{err});
                    };
                }
            }
        } else {
            if (builtin.mode == .Debug) std.log.debug("Invalid event count in kqueue loop: {}", .{num_events});
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

    // Accept + Process in single operation - optimized for throughput
    fn handleAcceptAndProcess(self: *Self, server: *std.net.Server, config: Config) !void {
        // Process up to 32 connections per event loop iteration for better throughput
        var conn_count: u32 = 0;
        while (conn_count < 32) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => break, // No more connections
                else => return err,
            };
            defer conn.stream.close();
            conn_count += 1;

            // Reset arena for this request - ULTRA FAST!
            _ = self.arena.reset(.free_all);
            const req_allocator = self.arena.allocator();

            // Single request per connection for maximum throughput - no keep-alive overhead
            _ = http.handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
                if (builtin.mode != .ReleaseFast) {
                    std.log.err("Error handling ultra request: {}", .{err});
                }
            };
        }
    }
};

// Queue-based worker thread - no accept() competition
fn queueWorkerThread(conn_queue: *ConnectionQueue, config: Config, shared_allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool)) void {

    // Pre-allocated Arena per worker - reuse via reset()
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
    defer arena.deinit();

    while (!should_stop.load(.monotonic)) {
        // Get connection from queue - blocks until available
        const conn = conn_queue.tryPop() orelse {
            // No connection available, brief sleep
            std.time.sleep(100_000); // 100μs for better responsiveness
            continue;
        };
        defer conn.stream.close();

        // Reset arena for this request - ULTRA FAST!
        _ = arena.reset(.free_all);
        const req_allocator = arena.allocator();

        // Handle request - no socket errors since connection is already established
        _ = http.handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
            if (builtin.mode != .ReleaseFast) {
                std.log.err("Error handling queue worker request: {}", .{err});
            }
        };
    }
}

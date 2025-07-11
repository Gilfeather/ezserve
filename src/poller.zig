const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

const Config = @import("lib.zig").Config;

// ULTRA POLLER - Zero overhead, maximum performance
pub const UltraPoller = struct {
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
                const keep_alive = http.handleRequest(conn.stream.reader(), conn.stream.writer(), conn.address, config, req_allocator) catch |err| {
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
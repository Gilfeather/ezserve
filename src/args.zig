const std = @import("std");
const lib = @import("lib.zig");

pub const Config = lib.Config;

pub fn printHelp() void {
    const help_text =
        \\ezserve - Ultra-lightweight HTTP static file server
        \\
        \\USAGE:
        \\    ezserve [OPTIONS]
        \\    ezserve dev [OPTIONS]    # Development mode with --cors --open --watch
        \\
        \\OPTIONS:
        \\    --port <number>     Port to listen on (default: 8000)
        \\    --bind <address>    Bind address (default: 127.0.0.1)
        \\    --root <path>       Root directory to serve (default: .)
        \\    --cors              Enable CORS headers
        \\    --single-page       SPA mode - fallback to index.html on 404
        \\    --no-dirlist        Disable directory listing
        \\    --log=json          Output access logs in JSON format
        \\    --threads <number>  Number of worker threads (default: auto, max 8)
        \\    --watch             File watching mode (TODO)
        \\    --open              Auto-open browser after server start
        \\    --help, -h          Show this help message
        \\
        \\EXAMPLES:
        \\    ezserve                              # Serve current directory on port 8000
        \\    ezserve --port 3000 --cors           # Development server with CORS
        \\    ezserve --bind 0.0.0.0 --port 80     # Production server on all interfaces
        \\    ezserve --single-page --no-dirlist   # SPA deployment mode
        \\    ezserve --root ./dist --log=json     # Serve build directory with JSON logs
        \\    ezserve --threads 16 --bind 0.0.0.0  # High-performance server with 16 threads
        \\    ezserve --open --cors --single-page  # Development mode with auto-open
        \\
        \\For more information, visit: https://github.com/tomas/ezserve
        \\
    ;
    std.log.info("{s}", .{help_text});
}

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    
    // Check for 'dev' subcommand
    var start_index: usize = 1;
    if (args.len > 1 and std.mem.eql(u8, args[1], "dev")) {
        // Enable development defaults
        config.cors = true;
        config.open = true;
        config.watch = true;
        start_index = 2;
        if (comptime @import("builtin").mode != .ReleaseSmall) {
            std.log.info("Development mode enabled: CORS + auto-open + file watching", .{});
        }
    }

    // Simple argument parsing
    var i: usize = start_index;
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
        } else if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
            config.threads = std.fmt.parseInt(u32, args[i+1], 10) catch {
                std.log.err("Invalid thread count: {s}", .{args[i+1]});
                std.log.err("Thread count must be a positive number", .{});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            config.watch = true;
        } else if (std.mem.eql(u8, args[i], "--open")) {
            config.open = true;
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
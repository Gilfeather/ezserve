const std = @import("std");

pub const Config = struct {
    port: u16 = 8000,
    root: []const u8 = ".",
    bind: []const u8 = "127.0.0.1",
    single_page: bool = false,
    cors: bool = false,
    no_dirlist: bool = false,
    log_json: bool = false,
    watch: bool = false,
    threads: ?u32 = null, // null = auto-detect, default max 8 for safety
    gzip: bool = false, // Enable gzip compression
    config_file: ?[]const u8 = null, // Configuration file path
};

pub const ResponseInfo = struct {
    status: u16,
    content_length: usize,
};

const MimeMap = std.StringHashMap([]const u8);

var mime_map: ?MimeMap = null;

pub fn initMimeMap() !MimeMap {
    var map = MimeMap.init(std.heap.page_allocator);
    try map.put(".html", "text/html");
    try map.put(".htm", "text/html");
    try map.put(".css", "text/css");
    try map.put(".js", "application/javascript");
    try map.put(".json", "application/json");
    try map.put(".png", "image/png");
    try map.put(".jpg", "image/jpeg");
    try map.put(".jpeg", "image/jpeg");
    try map.put(".gif", "image/gif");
    try map.put(".svg", "image/svg+xml");
    try map.put(".ico", "image/x-icon");
    try map.put(".txt", "text/plain");
    try map.put(".xml", "application/xml");
    try map.put(".pdf", "application/pdf");
    try map.put(".zip", "application/zip");
    try map.put(".wasm", "application/wasm");
    return map;
}

pub fn getMimeType(path: []const u8) []const u8 {
    if (mime_map == null) {
        mime_map = initMimeMap() catch {
            // Fallback to simple detection if HashMap fails
            if (std.mem.endsWith(u8, path, ".html")) return "text/html";
            if (std.mem.endsWith(u8, path, ".css")) return "text/css";
            if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
            return "application/octet-stream";
        };
    }

    // Find the last dot in the path
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot_index| {
        const ext = path[dot_index..];
        if (mime_map.?.get(ext)) |mime_type| {
            return mime_type;
        }
    }

    return "application/octet-stream";
}

// Load configuration from TOML file
pub fn loadConfigFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn("Configuration file not found: {s}", .{path});
            return Config{};
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    var config = Config{};
    
    // Simple TOML parser - parse key=value pairs
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue; // Skip empty lines and comments
        
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t\"'");
            
            if (std.mem.eql(u8, key, "port")) {
                config.port = std.fmt.parseInt(u16, value, 10) catch config.port;
            } else if (std.mem.eql(u8, key, "root")) {
                config.root = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "bind")) {
                config.bind = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "single_page")) {
                config.single_page = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "cors")) {
                config.cors = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "no_dirlist")) {
                config.no_dirlist = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "log_json")) {
                config.log_json = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "watch")) {
                config.watch = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "gzip")) {
                config.gzip = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "threads")) {
                config.threads = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
    }
    
    return config;
}

// Tests
const testing = std.testing;

test "getMimeType - common file extensions" {
    try testing.expectEqualStrings("text/html", getMimeType("index.html"));
    try testing.expectEqualStrings("text/html", getMimeType("/path/to/file.htm"));
    try testing.expectEqualStrings("text/css", getMimeType("style.css"));
    try testing.expectEqualStrings("application/javascript", getMimeType("script.js"));
    try testing.expectEqualStrings("application/json", getMimeType("data.json"));
    try testing.expectEqualStrings("image/png", getMimeType("image.png"));
    try testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpg"));
    try testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpeg"));
    try testing.expectEqualStrings("image/gif", getMimeType("animation.gif"));
    try testing.expectEqualStrings("image/svg+xml", getMimeType("icon.svg"));
    try testing.expectEqualStrings("image/x-icon", getMimeType("favicon.ico"));
    try testing.expectEqualStrings("text/plain", getMimeType("readme.txt"));
    try testing.expectEqualStrings("application/xml", getMimeType("config.xml"));
    try testing.expectEqualStrings("application/pdf", getMimeType("document.pdf"));
    try testing.expectEqualStrings("application/zip", getMimeType("archive.zip"));
    try testing.expectEqualStrings("application/wasm", getMimeType("module.wasm"));
}

test "getMimeType - unknown extensions" {
    try testing.expectEqualStrings("application/octet-stream", getMimeType("file.unknown"));
    try testing.expectEqualStrings("application/octet-stream", getMimeType("file"));
    try testing.expectEqualStrings("application/octet-stream", getMimeType(""));
}

test "getMimeType - case sensitivity" {
    try testing.expectEqualStrings("application/octet-stream", getMimeType("file.HTML"));
    try testing.expectEqualStrings("application/octet-stream", getMimeType("style.CSS"));
}

test "getMimeType - complex paths" {
    try testing.expectEqualStrings("text/html", getMimeType("/usr/local/www/index.html"));
    try testing.expectEqualStrings("application/javascript", getMimeType("./assets/js/app.js"));
    try testing.expectEqualStrings("text/css", getMimeType("../styles/main.css"));
}

test "Config - default values" {
    const config = Config{};
    try testing.expect(config.port == 8000);
    try testing.expectEqualStrings(".", config.root);
    try testing.expectEqualStrings("127.0.0.1", config.bind);
    try testing.expect(config.single_page == false);
    try testing.expect(config.cors == false);
    try testing.expect(config.no_dirlist == false);
    try testing.expect(config.log_json == false);
    try testing.expect(config.watch == false);
    try testing.expect(config.gzip == false);
    try testing.expect(config.config_file == null);
}

test "Config - custom values" {
    const config = Config{
        .port = 3000,
        .root = "./public",
        .bind = "0.0.0.0",
        .single_page = true,
        .cors = true,
        .no_dirlist = true,
        .log_json = true,
        .watch = true,
        .gzip = true,
    };
    try testing.expect(config.port == 3000);
    try testing.expectEqualStrings("./public", config.root);
    try testing.expectEqualStrings("0.0.0.0", config.bind);
    try testing.expect(config.single_page == true);
    try testing.expect(config.cors == true);
    try testing.expect(config.no_dirlist == true);
    try testing.expect(config.log_json == true);
    try testing.expect(config.watch == true);
    try testing.expect(config.gzip == true);
}

test "ResponseInfo - structure" {
    const response = ResponseInfo{
        .status = 200,
        .content_length = 1024,
    };
    try testing.expect(response.status == 200);
    try testing.expect(response.content_length == 1024);
}

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
    open: bool = false, // Browser auto-open
};

pub const ResponseInfo = struct {
    status: u16,
    content_length: usize,
};

// Compact MIME type mapping for smaller binary size
const MimeEntry = struct { ext: []const u8, mime: []const u8 };

const mime_types = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html" },
    .{ .ext = ".htm", .mime = "text/html" },
    .{ .ext = ".css", .mime = "text/css" },
    .{ .ext = ".js", .mime = "application/javascript" },
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".txt", .mime = "text/plain" },
    .{ .ext = ".xml", .mime = "application/xml" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".wasm", .mime = "application/wasm" },
};

pub fn getMimeType(path: []const u8) []const u8 {
    // Find file extension
    const dot_index = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot_index..];
    
    // Linear search through compact array (faster for small arrays)
    for (mime_types) |entry| {
        if (std.mem.eql(u8, ext, entry.ext)) {
            return entry.mime;
        }
    }
    
    return "application/octet-stream";
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
    };
    try testing.expect(config.port == 3000);
    try testing.expectEqualStrings("./public", config.root);
    try testing.expectEqualStrings("0.0.0.0", config.bind);
    try testing.expect(config.single_page == true);
    try testing.expect(config.cors == true);
    try testing.expect(config.no_dirlist == true);
    try testing.expect(config.log_json == true);
    try testing.expect(config.watch == true);
}

test "ResponseInfo - structure" {
    const response = ResponseInfo{
        .status = 200,
        .content_length = 1024,
    };
    try testing.expect(response.status == 200);
    try testing.expect(response.content_length == 1024);
}
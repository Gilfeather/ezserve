const std = @import("std");
const builtin = @import("builtin");

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    last_check: i128,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .root_path = root_path,
            .last_check = std.time.nanoTimestamp(),
        };
    }
    
    pub fn checkForChanges(self: *Self) !bool {
        const current_time = std.time.nanoTimestamp();
        defer self.last_check = current_time;
        
        return self.checkDirectoryChanges(self.root_path, self.last_check);
    }
    
    fn checkDirectoryChanges(self: *Self, path: []const u8, since: i128) !bool {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{path, entry.name});
                defer self.allocator.free(subdir_path);
                
                if (try self.checkDirectoryChanges(subdir_path, since)) {
                    return true;
                }
            } else if (entry.kind == .file) {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{path, entry.name});
                defer self.allocator.free(file_path);
                
                const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
                defer file.close();
                
                const stat = file.stat() catch continue;
                
                // Check if file was modified after last check
                if (stat.mtime > since) {
                    std.log.info("File changed: {s}", .{file_path});
                    return true;
                }
            }
        }
        
        return false;
    }
    
    pub fn watchLoop(self: *Self, should_stop: *std.atomic.Value(bool)) void {
        while (!should_stop.load(.monotonic)) {
            const changed = self.checkForChanges() catch false;
            if (changed) {
                std.log.info("Files changed - consider restarting server", .{});
            }
            
            // Check every 1 second
            std.time.sleep(1_000_000_000);
        }
    }
};
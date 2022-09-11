const std = @import("std");
const Async = @import("thread_pool_async.zig");

const supported_extensions = std.ComptimeStringMap(void, .{
    .{".ts"},
    .{".tsx"},
    .{".js"},
    .{".jsx"},
});

pub fn main() !void {
    try Async.run(asyncMain, .{});
}

pub fn asyncMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());

    std.debug.print("running depchecker\n", .{});

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    const root_dir = args[1];
    const src_dir = args[2];
    defer std.process.argsFree(allocator, args);

    var cwd = try std.fs.openDirAbsolute(root_dir, .{});
    defer cwd.close();

    const package_json = try cwd.openFile("package.json", .{});
    defer package_json.close();

    const reader = package_json.reader();
    const contents = try reader.readAllAlloc(allocator, 1_000_000);
    defer allocator.free(contents);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    var json = try parser.parse(contents);
    defer json.deinit();

    var dependency_map = std.StringHashMap(u16).init(Async.allocator);
    defer dependency_map.deinit();

    const maybe_dependencies = json.root.Object.get("dependencies");
    if (maybe_dependencies) |dependencies| {
        const dependency_names = dependencies.Object.keys();
        for (dependency_names) |name| {
            try dependency_map.put(name, 0);
        }
    }

    const maybe_dev_dependencies = json.root.Object.get("devDependencies");
    if (maybe_dev_dependencies) |dependencies_development| {
        const dependency_dev_names = dependencies_development.Object.keys();
        for (dependency_dev_names) |name| {
            try dependency_map.put(name, 0);
        }
    }

    const directory = try std.fs.openIterableDirAbsolute(src_dir, .{});
    std.debug.print("src_dir opened {s}\n", .{src_dir});

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var tasks = std.ArrayList(Async.JoinHandle(Async.ReturnTypeOf(analyzeFile))).init(allocator);
    defer tasks.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.File) {
            continue;
        }

        // TODO - provide ignore patterns CLI property
        // TODO - add some logic for ignoring mega-long source-mappings in lines (buffer overflow)
        if (std.mem.indexOf(u8, entry.path, "/dist/") != null) {
            continue;
        }
        if (std.mem.indexOf(u8, entry.path, "/__compiled__/") != null) {
            continue;
        }

        var extension_start = std.mem.lastIndexOf(u8, entry.basename, ".") orelse 0;
        var extension = entry.basename[extension_start..];

        if (supported_extensions.has(extension)) {
            var entry_path_full = try std.fmt.allocPrint(Async.allocator, "{s}/{s}", .{ src_dir, entry.path });

            var frame = Async.spawn(analyzeFile, .{entry_path_full, &dependency_map});
            try tasks.append(frame);
        }
    }

    const task_handles = tasks.toOwnedSlice();
    defer allocator.free(task_handles);

    for (task_handles) |*handle| {
        try handle.join();
    }

    var map_iterator = dependency_map.iterator();
    var stdout = std.io.getStdOut().writer();

    while (map_iterator.next()) |entry| {
        var key = entry.key_ptr.*;
        var value = entry.value_ptr.*;

        if (value == 0) {
            try stdout.print("dependency unused: {s}\n", .{key});
        } else {
            try stdout.print("dependency used: {s}\n", .{key});
        }
    }
}

const import_symbol = "from ";
const other_symbols = std.ComptimeStringMap(void, .{
    .{"export"},
    .{"const"},
    .{"type"},
    .{"interface"},
    .{"function"},
});
const trim_left_symbols: []const u8 = "\"'";
const trim_right_symbols: []const u8 = "\"';";

fn analyzeFile(file_path: []const u8, map: *std.StringHashMap(u16)) !void {
    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var buffered_stream = buffered_reader.reader();

    var buffered_line: [8192]u8 = undefined;

    while (try buffered_stream.readUntilDelimiterOrEof(&buffered_line, '\n')) |line| {
        if (std.mem.indexOf(u8, line, import_symbol) != null) {
            var tokens = std.mem.split(u8, line, "from ");
            _ = tokens.first();

            var import = tokens.rest();

            import = std.mem.trimLeft(u8, import, trim_left_symbols);
            import = std.mem.trimRight(u8, import, trim_right_symbols);

            var count = map.get(import);
            if (count) |value| {
                _ = try map.put(import, value + 1);
            }
        }
    }
}

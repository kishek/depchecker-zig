const std = @import("std");
    
const supported_extensions = std.ComptimeStringMap(void, .{
    .{".ts"},
    .{".tsx"},
    .{".js"},
    .{".jsx"},
});

pub fn main() !void {
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

    var dependency_map = std.StringHashMap(u16).init(allocator);
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

    var tasks = std.ArrayList(@Frame(analyzeFile)).init(allocator);
    defer tasks.deinit();

    var loop: std.event.Loop = undefined;
    try loop.initMultiThreaded();
    defer loop.deinit();

    loop.run();

    while (try walker.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.File) {
            continue;
        }

        var extension_start = std.mem.lastIndexOf(u8, entry.basename, ".");
        if (extension_start) |start| {
            var extension = entry.basename[start..];

            if (supported_extensions.has(extension)) {
                var frame = async analyzeFile(directory.dir, entry.path, &dependency_map);
                try tasks.append(frame);
            }
        }
    }

    const task_handles = tasks.toOwnedSlice();
    defer allocator.free(task_handles);
    
    for (task_handles) |*handle| {
        try await handle;
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

const import_symbol: []const u8 = "from ";
const other_symbols = std.ComptimeStringMap(void, .{
    .{"export"},
    .{"const"},
    .{"type"},
    .{"interface"},
    .{"function"},
});

fn analyzeFile(src_dir: std.fs.Dir, file_path: []const u8, map: *std.StringHashMap(u16)) !void {
    const file = try src_dir.openFile(file_path, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var buffered_stream = buffered_reader.reader();

    var buffered_line: [1024]u8 = undefined;

    while (try buffered_stream.readUntilDelimiterOrEof(&buffered_line, '\n')) |line| {
        var import_start = std.mem.indexOf(u8, line, import_symbol);
        if (import_start) |start| {
            var import_start_at = start + 5;
            var import_end_at = import_start_at;
            
            if (import_start_at == line.len or (line[import_start_at] != '\'' and line[import_start_at] != '"')) {
                continue;
            }
            
            
            var found = false;
            while (import_end_at != line.len - 1) {
                import_end_at += 1;
                if (line[import_end_at] == '\'' or line[import_end_at] == '"') {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                continue;
            }

            const import_name = line[import_start_at + 1..import_end_at];

            var count = map.get(import_name);
            if (count) |value| {
                _ = try map.put(import_name, value + 1);
            }
        }
    }
}
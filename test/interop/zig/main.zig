const std = @import("std");
const xitdb = @import("xitdb");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const kinds = [_]xitdb.Tag{ .array_list, .linked_array_list, .hash_map, .hash_set, .counted_hash_map, .counted_hash_set, .sorted_map, .sorted_set };

fn field(value: Value, name: []const u8) !Value {
    return value.object.get(name) orelse error.MissingField;
}

fn string(value: Value, name: []const u8) ![]const u8 {
    return (try field(value, name)).string;
}

fn object(allocator: Allocator, fields: []const struct { []const u8, Value }) !Value {
    var result: std.json.ObjectMap = .empty;
    for (fields) |entry| try result.put(allocator, entry[0], entry[1]);
    return .{ .object = result };
}

fn hex(allocator: Allocator, bytes: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        result[i * 2] = digits[byte >> 4];
        result[i * 2 + 1] = digits[byte & 15];
    }
    return result;
}

fn unhex(allocator: Allocator, text: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, text.len / 2);
    return try std.fmt.hexToBytes(result, text);
}

fn Adapter(comptime HashInt: type) type {
    return struct {
        const Self = @This();
        const DB = xitdb.Database(.file, HashInt);
        allocator: Allocator,
        io: std.Io,
        request: Value,
        iteration: *std.json.Array,

        fn scalar(self: Self, value: Value) !DB.WriteableData {
            if (value.object.get("hex")) |bytes| {
                const tag = try field(value, "format_tag");
                var format: ?[2]u8 = null;
                if (tag != .null) {
                    const decoded = try unhex(self.allocator, tag.string);
                    format = decoded[0..2].*;
                }
                return .{ .bytes_object = .{ .value = try unhex(self.allocator, bytes.string), .format_tag = format } };
            }
            const tag = std.meta.stringToEnum(xitdb.Tag, try string(value, "tag")) orelse return error.UnknownTag;
            const bits = try std.fmt.parseInt(u64, try string(value, "bits"), 10);
            return switch (tag) {
                .uint => .{ .uint = bits },
                .int => .{ .int = @bitCast(bits) },
                else => .{ .slot = .{ .tag = tag, .value = bits, .full = (try field(value, "full")).bool } },
            };
        }

        fn tree(self: Self, cursor: DB.Cursor(.read_only)) anyerror!Value {
            const slot = try cursor.slot();
            const name = @tagName(slot.tag);
            if (std.mem.findScalar(xitdb.Tag, &kinds, slot.tag) == null) {
                if (slot.tag == .bytes or slot.tag == .short_bytes) {
                    const bytes = try cursor.readBytesObjectAlloc(self.allocator, null);
                    return object(self.allocator, &.{
                        .{ "tag", .{ .string = name } },                                 .{ "full", .{ .bool = slot.full } },
                        .{ "hex", .{ .string = try hex(self.allocator, bytes.value) } }, .{ "format_tag", if (bytes.format_tag) |tag| .{ .string = try hex(self.allocator, &tag) } else .null },
                    });
                }
                return object(self.allocator, &.{
                    .{ "tag", .{ .string = name } },                                                          .{ "full", .{ .bool = slot.full } },
                    .{ "bits", .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{slot.value}) } },
                });
            }
            var items = std.json.Array.init(self.allocator);
            if (slot.tag == .array_list or slot.tag == .linked_array_list) {
                var iter = try cursor.iterator();
                var returned: i64 = 0;
                while (try iter.next() != null) returned += 1;
                try self.iteration.append(.{ .integer = returned });
                for (0..try cursor.count()) |i| {
                    const path: DB.PathPart(void) = if (slot.tag == .array_list) .{ .array_list_get = i } else .{ .linked_array_list_get = i };
                    const child = try cursor.readPath(void, &.{path});
                    try items.append(if (child) |c| try self.tree(c) else try object(self.allocator, &.{
                        .{ "tag", .{ .string = "none" } }, .{ "full", .{ .bool = false } }, .{ "bits", .{ .string = "0" } },
                    }));
                }
                return object(self.allocator, &.{ .{ "tag", .{ .string = name } }, .{ "items", .{ .array = items } } });
            }
            var iterator = try cursor.iterator();
            while (try iterator.next()) |child| {
                var entry = std.json.Array.init(self.allocator);
                if (slot.tag == .sorted_set) {
                    try entry.append(.{ .string = try hex(self.allocator, try child.readBytesAlloc(self.allocator, null)) });
                    try entry.append(.null);
                } else {
                    const pair = try child.readKeyValuePair();
                    try entry.append(.{ .string = try hex(self.allocator, try pair.key_cursor.readBytesAlloc(self.allocator, null)) });
                    try entry.append(if (slot.tag == .hash_set or slot.tag == .counted_hash_set) .null else try self.tree(pair.value_cursor));
                }
                try items.append(.{ .array = entry });
            }
            std.mem.sort(Value, items.items, {}, struct {
                fn less(_: void, a: Value, b: Value) bool {
                    return std.mem.order(u8, a.array.items[0].string, b.array.items[0].string) == .lt;
                }
            }.less);
            return object(self.allocator, &.{ .{ "tag", .{ .string = name } }, .{ "items", .{ .array = items } } });
        }

        pub fn run(self: Self, cursor: *DB.Cursor(.read_write)) !void {
            const list = try DB.ArrayList(.read_write).init(cursor.*);
            for ((try field(self.request, "scalars")).array.items) |value| try list.append(try self.scalar(value));
            inline for (kinds) |kind| {
                for ([_]usize{ 0, 17 }) |count| {
                    const child = try list.appendCursor();
                    const Collection = switch (kind) {
                        .array_list => DB.ArrayList(.read_write),
                        .linked_array_list => DB.LinkedArrayList(.read_write),
                        .hash_map => DB.HashMap(.read_write),
                        .hash_set => DB.HashSet(.read_write),
                        .counted_hash_map => DB.CountedHashMap(.read_write),
                        .counted_hash_set => DB.CountedHashSet(.read_write),
                        .sorted_map => DB.SortedMap(.read_write),
                        .sorted_set => DB.SortedSet(.read_write),
                        else => unreachable,
                    };
                    const collection = try Collection.init(child);
                    for (0..count) |i| {
                        const key = try std.fmt.allocPrint(self.allocator, "k{d:0>2}", .{i});
                        if (kind == .array_list or kind == .linked_array_list) {
                            if (i == 0) {
                                const appended = try collection.appendCursor();
                                if (!(try appended.slot()).empty()) return error.UnexpectedAppendOccupancy;
                            } else if (i == 1) {
                                try collection.append(.{ .slot = .{ .tag = .none, .value = 0, .full = false } });
                            } else try collection.append(.{ .uint = i });
                        } else if (kind == .sorted_map) {
                            try collection.put(key, .{ .uint = i });
                        } else if (kind == .sorted_set) {
                            try collection.put(key);
                        } else {
                            const Hash = switch (@bitSizeOf(HashInt)) {
                                160 => std.crypto.hash.Sha1,
                                256 => std.crypto.hash.sha2.Sha256,
                                384 => std.crypto.hash.sha2.Sha384,
                                else => unreachable,
                            };
                            var digest: [@bitSizeOf(HashInt) / 8]u8 = undefined;
                            Hash.hash(key, &digest, .{});
                            const hash = std.mem.readInt(HashInt, &digest, .big);
                            if (kind == .hash_set or kind == .counted_hash_set) {
                                try collection.put(hash, .{ .bytes = key });
                            } else {
                                try collection.putKey(hash, .{ .bytes = key });
                                try collection.put(hash, .{ .uint = i });
                            }
                        }
                    }
                }
            }
        }

        fn execute(self: Self) !Value {
            const path = try string(self.request, "path");
            const operation = try string(self.request, "operation");
            const write = std.mem.eql(u8, operation, "write");
            const file = if (write) try std.Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .exclusive = true }) else try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const hash_name = try string(try field(self.request, "hash"), "id");
            var db = try DB.init(self.io, .{ .file = file, .hash_id = xitdb.HashId.fromBytes(hash_name[0..4]), .file_id = 1 });
            if (write) {
                const history = try DB.ArrayList(.read_write).init(db.rootCursor());
                try history.append(.{ .uint = 7 });
                const first = try db.committedSize();
                try history.appendContext(.{ .slot = null }, self);
                for ([_][]const u8{ "base", "delta" }, 0..) |suffix, i| {
                    var output = std.Io.Writer.Allocating.init(self.allocator);
                    try db.readCommitted(if (i == 0) 0 else first, if (i == 0) first else try db.committedSize(), &output.writer);
                    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, suffix }), .data = output.written() });
                }
            }
            if (write or std.mem.eql(u8, operation, "read")) {
                const result = try self.tree(db.rootCursor().readOnly());
                return object(self.allocator, &.{ .{ "tree", result }, .{ "iteration", .{ .array = self.iteration.* } } });
            }
            if (std.mem.eql(u8, operation, "compact")) {
                const target = try std.Io.Dir.cwd().createFile(self.io, try std.fmt.allocPrint(self.allocator, "{s}.compact", .{path}), .{ .read = true, .exclusive = true });
                defer target.close(self.io);
                var offsets = std.AutoHashMap(u64, u64).init(self.allocator);
                defer offsets.deinit();
                var compacted = try db.compact(.file, .{ .file = target }, &offsets);
                return object(self.allocator, &.{.{ "size", .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{try compacted.committedSize()}) } }});
            }
            if (std.mem.eql(u8, operation, "replicate")) {
                const target = try std.Io.Dir.cwd().createFile(self.io, try std.fmt.allocPrint(self.allocator, "{s}.replica", .{path}), .{ .read = true, .exclusive = true });
                defer target.close(self.io);
                var replica = try DB.init(self.io, .{ .file = target, .hash_id = db.header.hash_id });
                const base = try std.Io.Dir.cwd().readFileAlloc(self.io, try std.fmt.allocPrint(self.allocator, "{s}.base", .{path}), self.allocator, .unlimited);
                const delta = try std.Io.Dir.cwd().readFileAlloc(self.io, try std.fmt.allocPrint(self.allocator, "{s}.delta", .{path}), self.allocator, .unlimited);
                var reader = std.Io.Reader.fixed(base);
                try replica.applyReplicated(0, &reader, base.len);
                const before = try replica.replicaState();
                if (try db.replicationStart(before) != base.len) return error.InvalidPrefix;
                var truncated = std.Io.Reader.fixed(delta[0 .. delta.len / 2]);
                var rejected = false;
                replica.applyReplicated(base.len, &truncated, delta.len) catch |err| switch (err) {
                    error.EndOfStream => rejected = true,
                    else => return err,
                };
                const after = try replica.replicaState();
                if (!rejected or before.committed_size != after.committed_size or before.checksum != after.checksum) return error.InterruptedReplicaPublished;
                var complete = std.Io.Reader.fixed(delta);
                try replica.applyReplicated(base.len, &complete, delta.len);
                for ([_][]const u8{ "base", "delta" }, 0..) |suffix, i| {
                    var output = std.Io.Writer.Allocating.init(self.allocator);
                    try db.readCommitted(if (i == 0) 0 else base.len, if (i == 0) base.len else try db.committedSize(), &output.writer);
                    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try std.fmt.allocPrint(self.allocator, "{s}.reference.{s}", .{ path, suffix }), .data = output.written() });
                }
                return object(self.allocator, &.{.{ "interrupted", .{ .bool = rejected } }});
            }
            return error.UnsupportedOperation;
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    const bytes = try input.interface.allocRemaining(allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{});
    const request = parsed.value;
    if (!std.mem.eql(u8, try string(request, "case"), "all-kinds")) return error.UnsupportedCase;
    const hash = try field(request, "hash");
    const size = (try field(hash, "size")).integer;
    const hash_id = try string(hash, "id");
    if (!(size == 20 and std.mem.eql(u8, hash_id, "sha1") or size == 32 and std.mem.eql(u8, hash_id, "rb01") or size == 48 and std.mem.eql(u8, hash_id, "s384"))) return error.UnsupportedHash;
    var iteration = std.json.Array.init(allocator);
    const result = if (size == 20) try (Adapter(u160){ .allocator = allocator, .io = init.io, .request = request, .iteration = &iteration }).execute() else if (size == 32) try (Adapter(u256){ .allocator = allocator, .io = init.io, .request = request, .iteration = &iteration }).execute() else try (Adapter(u384){ .allocator = allocator, .io = init.io, .request = request, .iteration = &iteration }).execute();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try std.json.Stringify.value(result, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

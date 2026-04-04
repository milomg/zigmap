const std = @import("std");
const rank_tree2 = @import("rank_select/rank_select_tree2.zig");

pub fn QfMetaTreeRunEndHashMap(comptime K: type, comptime V: type) type {
    const Context = std.hash_map.AutoContext(K);
    const hashFn = std.hash_map.getAutoHashFn(K, Context);
    const eqlFn = std.hash_map.getAutoEqlFn(K, Context);

    return struct {
        allocator: std.mem.Allocator,
        ctx: Context,
        entries: []Entry,
        tags: []u8,
        meta: rank_tree2.RankSelectTree2,
        cap: usize,
        slots_len: usize,
        len: usize,

        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
        };
        const max_load_num = 7;
        const max_load_den = 8;
        const min_overflow_slots = 64;
        const max_overflow_slots = 255;

        pub fn initCapacity(allocator: std.mem.Allocator, expected_items: usize) !Self {
            var self = Self{
                .allocator = allocator,
                .ctx = .{},
                .entries = &.{},
                .tags = &.{},
                .meta = undefined,
                .cap = 0,
                .slots_len = 0,
                .len = 0,
            };
            try self.ensureCapacity(expected_items);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.cap == 0) return;
            self.allocator.free(self.entries);
            self.allocator.free(self.tags);
            self.meta.deinit();
            self.* = .{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .entries = &.{},
                .tags = &.{},
                .meta = undefined,
                .cap = 0,
                .slots_len = 0,
                .len = 0,
            };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = self.findIndex(key) orelse return null;
            return self.entries[idx].value;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            while (true) {
                try self.ensureCapacity(self.len + 1);
                if (self.putAssumeCapacity(key, value)) return;

                const next_cap = if (self.cap == 0) 64 else self.cap * 2;
                try self.growTo(next_cap);
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.len == 0) return false;

            const hash = self.hashKey(key);
            const home = self.bucketFromHash(hash);
            if (!self.isOccupied(home)) return false;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return false;
            const run_end = self.findRunEnd(run_start);

            var idx = run_start;
            while (idx <= run_end) : (idx += 1) {
                if (self.tags[idx] == tag and self.eql(self.entries[idx].key, key)) {
                    const single = run_start == run_end;
                    if (single) {
                        self.setOccupied(home, false);
                    }

                    if (idx == run_end) {
                        self.setRunEnd(run_end, false);
                        if (!single) {
                            self.setRunEnd(run_end - 1, true);
                        }
                    }

                    var stop = idx + 1;
                    while (stop < self.slots_len and self.isSlotOccupied(stop) and self.homeForIndex(stop) != stop) {
                        stop += 1;
                    }

                    if (stop > idx + 1) {
                        const moved = stop - idx - 1;
                        @memmove(self.entries[idx .. idx + moved], self.entries[idx + 1 .. idx + 1 + moved]);
                        @memmove(self.tags[idx .. idx + moved], self.tags[idx + 1 .. idx + 1 + moved]);

                        self.meta.shiftBitsBLeft(idx + 1, stop - 1);
                    }

                    const clear_idx = stop - 1;
                    self.tags[clear_idx] = 0;
                    self.setRunEnd(clear_idx, false);
                    self.len -= 1;
                    return true;
                }
            }

            return false;
        }

        fn ensureCapacity(self: *Self, min_items: usize) !void {
            if (self.cap > 0 and min_items <= maxLoad(self.cap)) return;

            var new_cap: usize = if (self.cap == 0) 64 else self.cap;
            while (min_items > maxLoad(new_cap)) new_cap *= 2;
            try self.growTo(new_cap);
        }

        fn maxLoad(cap: usize) usize {
            return cap * max_load_num / max_load_den;
        }

        fn overflowSlots(cap: usize) usize {
            const bits = @bitSizeOf(usize);
            const lg = bits - 1 - @clz(cap);
            const target = lg * 8;

            var overflow: usize = min_overflow_slots;
            while (overflow < target and overflow < max_overflow_slots) {
                overflow *= 2;
            }
            return @min(overflow, max_overflow_slots);
        }

        fn growTo(self: *Self, new_cap: usize) !void {
            const new_slots_len = new_cap + overflowSlots(new_cap);
            var new_map = Self{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .entries = try self.allocator.alloc(Entry, new_slots_len),
                .tags = try self.allocator.alloc(u8, new_slots_len),
                .meta = try rank_tree2.RankSelectTree2.init(self.allocator, new_slots_len),
                .cap = new_cap,
                .slots_len = new_slots_len,
                .len = 0,
            };
            errdefer {
                self.allocator.free(new_map.entries);
                self.allocator.free(new_map.tags);
                new_map.meta.deinit();
            }
            @memset(new_map.tags, 0);

            if (self.cap > 0) {
                for (0..self.slots_len) |i| {
                    if (!self.isSlotOccupied(i)) continue;
                    const entry = self.entries[i];
                    std.debug.assert(new_map.putAssumeCapacity(entry.key, entry.value));
                }

                self.allocator.free(self.entries);
                self.allocator.free(self.tags);
                self.meta.deinit();
            }

            self.* = new_map;
        }

        fn hashKey(self: *const Self, key: K) u64 {
            return hashFn(self.ctx, key);
        }

        fn eql(self: *const Self, a: K, b: K) bool {
            return eqlFn(self.ctx, a, b);
        }

        fn bucketFromHash(self: *const Self, hash: u64) usize {
            return @as(usize, @truncate(hash)) & (self.cap - 1);
        }

        fn tagFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        fn isSlotOccupied(self: *const Self, idx: usize) bool {
            return self.tags[idx] != 0;
        }

        fn isOccupied(self: *const Self, idx: usize) bool {
            return self.meta.testBitA(idx);
        }

        fn setOccupied(self: *Self, idx: usize, value: bool) void {
            self.meta.setBitA(idx, value);
        }

        fn isRunEnd(self: *const Self, idx: usize) bool {
            return self.meta.testBitB(idx);
        }

        fn setRunEnd(self: *Self, idx: usize, value: bool) void {
            self.meta.setBitB(idx, value);
        }

        fn homeForIndex(self: *const Self, idx: usize) usize {
            const run_index = self.meta.rankB(idx);
            return self.meta.selectA(run_index) orelse unreachable;
        }

        fn findEmptyFrom(self: *const Self, start: usize) ?usize {
            var idx = start;
            while (idx < self.slots_len and self.isSlotOccupied(idx)) : (idx += 1) {}
            if (idx == self.slots_len) return null;
            return idx;
        }

        fn findClusterStart(self: *const Self, home: usize) usize {
            var idx = home;
            while (idx > 0 and self.isSlotOccupied(idx - 1)) {
                idx -= 1;
            }
            return idx;
        }

        fn nextRunStart(self: *const Self, run_start: usize) usize {
            var idx = run_start;
            while (!self.isRunEnd(idx)) {
                idx += 1;
            }
            return idx + 1;
        }

        fn findRunEnd(self: *const Self, run_start: usize) usize {
            var idx = run_start;
            while (!self.isRunEnd(idx)) {
                idx += 1;
            }
            return idx;
        }

        fn findRunStart(self: *const Self, home: usize) ?usize {
            if (!self.isOccupied(home)) return null;

            const cluster_start = self.findClusterStart(home);
            var run_start = cluster_start;
            var idx = cluster_start;
            while (idx < home) : (idx += 1) {
                if (self.isOccupied(idx)) {
                    run_start = self.nextRunStart(run_start);
                }
            }
            return run_start;
        }

        fn findRunStartForInsert(self: *const Self, home: usize) usize {
            const cluster_start = self.findClusterStart(home);
            var run_start = cluster_start;
            var idx = cluster_start;
            while (idx < home) : (idx += 1) {
                if (self.isOccupied(idx)) {
                    run_start = self.nextRunStart(run_start);
                }
            }
            return run_start;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const hash = self.hashKey(key);
            const home = self.bucketFromHash(hash);
            if (!self.isOccupied(home)) return null;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return null;
            const run_end = self.findRunEnd(run_start);

            var idx = run_start;
            while (idx <= run_end) : (idx += 1) {
                if (self.tags[idx] == tag and self.eql(self.entries[idx].key, key)) return idx;
            }

            return null;
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) bool {
            const hash = self.hashKey(key);
            const home = self.bucketFromHash(hash);
            const tag = tagFromHash(hash);

            if (!self.isSlotOccupied(home)) {
                self.entries[home] = .{ .key = key, .value = value };
                self.tags[home] = tag;
                self.setOccupied(home, true);
                self.setRunEnd(home, true);
                self.len += 1;
                return true;
            }

            var insert_pos: usize = undefined;
            var insert_disp: usize = undefined;

            if (self.isOccupied(home)) {
                const run_start = self.findRunStart(home) orelse return false;
                const run_end = self.findRunEnd(run_start);

                var idx = run_start;
                while (idx <= run_end) : (idx += 1) {
                    if (self.tags[idx] == tag and self.eql(self.entries[idx].key, key)) {
                        self.entries[idx].value = value;
                        return true;
                    }
                }

                insert_pos = run_end + 1;
            } else {
                insert_pos = self.findRunStartForInsert(home);
            }

            insert_disp = insert_pos - home;

            if (insert_disp > max_overflow_slots) return false;
            const empty = self.findEmptyFrom(insert_pos) orelse return false;
            if (empty - home > max_overflow_slots) return false;

            if (empty > insert_pos) {
                const moved = empty - insert_pos;
                @memmove(
                    self.entries[insert_pos + 1 .. insert_pos + 1 + moved],
                    self.entries[insert_pos .. insert_pos + moved],
                );
                @memmove(
                    self.tags[insert_pos + 1 .. insert_pos + 1 + moved],
                    self.tags[insert_pos .. insert_pos + moved],
                );

                self.meta.shiftBitsBRight(insert_pos, empty - 1);
            }

            self.entries[insert_pos] = .{ .key = key, .value = value };
            self.tags[insert_pos] = tag;

            if (self.isOccupied(home)) {
                self.setRunEnd(insert_pos - 1, false);
            } else {
                self.setOccupied(home, true);
            }
            self.setRunEnd(insert_pos, true);
            self.len += 1;
            return true;
        }
    };
}

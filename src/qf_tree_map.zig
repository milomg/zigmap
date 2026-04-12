const std = @import("std");
const rank_tree2 = @import("rank_select/rank_select_tree2.zig");

pub fn QfTreeHashMap(comptime K: type, comptime V: type) type {
    const Context = std.hash_map.AutoContext(K);
    const hashFn = std.hash_map.getAutoHashFn(K, Context);
    const eqlFn = std.hash_map.getAutoEqlFn(K, Context);

    return struct {
        ctx: Context,
        entries: []Entry,
        tags: []u8,
        occupied: rank_tree2.RankSelectTree,
        run_end: rank_tree2.RankSelectTree,
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
        const tag_scan_chunk = @max(std.simd.suggestVectorLength(u8) orelse 1, @sizeOf(usize));

        pub const empty: Self = .{
            .ctx = .{},
            .entries = &.{},
            .tags = &.{},
            .occupied = undefined,
            .run_end = undefined,
            .cap = 0,
            .slots_len = 0,
            .len = 0,
        };

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, expected_items: usize) !void {
            try self.ensureCapacity(allocator, expected_items);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.cap == 0) return;
            allocator.free(self.entries);
            allocator.free(self.tags);
            self.occupied.deinit();
            self.run_end.deinit();
            self.* = .{
                .ctx = self.ctx,
                .entries = &.{},
                .tags = &.{},
                .occupied = undefined,
                .run_end = undefined,
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

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: K, value: V) !void {
            while (true) {
                try self.ensureCapacity(allocator, self.len + 1);
                if (self.putAssumeCapacity(key, value)) return;

                const next_cap = if (self.cap == 0) 64 else self.cap * 2;
                try self.growTo(allocator, next_cap);
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.len == 0) return false;

            const hash = hashFn(self.ctx, key);
            const home = self.bucketFromHash(hash);
            if (!self.occupied.testBit(home)) return false;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return false;
            const run_end = self.findRunEnd(run_start);

            const idx = self.findKeyInRun(key, tag, run_start, run_end) orelse return false;
            const single = run_start == run_end;
            if (single) {
                self.occupied.setBit(home, false);
            }

            if (idx == run_end) {
                self.run_end.setBit(run_end, false);
                if (!single) {
                    self.run_end.setBit(run_end - 1, true);
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

                self.run_end.shiftLeft(idx + 1, stop - 1);
            }

            const clear_idx = stop - 1;
            self.tags[clear_idx] = 0;
            self.run_end.setBit(clear_idx, false);
            self.len -= 1;
            return true;
        }

        fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, min_items: usize) !void {
            if (self.cap > 0 and min_items <= maxLoad(self.cap)) return;

            var new_cap: usize = if (self.cap == 0) 64 else self.cap;
            while (min_items > maxLoad(new_cap)) new_cap *= 2;
            try self.growTo(allocator, new_cap);
        }

        fn maxLoad(cap: usize) usize {
            return cap * max_load_num / max_load_den;
        }

        fn overflowSlots(cap: usize) usize {
            const bits = @bitSizeOf(usize);
            const lg: usize = bits - 1 - @clz(cap);
            const target = lg * 8;

            var overflow: usize = min_overflow_slots;
            while (overflow < target and overflow < max_overflow_slots) {
                overflow *= 2;
            }
            return @min(overflow, max_overflow_slots);
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, new_cap: usize) !void {
            const new_slots_len = new_cap + overflowSlots(new_cap);
            var new_map = Self{
                .ctx = self.ctx,
                .entries = try allocator.alloc(Entry, new_slots_len),
                .tags = try allocator.alloc(u8, new_slots_len),
                .occupied = try rank_tree2.RankSelectTree.init(allocator, new_slots_len),
                .run_end = try rank_tree2.RankSelectTree.init(allocator, new_slots_len),
                .cap = new_cap,
                .slots_len = new_slots_len,
                .len = 0,
            };
            errdefer {
                allocator.free(new_map.entries);
                allocator.free(new_map.tags);
                new_map.occupied.deinit();
                new_map.run_end.deinit();
            }
            @memset(new_map.tags, 0);

            if (self.cap > 0) {
                for (0..self.slots_len) |i| {
                    if (!self.isSlotOccupied(i)) continue;
                    const entry = self.entries[i];
                    std.debug.assert(new_map.putAssumeCapacity(entry.key, entry.value));
                }

                allocator.free(self.entries);
                allocator.free(self.tags);
                self.occupied.deinit();
                self.run_end.deinit();
            }

            self.* = new_map;
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

        fn homeForIndex(self: *const Self, idx: usize) usize {
            const run_index = self.run_end.rank(idx);
            return self.occupied.select(run_index) orelse unreachable;
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
            while (!self.run_end.testBit(idx)) {
                idx += 1;
            }
            return idx + 1;
        }

        fn findRunEnd(self: *const Self, run_start: usize) usize {
            var idx = run_start;
            while (!self.run_end.testBit(idx)) {
                idx += 1;
            }
            return idx;
        }

        fn runStartFromCluster(self: *const Self, cluster_start: usize, home: usize) usize {
            if (cluster_start == home) return cluster_start;

            const runs_before_home: usize = blk: {
                const span = home - cluster_start;
                if (span <= 16) {
                    var occupied_count: usize = 0;
                    var idx = cluster_start;
                    while (idx < home) : (idx += 1) {
                        occupied_count += @intFromBool(self.occupied.testBit(idx));
                    }
                    break :blk occupied_count;
                }

                const home_rank = self.occupied.rank(home);
                const cluster_rank = self.occupied.rank(cluster_start);
                break :blk @as(usize, home_rank - cluster_rank);
            };

            var run_start = cluster_start;
            var remaining = runs_before_home;
            while (remaining > 0) : (remaining -= 1) {
                run_start = self.nextRunStart(run_start);
            }

            return run_start;
        }

        fn findRunStartBase(self: *const Self, home: usize) usize {
            const cluster_start = self.findClusterStart(home);
            return self.runStartFromCluster(cluster_start, home);
        }

        fn findRunStart(self: *const Self, home: usize) ?usize {
            if (!self.occupied.testBit(home)) return null;
            return self.findRunStartBase(home);
        }

        fn findKeyInRun(self: *const Self, key: K, tag: u8, run_start: usize, run_end: usize) ?usize {
            const run_len = run_end - run_start + 1;
            var idx = run_start;

            const simd_len = run_len - (run_len % tag_scan_chunk);
            const simd_end = run_start + simd_len;

            if (simd_len >= tag_scan_chunk) {
                const tag_vec: @Vector(tag_scan_chunk, u8) = @splat(tag);
                while (idx < simd_end) : (idx += tag_scan_chunk) {
                    const group: @Vector(tag_scan_chunk, u8) = self.tags[idx..][0..tag_scan_chunk].*;
                    var matches: @Int(.unsigned, tag_scan_chunk) = @bitCast(group == tag_vec);
                    while (matches != 0) {
                        const off: usize = @intCast(@ctz(matches));
                        const candidate = idx + off;
                        if (eqlFn(self.ctx, self.entries[candidate].key, key)) return candidate;
                        matches &= matches - 1;
                    }
                }
            }

            while (idx <= run_end) : (idx += 1) {
                if (self.tags[idx] == tag and eqlFn(self.ctx, self.entries[idx].key, key)) return idx;
            }

            return null;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const hash = hashFn(self.ctx, key);
            const home = self.bucketFromHash(hash);
            if (!self.occupied.testBit(home)) return null;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return null;
            const run_end = self.findRunEnd(run_start);

            return self.findKeyInRun(key, tag, run_start, run_end);
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) bool {
            const hash = hashFn(self.ctx, key);
            const home = self.bucketFromHash(hash);
            const tag = tagFromHash(hash);

            if (!self.isSlotOccupied(home)) {
                self.entries[home] = .{ .key = key, .value = value };
                self.tags[home] = tag;
                self.occupied.setBit(home, true);
                self.run_end.setBit(home, true);
                self.len += 1;
                return true;
            }

            var insert_pos: usize = undefined;
            var insert_disp: usize = undefined;

            if (self.occupied.testBit(home)) {
                const run_start = self.findRunStart(home) orelse return false;
                const run_end = self.findRunEnd(run_start);

                if (self.findKeyInRun(key, tag, run_start, run_end)) |idx| {
                    self.entries[idx].value = value;
                    return true;
                }

                insert_pos = run_end + 1;
            } else {
                insert_pos = self.findRunStartBase(home);
            }

            insert_disp = insert_pos - home;

            if (insert_disp > max_overflow_slots) return false;
            const empty_slot = self.findEmptyFrom(insert_pos) orelse return false;
            if (empty_slot - home > max_overflow_slots) return false;

            if (empty_slot > insert_pos) {
                const moved = empty_slot - insert_pos;
                @memmove(
                    self.entries[insert_pos + 1 .. insert_pos + 1 + moved],
                    self.entries[insert_pos .. insert_pos + moved],
                );
                @memmove(
                    self.tags[insert_pos + 1 .. insert_pos + 1 + moved],
                    self.tags[insert_pos .. insert_pos + moved],
                );

                self.run_end.shiftRight(insert_pos, empty_slot - 1);
            }

            self.entries[insert_pos] = .{ .key = key, .value = value };
            self.tags[insert_pos] = tag;

            if (self.occupied.testBit(home)) {
                self.run_end.setBit(insert_pos - 1, false);
            } else {
                self.occupied.setBit(home, true);
            }
            self.run_end.setBit(insert_pos, true);
            self.len += 1;
            return true;
        }
    };
}

const std = @import("std");

pub fn QfBlocksBucketHashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        keys: []K,
        values: []V,
        tags: []align(bucket_size) u8,
        overflow_count: []u16,
        bucket_count: usize,
        len: usize,

        const Self = @This();
        const bucket_size = 16;
        const max_load_num = 7;
        const max_load_den = 8;

        pub const empty: Self = .{
            .keys = &.{},
            .values = &.{},
            .tags = &.{},
            .overflow_count = &.{},
            .bucket_count = 0,
            .len = 0,
        };

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, expected_items: usize) !void {
            try self.ensureCapacity(allocator, expected_items);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.bucket_count == 0) return;
            allocator.free(self.keys);
            allocator.free(self.values);
            allocator.free(self.tags);
            allocator.free(self.overflow_count);
            self.* = empty;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = self.findIndex(key) orelse return null;
            return self.values[idx];
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: K, value: V) !void {
            try self.ensureCapacity(allocator, self.len + 1);
            while (!self.tryInsert(key, value)) {
                try self.growTo(allocator, self.bucket_count * 2);
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.len == 0) return false;
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const tag = tagFromHash(hash);
            const home = self.bucketFromHash(hash);
            const mask = self.bucket_count - 1;
            const tag_lane: @Vector(bucket_size, u8) = @splat(tag);

            var bucket = home;
            while (true) {
                const tags_vec = self.loadTags(bucket);
                var matches: u16 = @bitCast(tags_vec == tag_lane);
                while (matches != 0) {
                    const lane: usize = @intCast(@ctz(matches));
                    const idx = bucket * bucket_size + lane;
                    if (ctx.eql(self.keys[idx], key)) {
                        self.tags[idx] = 0;
                        self.len -= 1;
                        var b = home;
                        while (b != bucket) : (b = (b + 1) & mask) {
                            self.overflow_count[b] -= 1;
                        }
                        return true;
                    }
                    matches &= matches - 1;
                }
                if (self.overflow_count[bucket] == 0) return false;
                bucket = (bucket + 1) & mask;
                if (bucket == home) return false;
            }
        }

        fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, min_items: usize) !void {
            if (self.bucket_count > 0 and min_items <= maxLoad(self.bucket_count)) return;
            var new_bc: usize = if (self.bucket_count == 0) 4 else self.bucket_count;
            while (min_items > maxLoad(new_bc)) new_bc *= 2;
            try self.growTo(allocator, new_bc);
        }

        fn maxLoad(bc: usize) usize {
            return bc * bucket_size * max_load_num / max_load_den;
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, new_bucket_count: usize) !void {
            std.debug.assert(std.math.isPowerOfTwo(new_bucket_count));
            const total_slots = new_bucket_count * bucket_size;

            var new_map = Self{
                .keys = try allocator.alloc(K, total_slots),
                .values = try allocator.alloc(V, total_slots),
                .tags = try allocator.alignedAlloc(u8, .@"16", total_slots),
                .overflow_count = try allocator.alloc(u16, new_bucket_count),
                .bucket_count = new_bucket_count,
                .len = 0,
            };
            errdefer {
                allocator.free(new_map.keys);
                allocator.free(new_map.values);
                allocator.free(new_map.tags);
                allocator.free(new_map.overflow_count);
            }
            @memset(new_map.tags, 0);
            @memset(new_map.overflow_count, 0);

            if (self.bucket_count > 0) {
                const total_old = self.bucket_count * bucket_size;
                for (0..total_old) |i| {
                    if (self.tags[i] != 0) {
                        std.debug.assert(new_map.tryInsert(self.keys[i], self.values[i]));
                    }
                }
                allocator.free(self.keys);
                allocator.free(self.values);
                allocator.free(self.tags);
                allocator.free(self.overflow_count);
            }

            self.* = new_map;
        }

        inline fn bucketFromHash(self: *const Self, hash: u64) usize {
            return @as(usize, @truncate(hash)) & (self.bucket_count - 1);
        }

        inline fn tagFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        inline fn loadTags(self: *const Self, bucket: usize) @Vector(bucket_size, u8) {
            const base = bucket * bucket_size;
            const ptr: *align(bucket_size) const [bucket_size]u8 = @alignCast(@ptrCast(self.tags.ptr + base));
            return ptr.*;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const tag = tagFromHash(hash);
            const home = self.bucketFromHash(hash);
            const mask = self.bucket_count - 1;
            const tag_lane: @Vector(bucket_size, u8) = @splat(tag);

            var bucket = home;
            while (true) {
                const tags_vec = self.loadTags(bucket);
                var matches: u16 = @bitCast(tags_vec == tag_lane);
                while (matches != 0) {
                    const lane: usize = @intCast(@ctz(matches));
                    const idx = bucket * bucket_size + lane;
                    if (ctx.eql(self.keys[idx], key)) return idx;
                    matches &= matches - 1;
                }
                if (self.overflow_count[bucket] == 0) return null;
                bucket = (bucket + 1) & mask;
                if (bucket == home) return null;
            }
        }

        fn tryInsert(self: *Self, key: K, value: V) bool {
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const tag = tagFromHash(hash);
            const home = self.bucketFromHash(hash);
            const mask = self.bucket_count - 1;
            const tag_lane: @Vector(bucket_size, u8) = @splat(tag);
            const empty_lane: @Vector(bucket_size, u8) = @splat(0);

            // Walk the existing chain: detect duplicate key, capture first empty slot.
            var first_empty_bucket: usize = std.math.maxInt(usize);
            var first_empty_lane: usize = 0;
            var bucket = home;
            var chain_done = false;
            while (!chain_done) {
                const tags_vec = self.loadTags(bucket);
                var matches: u16 = @bitCast(tags_vec == tag_lane);
                while (matches != 0) {
                    const lane: usize = @intCast(@ctz(matches));
                    const idx = bucket * bucket_size + lane;
                    if (ctx.eql(self.keys[idx], key)) {
                        self.values[idx] = value;
                        return true;
                    }
                    matches &= matches - 1;
                }
                if (first_empty_bucket == std.math.maxInt(usize)) {
                    const empties: u16 = @bitCast(tags_vec == empty_lane);
                    if (empties != 0) {
                        first_empty_bucket = bucket;
                        first_empty_lane = @intCast(@ctz(empties));
                    }
                }
                if (self.overflow_count[bucket] == 0) {
                    chain_done = true;
                } else {
                    bucket = (bucket + 1) & mask;
                    if (bucket == home) chain_done = true;
                }
            }

            // No duplicate. If we already saw an empty slot inside the chain, use it.
            if (first_empty_bucket != std.math.maxInt(usize)) {
                const idx = first_empty_bucket * bucket_size + first_empty_lane;
                self.keys[idx] = key;
                self.values[idx] = value;
                self.tags[idx] = tag;
                self.len += 1;
                var b = home;
                while (b != first_empty_bucket) : (b = (b + 1) & mask) {
                    self.overflow_count[b] += 1;
                }
                return true;
            }

            // Chain was full. Probe forward.
            var probe_bucket = (bucket + 1) & mask;
            var probes: usize = 1;
            while (probes < self.bucket_count) : (probes += 1) {
                if (probe_bucket == home) return false;
                const tags_vec = self.loadTags(probe_bucket);
                const empties: u16 = @bitCast(tags_vec == empty_lane);
                if (empties != 0) {
                    const lane: usize = @intCast(@ctz(empties));
                    const idx = probe_bucket * bucket_size + lane;
                    self.keys[idx] = key;
                    self.values[idx] = value;
                    self.tags[idx] = tag;
                    self.len += 1;
                    var b = home;
                    while (b != probe_bucket) : (b = (b + 1) & mask) {
                        self.overflow_count[b] += 1;
                    }
                    return true;
                }
                probe_bucket = (probe_bucket + 1) & mask;
            }
            return false;
        }
    };
}

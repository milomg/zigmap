const std = @import("std");

pub fn CuckooSimdHashMap(comptime K: type, comptime V: type) type {
    const Context = std.hash_map.AutoContext(K);
    const hashFn = std.hash_map.getAutoHashFn(K, Context);
    const eqlFn = std.hash_map.getAutoEqlFn(K, Context);

    return struct {
        allocator: std.mem.Allocator,
        ctx: Context,
        keys: []K,
        values: []V,
        tags: []u8,
        bucket_count: usize,
        len: usize,

        const Self = @This();
        const group_len = 16;
        const max_load_num = 7;
        const max_load_den = 8;
        const max_kicks = 64;

        pub fn initCapacity(allocator: std.mem.Allocator, expected_items: usize) !Self {
            var self = Self{
                .allocator = allocator,
                .ctx = .{},
                .keys = &.{},
                .values = &.{},
                .tags = &.{},
                .bucket_count = 0,
                .len = 0,
            };
            try self.ensureCapacity(expected_items);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.bucket_count == 0) return;
            self.allocator.free(self.keys);
            self.allocator.free(self.values);
            self.allocator.free(self.tags);
            self.* = .{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .keys = &.{},
                .values = &.{},
                .tags = &.{},
                .bucket_count = 0,
                .len = 0,
            };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = self.findIndex(key) orelse return null;
            return self.values[idx];
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            try self.ensureCapacity(self.len + 1);
            self.putAssumeCapacity(key, value);
        }

        pub fn remove(self: *Self, key: K) bool {
            const idx = self.findIndex(key) orelse return false;
            self.tags[idx] = 0;
            self.len -= 1;
            return true;
        }

        fn ensureCapacity(self: *Self, min_items: usize) !void {
            if (self.bucket_count > 0 and min_items <= maxLoad(self.bucket_count)) return;

            var new_bucket_count: usize = if (self.bucket_count == 0) 64 else self.bucket_count;
            while (min_items > maxLoad(new_bucket_count)) new_bucket_count *= 2;
            try self.growTo(new_bucket_count);
        }

        fn maxLoad(bucket_count: usize) usize {
            return bucket_count * group_len * max_load_num / max_load_den;
        }

        fn growTo(self: *Self, new_bucket_count: usize) !void {
            var new_map = Self{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .keys = try self.allocator.alloc(K, new_bucket_count * group_len),
                .values = try self.allocator.alloc(V, new_bucket_count * group_len),
                .tags = try self.allocator.alloc(u8, new_bucket_count * group_len),
                .bucket_count = new_bucket_count,
                .len = 0,
            };
            errdefer {
                self.allocator.free(new_map.keys);
                self.allocator.free(new_map.values);
                self.allocator.free(new_map.tags);
            }
            @memset(new_map.tags, 0);

            if (self.bucket_count > 0) {
                for (0..self.bucket_count * group_len) |i| {
                    if (self.tags[i] != 0) {
                        new_map.putAssumeCapacity(self.keys[i], self.values[i]);
                    }
                }
                self.allocator.free(self.keys);
                self.allocator.free(self.values);
                self.allocator.free(self.tags);
            }

            self.* = new_map;
        }

        fn hashKey(self: *const Self, key: K) u64 {
            return hashFn(self.ctx, key);
        }

        fn eql(self: *const Self, a: K, b: K) bool {
            return eqlFn(self.ctx, a, b);
        }

        fn tagFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        fn bucketIndex(self: *const Self, hash: u64) usize {
            return @as(usize, @truncate(hash)) & (self.bucket_count - 1);
        }

        fn loadTagGroup(self: *const Self, bucket: usize) @Vector(group_len, u8) {
            const base = bucket * group_len;
            const ptr: *const [group_len]u8 = @ptrCast(self.tags.ptr + base);
            return ptr.*;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.bucket_count == 0) return null;

            const hash0 = self.hashKey(key);
            const hash1 = std.math.rotl(u64, hash0, 32);
            const tag = tagFromHash(hash0);
            const b0 = self.bucketIndex(hash0);
            const b1 = self.bucketIndex(hash1);

            if (self.findInBucket(key, tag, b0)) |idx| return idx;
            if (self.findInBucket(key, tag, b1)) |idx| return idx;
            return null;
        }

        fn findInBucket(self: *const Self, key: K, tag: u8, bucket: usize) ?usize {
            const tags = self.loadTagGroup(bucket);
            const tag_lane: @Vector(group_len, u8) = @splat(tag);
            const matches = tags == tag_lane;
            var bits: u16 = @bitCast(matches);
            while (bits != 0) {
                const lane = @ctz(bits);
                const idx = bucket * group_len + lane;
                if (self.eql(self.keys[idx], key)) return idx;
                bits &= bits - 1;
            }
            return null;
        }

        fn findEmptyInBucket(self: *const Self, bucket: usize) ?usize {
            const tags = self.loadTagGroup(bucket);
            const empty_lane: @Vector(group_len, u8) = @splat(@as(u8, 0));
            const empties = tags == empty_lane;
            const bits: u16 = @bitCast(empties);
            if (bits == 0) return null;
            const lane = @ctz(bits);
            return bucket * group_len + lane;
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            const hash0 = self.hashKey(key);
            const hash1 = std.math.rotl(u64, hash0, 32);
            const tag = tagFromHash(hash0);
            const b0 = self.bucketIndex(hash0);
            const b1 = self.bucketIndex(hash1);

            if (self.findInBucket(key, tag, b0)) |idx| {
                self.values[idx] = value;
                return;
            }
            if (self.findInBucket(key, tag, b1)) |idx| {
                self.values[idx] = value;
                return;
            }

            if (self.findEmptyInBucket(b0)) |idx| {
                self.keys[idx] = key;
                self.values[idx] = value;
                self.tags[idx] = tag;
                self.len += 1;
                return;
            }
            if (self.findEmptyInBucket(b1)) |idx| {
                self.keys[idx] = key;
                self.values[idx] = value;
                self.tags[idx] = tag;
                self.len += 1;
                return;
            }

            var cur_key = key;
            var cur_val = value;
            var cur_tag = tag;
            var cur_bucket = b0;

            var kick: usize = 0;
            while (kick < max_kicks) : (kick += 1) {
                const lane = (cur_tag +% @as(u8, @intCast(kick))) & (group_len - 1);
                const idx = cur_bucket * group_len + lane;

                const evict_key = self.keys[idx];
                const evict_val = self.values[idx];
                const evict_tag = self.tags[idx];

                self.keys[idx] = cur_key;
                self.values[idx] = cur_val;
                self.tags[idx] = cur_tag;

                cur_key = evict_key;
                cur_val = evict_val;
                cur_tag = evict_tag;

                const evict_hash0 = self.hashKey(cur_key);
                const evict_hash1 = std.math.rotl(u64, evict_hash0, 32);
                const evict_b0 = self.bucketIndex(evict_hash0);
                const evict_b1 = self.bucketIndex(evict_hash1);

                cur_bucket = if (cur_bucket == evict_b0) evict_b1 else evict_b0;

                if (self.findEmptyInBucket(cur_bucket)) |empty_idx| {
                    self.keys[empty_idx] = cur_key;
                    self.values[empty_idx] = cur_val;
                    self.tags[empty_idx] = cur_tag;
                    self.len += 1;
                    return;
                }
            }

            self.growTo(self.bucket_count * 2) catch unreachable;
            self.putAssumeCapacity(cur_key, cur_val);
        }
    };
}

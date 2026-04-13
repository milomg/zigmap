const std = @import("std");

pub fn BoostStyleFlatMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        metadata: ?[*]u8,
        cap: usize,
        group_count: usize,
        len: usize,
        max_load: usize,

        const Self = @This();
        const Header = struct {
            keys: [*]K,
            values: [*]V,
        };
        const group_size = 15;
        const group_span = 16;
        const empty_meta: u8 = 0;

        pub const empty: Self = .{
            .metadata = null,
            .cap = 0,
            .group_count = 0,
            .len = 0,
            .max_load = 0,
        };

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, expected_items: usize) !void {
            try self.ensureCapacity(allocator, expected_items);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.deallocateStorage(allocator);
            self.* = .{
                .metadata = null,
                .cap = 0,
                .group_count = 0,
                .len = 0,
                .max_load = 0,
            };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = self.findIndex(key) orelse return null;
            return self.values()[idx];
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: K, value: V) !void {
            try self.ensureCapacity(allocator, self.len + 1);
            self.putAssumeCapacity(key, value);
        }

        pub fn remove(self: *Self, key: K) bool {
            const idx = self.findIndex(key) orelse return false;
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const overflow_bit = overflowBitFromHash(hash);
            const grp = idx / group_size;
            const grp_overflow = self.metaPtr()[metaOffsetForGroup(grp) + group_size];
            if ((grp_overflow & overflow_bit) != 0) {
                self.max_load -|= 1;
            }
            self.setMetaForBucket(idx, empty_meta);
            self.len -= 1;
            return true;
        }

        fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, min_items: usize) !void {
            if (self.cap > 0 and min_items <= self.max_load) return;

            const target = if (self.cap > 0 and min_items <= maxLoad(self.cap))
                self.len + self.len / 61 + 1
            else
                min_items;

            var new_groups: usize = if (self.group_count == 0) 8 else self.group_count;
            while (target > maxLoad(new_groups * group_size)) new_groups *= 2;
            try self.growToGroups(allocator, new_groups);
        }

        inline fn maxLoad(cap: usize) usize {
            return (cap * 7) / 8;
        }

        inline fn header(self: *const Self) *Header {
            return @ptrCast(@as([*]Header, @ptrCast(@alignCast(self.metadata.?))) - 1);
        }

        inline fn keys(self: *const Self) [*]K {
            return self.header().keys;
        }

        inline fn values(self: *const Self) [*]V {
            return self.header().values;
        }

        inline fn metaPtr(self: *const Self) [*]u8 {
            return self.metadata.?;
        }

        fn allocateStorage(self: *Self, allocator: std.mem.Allocator, new_group_count: usize) !void {
            const header_align = @alignOf(Header);
            const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
            const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
            const max_align: std.mem.Alignment = comptime .fromByteUnits(@max(header_align, key_align, val_align));

            const new_cap = new_group_count * group_size;
            const meta_size = @sizeOf(Header) + new_group_count * group_span;
            const keys_start = std.mem.alignForward(usize, meta_size, key_align);
            const keys_end = keys_start + new_cap * @sizeOf(K);
            const vals_start = std.mem.alignForward(usize, keys_end, val_align);
            const vals_end = vals_start + new_cap * @sizeOf(V);
            const total_size = max_align.forward(vals_end);

            const slice = try allocator.alignedAlloc(u8, max_align, total_size);
            const ptr: [*]u8 = @ptrCast(slice.ptr);
            const hdr: *Header = @ptrCast(@alignCast(ptr));
            if (@sizeOf([*]K) != 0) hdr.keys = @ptrCast(@alignCast(ptr + keys_start));
            if (@sizeOf([*]V) != 0) hdr.values = @ptrCast(@alignCast(ptr + vals_start));

            self.metadata = @ptrCast(@alignCast(ptr + @sizeOf(Header)));
            self.cap = new_cap;
            self.group_count = new_group_count;
            self.max_load = maxLoad(new_cap);
            @memset(self.metaPtr()[0 .. new_group_count * group_span], empty_meta);
        }

        fn deallocateStorage(self: *Self, allocator: std.mem.Allocator) void {
            if (self.metadata == null) return;

            const header_align = @alignOf(Header);
            const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
            const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
            const max_align = comptime @max(header_align, key_align, val_align);

            const meta_size = @sizeOf(Header) + self.group_count * group_span;
            const keys_start = std.mem.alignForward(usize, meta_size, key_align);
            const keys_end = keys_start + self.cap * @sizeOf(K);
            const vals_start = std.mem.alignForward(usize, keys_end, val_align);
            const vals_end = vals_start + self.cap * @sizeOf(V);
            const total_size = std.mem.alignForward(usize, vals_end, max_align);

            const slice = @as([*]align(max_align) u8, @ptrCast(@alignCast(self.header())))[0..total_size];
            allocator.free(slice);
            self.metadata = null;
            self.cap = 0;
            self.group_count = 0;
        }

        fn growToGroups(self: *Self, allocator: std.mem.Allocator, new_group_count: usize) !void {
            var new_map = Self{
                .metadata = null,
                .cap = 0,
                .group_count = 0,
                .len = 0,
                .max_load = 0,
            };
            try new_map.allocateStorage(allocator, new_group_count);
            errdefer new_map.deallocateStorage(allocator);

            if (self.cap > 0) {
                for (0..self.cap) |bucket| {
                    if (self.isOccupied(bucket)) {
                        new_map.putAssumeCapacity(self.keys()[bucket], self.values()[bucket]);
                    }
                }
                self.deallocateStorage(allocator);
            }

            self.* = new_map;
        }

        inline fn isOccupied(self: *const Self, bucket: usize) bool {
            return self.metaForBucket(bucket) >= 2;
        }

        inline fn groupFromHash(self: *const Self, hash: u64) usize {
            const shift: u6 = @intCast(64 - @ctz(self.group_count));
            return @as(usize, @truncate(hash >> shift));
        }

        inline fn fingerprintFromHash(hash: u64) u8 {
            const fp = @as(u8, @truncate(hash));
            return if (fp < 2) fp + 8 else fp;
        }

        inline fn overflowBitFromHash(hash: u64) u8 {
            const bit_index: u3 = @truncate(hash);
            return @as(u8, 1) << bit_index;
        }

        inline fn bucketForGroupLane(group: usize, lane: usize) usize {
            return group * group_size + lane;
        }

        inline fn metaOffsetForGroup(group: usize) usize {
            return group * group_span;
        }

        inline fn metaForBucket(self: *const Self, bucket: usize) u8 {
            const group = bucket / group_size;
            const lane = bucket % group_size;
            return self.metaPtr()[metaOffsetForGroup(group) + lane];
        }

        inline fn setMetaForBucket(self: *Self, bucket: usize, value: u8) void {
            const group = bucket / group_size;
            const lane = bucket % group_size;
            self.metaPtr()[metaOffsetForGroup(group) + lane] = value;
        }

        inline fn loadMetaGroup(self: *const Self, group: usize) @Vector(group_span, u8) {
            const ptr: *const [group_span]u8 = @ptrCast(self.metaPtr() + metaOffsetForGroup(group));
            return ptr.*;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const fp = fingerprintFromHash(hash);
            const overflow_bit = overflowBitFromHash(hash);
            const fp_lane: @Vector(group_span, u8) = @splat(fp);

            var group = self.groupFromHash(hash);
            var step: usize = 0;

            while (step < self.group_count) : (step += 1) {
                const chunk = self.loadMetaGroup(group);
                const chunk_bytes: [group_span]u8 = @bitCast(chunk);
                const candidates = chunk == fp_lane;

                if (@reduce(.Or, candidates)) {
                    inline for (0..group_size) |lane| {
                        if (chunk_bytes[lane] == fp) {
                            const bucket = bucketForGroupLane(group, lane);
                            if (ctx.eql(self.keys()[bucket], key)) return bucket;
                        }
                    }
                }

                const overflow = chunk_bytes[group_size];
                if ((overflow & overflow_bit) == 0) return null;
                group = (group + step + 1) & (self.group_count - 1);
            }

            return null;
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const fp = fingerprintFromHash(hash);
            const overflow_bit = overflowBitFromHash(hash);
            const fp_lane: @Vector(group_span, u8) = @splat(fp);
            const empty_lane: @Vector(group_span, u8) = @splat(empty_meta);

            var group = self.groupFromHash(hash);
            var step: usize = 0;

            while (step < self.group_count) : (step += 1) {
                const base = metaOffsetForGroup(group);
                const chunk = self.loadMetaGroup(group);
                const chunk_bytes: [group_span]u8 = @bitCast(chunk);
                const candidates = chunk == fp_lane;

                if (@reduce(.Or, candidates)) {
                    inline for (0..group_size) |lane_match| {
                        if (chunk_bytes[lane_match] == fp) {
                            const bucket_match = bucketForGroupLane(group, lane_match);
                            if (ctx.eql(self.keys()[bucket_match], key)) {
                                self.values()[bucket_match] = value;
                                return;
                            }
                        }
                    }
                }

                const empties = chunk == empty_lane;
                if (@reduce(.Or, empties)) {
                    inline for (0..group_size) |lane_empty| {
                        if (chunk_bytes[lane_empty] == empty_meta) {
                            const bucket_empty = bucketForGroupLane(group, lane_empty);
                            self.keys()[bucket_empty] = key;
                            self.values()[bucket_empty] = value;
                            self.metaPtr()[base + lane_empty] = fp;
                            self.len += 1;
                            return;
                        }
                    }
                }

                self.metaPtr()[base + group_size] |= overflow_bit;
                group = (group + step + 1) & (self.group_count - 1);
            }

            unreachable;
        }
    };
}

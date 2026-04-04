const std = @import("std");

pub fn QfHashMap(comptime K: type, comptime V: type) type {
    const Context = std.hash_map.AutoContext(K);
    const hashFn = std.hash_map.getAutoHashFn(K, Context);
    const eqlFn = std.hash_map.getAutoEqlFn(K, Context);

    return struct {
        allocator: std.mem.Allocator,
        ctx: Context,
        keys: []K,
        values: []V,
        ctrl: []u8,
        direct_used_bits: []usize,
        cap: usize,
        len: usize,

        const Self = @This();
        const group_len = 16;
        const word_bits = @bitSizeOf(usize);

        const occupied_bit: u8 = 0b1000_0000;
        const fp_mask: u8 = 0b0111_1111;
        const empty_ctrl: u8 = 0;

        pub fn initCapacity(allocator: std.mem.Allocator, expected_items: usize) !Self {
            var self = Self{
                .allocator = allocator,
                .ctx = .{},
                .keys = &.{},
                .values = &.{},
                .ctrl = &.{},
                .direct_used_bits = &.{},
                .cap = 0,
                .len = 0,
            };
            try self.ensureCapacity(expected_items);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.cap == 0) return;
            self.allocator.free(self.keys);
            self.allocator.free(self.values);
            self.allocator.free(self.ctrl);
            self.allocator.free(self.direct_used_bits);
            self.* = .{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .keys = &.{},
                .values = &.{},
                .ctrl = &.{},
                .direct_used_bits = &.{},
                .cap = 0,
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
            const hash = self.hashKey(key);
            const home = self.bucketFromHash(hash);

            self.deleteAt(idx);
            if (!self.homeStillUsed(home)) self.setDirectUsed(home, false);
            return true;
        }

        fn ensureCapacity(self: *Self, min_items: usize) !void {
            if (self.cap > 0 and min_items <= maxLoad(self.cap)) return;

            var new_cap: usize = if (self.cap == 0) 64 else self.cap;
            while (min_items > maxLoad(new_cap)) new_cap *= 2;
            try self.growTo(new_cap);
        }

        fn maxLoad(cap: usize) usize {
            return cap - cap / 8;
        }

        fn bitWords(bit_len: usize) usize {
            return (bit_len + (word_bits - 1)) / word_bits;
        }

        fn growTo(self: *Self, new_cap: usize) !void {
            var new_map = Self{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .keys = try self.allocator.alloc(K, new_cap),
                .values = try self.allocator.alloc(V, new_cap),
                .ctrl = try self.allocator.alloc(u8, new_cap + group_len),
                .direct_used_bits = try self.allocator.alloc(usize, bitWords(new_cap)),
                .cap = new_cap,
                .len = 0,
            };
            errdefer {
                self.allocator.free(new_map.keys);
                self.allocator.free(new_map.values);
                self.allocator.free(new_map.ctrl);
                self.allocator.free(new_map.direct_used_bits);
            }
            @memset(new_map.ctrl, empty_ctrl);
            @memset(new_map.direct_used_bits, 0);

            if (self.cap > 0) {
                for (0..self.cap) |i| {
                    if (self.isOccupied(i)) {
                        new_map.putAssumeCapacity(self.keys[i], self.values[i]);
                    }
                }
                self.allocator.free(self.keys);
                self.allocator.free(self.values);
                self.allocator.free(self.ctrl);
                self.allocator.free(self.direct_used_bits);
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

        fn fingerprintFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) & fp_mask;
        }

        fn bitMask(bit_index: usize) usize {
            return @as(usize, 1) << @intCast(bit_index % word_bits);
        }

        fn bitTest(words: []const usize, bit_index: usize) bool {
            const word_index = bit_index / word_bits;
            return (words[word_index] & bitMask(bit_index)) != 0;
        }

        fn bitSet(words: []usize, bit_index: usize) void {
            const word_index = bit_index / word_bits;
            words[word_index] |= bitMask(bit_index);
        }

        fn bitClear(words: []usize, bit_index: usize) void {
            const word_index = bit_index / word_bits;
            words[word_index] &= ~bitMask(bit_index);
        }

        fn homeIsUsed(self: *const Self, home: usize) bool {
            return bitTest(self.direct_used_bits, home);
        }

        fn setDirectUsed(self: *Self, home: usize, value: bool) void {
            const old = self.homeIsUsed(home);
            if (old == value) return;

            if (value) {
                bitSet(self.direct_used_bits, home);
            } else {
                bitClear(self.direct_used_bits, home);
            }
        }

        fn isOccupied(self: *const Self, idx: usize) bool {
            return (self.ctrl[idx] & occupied_bit) != 0;
        }

        fn setCtrl(self: *Self, idx: usize, value: u8) void {
            self.ctrl[idx] = value;
            if (idx < group_len) self.ctrl[self.cap + idx] = value;
        }

        fn loadCtrlGroup(self: *const Self, idx: usize) @Vector(group_len, u8) {
            const ptr: *const [group_len]u8 = @ptrCast(self.ctrl.ptr + idx);
            return ptr.*;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const hash = self.hashKey(key);
            const fp = fingerprintFromHash(hash);
            const home = self.bucketFromHash(hash);
            if (!self.homeIsUsed(home)) return null;

            const mask = self.cap - 1;
            var idx = home;
            var scanned: usize = 0;

            const occ_mask: @Vector(group_len, u8) = @splat(occupied_bit);
            const fp_lane: @Vector(group_len, u8) = @splat(fp);
            const fp_mask_lane: @Vector(group_len, u8) = @splat(fp_mask);
            const empty_lane: @Vector(group_len, u8) = @splat(empty_ctrl);

            while (scanned < self.cap) : (scanned += group_len) {
                const chunk = self.loadCtrlGroup(idx);
                const occupied = (chunk & occ_mask) == occ_mask;
                const fp_match = (chunk & fp_mask_lane) == fp_lane;
                const candidates = occupied & fp_match;
                const empties = chunk == empty_lane;
                var candidate_bits: u16 = @bitCast(candidates);
                var empty_bits: u16 = @bitCast(empties);
                const valid_lanes: usize = @min(group_len, self.cap - scanned);
                if (valid_lanes < group_len) {
                    const valid_mask: u16 = (@as(u16, 1) << @intCast(valid_lanes)) - 1;
                    candidate_bits &= valid_mask;
                    empty_bits &= valid_mask;
                }

                if (candidate_bits != 0 or empty_bits != 0) {
                    const limit: usize = if (empty_bits != 0) @as(usize, @ctz(empty_bits)) else valid_lanes;
                    const limit_mask: u16 = if (limit == group_len) 0xffff else (@as(u16, 1) << @intCast(limit)) - 1;
                    var bits = candidate_bits & limit_mask;
                    while (bits != 0) {
                        const lane = @ctz(bits);
                        const slot = (idx + lane) & mask;
                        if (self.eql(self.keys[slot], key)) return slot;
                        bits &= bits - 1;
                    }
                    if (empty_bits != 0) return null;
                }
                idx = (idx + group_len) & mask;
            }

            return null;
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            const hash = self.hashKey(key);
            const fp = fingerprintFromHash(hash);
            const home = self.bucketFromHash(hash);
            const mask = self.cap - 1;
            var base = home;
            var scanned: usize = 0;

            const occ_mask: @Vector(group_len, u8) = @splat(occupied_bit);
            const fp_lane: @Vector(group_len, u8) = @splat(fp);
            const fp_mask_lane: @Vector(group_len, u8) = @splat(fp_mask);
            const empty_lane: @Vector(group_len, u8) = @splat(empty_ctrl);

            while (scanned < self.cap) : (scanned += group_len) {
                const chunk = self.loadCtrlGroup(base);
                const occupied = (chunk & occ_mask) == occ_mask;
                const fp_match = (chunk & fp_mask_lane) == fp_lane;
                const candidates = occupied & fp_match;
                const empties = chunk == empty_lane;
                var candidate_bits: u16 = @bitCast(candidates);
                var empty_bits: u16 = @bitCast(empties);
                const valid_lanes: usize = @min(group_len, self.cap - scanned);
                if (valid_lanes < group_len) {
                    const valid_mask: u16 = (@as(u16, 1) << @intCast(valid_lanes)) - 1;
                    candidate_bits &= valid_mask;
                    empty_bits &= valid_mask;
                }

                if (candidate_bits != 0 or empty_bits != 0) {
                    const limit: usize = if (empty_bits != 0) @as(usize, @ctz(empty_bits)) else valid_lanes;
                    const limit_mask: u16 = if (limit == group_len) 0xffff else (@as(u16, 1) << @intCast(limit)) - 1;
                    var bits = candidate_bits & limit_mask;
                    while (bits != 0) {
                        const lane = @ctz(bits);
                        const idx = (base + lane) & mask;
                        if (self.eql(self.keys[idx], key)) {
                            self.values[idx] = value;
                            return;
                        }
                        bits &= bits - 1;
                    }

                    if (empty_bits != 0) {
                        const lane = @ctz(empty_bits);
                        const idx = (base + lane) & mask;
                        self.keys[idx] = key;
                        self.values[idx] = value;
                        self.setCtrl(idx, occupied_bit | (fp & fp_mask));
                        self.len += 1;

                        self.setDirectUsed(home, true);
                        return;
                    }
                }
                base = (base + group_len) & mask;
            }

            unreachable;
        }

        fn homeStillUsed(self: *const Self, home: usize) bool {
            const mask = self.cap - 1;
            var idx = home;
            var scanned: usize = 0;
            const occ_mask: @Vector(group_len, u8) = @splat(occupied_bit);
            const empty_lane: @Vector(group_len, u8) = @splat(empty_ctrl);

            while (scanned < self.cap) : (scanned += group_len) {
                const chunk = self.loadCtrlGroup(idx);
                const occupied = (chunk & occ_mask) == occ_mask;
                const empties = chunk == empty_lane;

                var occ_bits: u16 = @bitCast(occupied);
                var empty_bits: u16 = @bitCast(empties);
                const valid_lanes: usize = @min(group_len, self.cap - scanned);
                if (valid_lanes < group_len) {
                    const valid_mask: u16 = (@as(u16, 1) << @intCast(valid_lanes)) - 1;
                    occ_bits &= valid_mask;
                    empty_bits &= valid_mask;
                }

                if (empty_bits != 0) {
                    const limit: usize = @ctz(empty_bits);
                    const limit_mask: u16 = if (limit == group_len) 0xffff else (@as(u16, 1) << @intCast(limit)) - 1;
                    occ_bits &= limit_mask;
                }

                while (occ_bits != 0) {
                    const lane = @ctz(occ_bits);
                    const slot = (idx + lane) & mask;
                    const slot_home = self.bucketFromHash(self.hashKey(self.keys[slot]));
                    if (slot_home == home) return true;
                    occ_bits &= occ_bits - 1;
                }

                if (empty_bits != 0) return false;
                idx = (idx + group_len) & mask;
            }

            return false;
        }

        fn deleteAt(self: *Self, start_idx: usize) void {
            const mask = self.cap - 1;
            var hole = start_idx;
            var scan = (hole + 1) & mask;

            while (self.isOccupied(scan)) {
                const home = self.bucketFromHash(self.hashKey(self.keys[scan]));
                if (shouldShift(home, hole, scan)) {
                    self.keys[hole] = self.keys[scan];
                    self.values[hole] = self.values[scan];

                    const fp = self.ctrl[scan] & fp_mask;
                    self.setCtrl(hole, occupied_bit | fp);
                    hole = scan;
                }

                scan = (scan + 1) & mask;
            }

            self.setCtrl(hole, empty_ctrl);
            self.len -= 1;
        }

        fn shouldShift(home: usize, hole: usize, idx: usize) bool {
            if (hole <= idx) {
                return home <= hole or home > idx;
            } else {
                return home <= hole and home > idx;
            }
        }
    };
}

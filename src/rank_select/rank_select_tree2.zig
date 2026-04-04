const std = @import("std");

pub const RankSelectTree2 = struct {
    allocator: std.mem.Allocator,
    bit_len: usize,
    leaf_bits_a: []u128,
    leaf_bits_b: []u128,
    counts_a: []u32,
    counts_b: []u32,
    level_offsets: []usize,
    level_sizes: []usize,
    leaf_span_per_level: []usize,
    level_count: usize,

    const Self = @This();
    const fanout = 16;
    const leaf_bits_len = 128;

    pub fn init(allocator: std.mem.Allocator, bit_len: usize) !Self {
        const leaf_count = (bit_len + (leaf_bits_len - 1)) / leaf_bits_len;
        const level_count = computeLevelCount(leaf_count);

        var leaf_span_per_level = try allocator.alloc(usize, level_count);
        errdefer allocator.free(leaf_span_per_level);
        leaf_span_per_level[0] = 1;
        var span_index: usize = 1;
        while (span_index < level_count) : (span_index += 1) {
            leaf_span_per_level[span_index] = leaf_span_per_level[span_index - 1] * fanout;
        }

        var level_sizes = try allocator.alloc(usize, level_count);
        errdefer allocator.free(level_sizes);
        var level_offsets = try allocator.alloc(usize, level_count);
        errdefer allocator.free(level_offsets);

        level_sizes[0] = leaf_count;
        var size_index: usize = 1;
        while (size_index < level_count) : (size_index += 1) {
            level_sizes[size_index] = (level_sizes[size_index - 1] + (fanout - 1)) / fanout;
        }

        level_offsets[0] = 0;
        var offset_index: usize = 1;
        while (offset_index < level_count) : (offset_index += 1) {
            level_offsets[offset_index] = level_offsets[offset_index - 1] + level_sizes[offset_index - 1];
        }

        const total_counts = level_offsets[level_count - 1] + level_sizes[level_count - 1];
        const counts_a = try allocator.alloc(u32, total_counts);
        errdefer allocator.free(counts_a);
        @memset(counts_a, 0);

        const counts_b = try allocator.alloc(u32, total_counts);
        errdefer allocator.free(counts_b);
        @memset(counts_b, 0);

        const leaf_bits_a = try allocator.alloc(u128, leaf_count);
        errdefer allocator.free(leaf_bits_a);
        @memset(leaf_bits_a, 0);

        const leaf_bits_b = try allocator.alloc(u128, leaf_count);
        errdefer allocator.free(leaf_bits_b);
        @memset(leaf_bits_b, 0);

        return .{
            .allocator = allocator,
            .bit_len = bit_len,
            .leaf_bits_a = leaf_bits_a,
            .leaf_bits_b = leaf_bits_b,
            .counts_a = counts_a,
            .counts_b = counts_b,
            .level_offsets = level_offsets,
            .level_sizes = level_sizes,
            .leaf_span_per_level = leaf_span_per_level,
            .level_count = level_count,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.counts_a);
        self.allocator.free(self.counts_b);
        self.allocator.free(self.level_offsets);
        self.allocator.free(self.level_sizes);
        self.allocator.free(self.leaf_bits_a);
        self.allocator.free(self.leaf_bits_b);
        self.allocator.free(self.leaf_span_per_level);
        self.* = undefined;
    }

    pub fn countA(self: *const Self) u32 {
        return self.counts_a[self.level_offsets[self.level_count - 1]];
    }

    pub fn countB(self: *const Self) u32 {
        return self.counts_b[self.level_offsets[self.level_count - 1]];
    }

    pub fn testBitA(self: *const Self, bit_index: usize) bool {
        const leaf = bit_index / leaf_bits_len;
        const offset = bit_index % leaf_bits_len;
        return (self.leaf_bits_a[leaf] & (@as(u128, 1) << @intCast(offset))) != 0;
    }

    pub fn testBitB(self: *const Self, bit_index: usize) bool {
        const leaf = bit_index / leaf_bits_len;
        const offset = bit_index % leaf_bits_len;
        return (self.leaf_bits_b[leaf] & (@as(u128, 1) << @intCast(offset))) != 0;
    }

    pub fn setBitA(self: *Self, bit_index: usize, value: bool) void {
        self.setBit(self.leaf_bits_a, self.counts_a, bit_index, value);
    }

    pub fn setBitB(self: *Self, bit_index: usize, value: bool) void {
        self.setBit(self.leaf_bits_b, self.counts_b, bit_index, value);
    }

    pub fn rankA(self: *const Self, bit_index_exclusive: usize) u32 {
        return self.rank(self.leaf_bits_a, self.counts_a, bit_index_exclusive);
    }

    pub fn rankB(self: *const Self, bit_index_exclusive: usize) u32 {
        return self.rank(self.leaf_bits_b, self.counts_b, bit_index_exclusive);
    }

    pub fn selectA(self: *const Self, rank_zero_based: u32) ?usize {
        return self.select(self.leaf_bits_a, self.counts_a, rank_zero_based);
    }

    pub fn selectB(self: *const Self, rank_zero_based: u32) ?usize {
        return self.select(self.leaf_bits_b, self.counts_b, rank_zero_based);
    }

    pub fn shiftBitsBRight(self: *Self, start: usize, end_inclusive: usize) void {
        if (start > end_inclusive) return;
        const carry = self.shiftBitsRight(self.leaf_bits_b, self.counts_b, start, end_inclusive);
        const out_index = end_inclusive + 1;
        if (out_index < self.bit_len) {
            self.setBit(self.leaf_bits_b, self.counts_b, out_index, carry == 1);
        }
    }

    pub fn shiftBitsBLeft(self: *Self, start: usize, end_inclusive: usize) void {
        if (start > end_inclusive) return;
        const carry = self.shiftBitsLeft(self.leaf_bits_b, self.counts_b, start, end_inclusive);
        if (start > 0) {
            const out_index = start - 1;
            self.setBit(self.leaf_bits_b, self.counts_b, out_index, carry == 1);
        }
    }

    fn setBit(self: *Self, leaf_bits: []u128, counts: []u32, bit_index: usize, value: bool) void {
        const leaf = bit_index / leaf_bits_len;
        const offset = bit_index % leaf_bits_len;
        const mask = @as(u128, 1) << @intCast(offset);
        const old = (leaf_bits[leaf] & mask) != 0;
        if (old == value) return;

        if (value) {
            leaf_bits[leaf] |= mask;
        } else {
            leaf_bits[leaf] &= ~mask;
        }

        const delta: i32 = if (value) 1 else -1;
        var level: usize = 0;
        var index = leaf;
        while (true) {
            const ptr = &counts[self.level_offsets[level] + index];
            ptr.* = @intCast(@as(i32, @intCast(ptr.*)) + delta);
            if (level + 1 == self.level_count) break;
            index /= fanout;
            level += 1;
        }
    }

    fn applyLeafDelta(self: *Self, counts: []u32, leaf: usize, delta: i32) void {
        if (delta == 0) return;

        var level: usize = 0;
        var index = leaf;
        while (true) {
            const ptr = &counts[self.level_offsets[level] + index];
            ptr.* = @intCast(@as(i32, @intCast(ptr.*)) + delta);
            if (level + 1 == self.level_count) break;
            index /= fanout;
            level += 1;
        }
    }

    fn segmentMask(seg_lo: usize, seg_hi: usize) u128 {
        const width = seg_hi - seg_lo + 1;
        if (width >= 128) return ~@as(u128, 0);
        return (@as(u128, 1) << @intCast(width)) - 1 << @intCast(seg_lo);
    }

    fn shiftBitsRight(self: *Self, leaf_bits: []u128, counts: []u32, start: usize, end_inclusive: usize) u1 {
        const word_start = start / leaf_bits_len;
        const word_end = end_inclusive / leaf_bits_len;
        const bit_start = start % leaf_bits_len;
        const bit_end = end_inclusive % leaf_bits_len;

        var carry: u1 = 0;
        var w: usize = word_start;
        while (w <= word_end) : (w += 1) {
            const seg_lo = if (w == word_start) bit_start else 0;
            const seg_hi = if (w == word_end) bit_end else (leaf_bits_len - 1);
            const mask = segmentMask(seg_lo, seg_hi);
            const word = leaf_bits[w];
            const segment = word & mask;
            const old_count: i32 = @intCast(@popCount(segment));
            const carry_out: u1 = @intCast((segment >> @intCast(seg_hi)) & 1);
            var shifted = (segment << 1) & mask;
            if (carry == 1) {
                shifted |= @as(u128, 1) << @intCast(seg_lo);
            }
            leaf_bits[w] = (word & ~mask) | shifted;
            const new_count: i32 = @intCast(@popCount(shifted));
            self.applyLeafDelta(counts, w, new_count - old_count);
            carry = carry_out;
        }
        return carry;
    }

    fn shiftBitsLeft(self: *Self, leaf_bits: []u128, counts: []u32, start: usize, end_inclusive: usize) u1 {
        const word_start = start / leaf_bits_len;
        const word_end = end_inclusive / leaf_bits_len;
        const bit_start = start % leaf_bits_len;
        const bit_end = end_inclusive % leaf_bits_len;

        var carry: u1 = 0;
        var w: usize = word_end;
        while (true) {
            const seg_lo = if (w == word_start) bit_start else 0;
            const seg_hi = if (w == word_end) bit_end else (leaf_bits_len - 1);
            const mask = segmentMask(seg_lo, seg_hi);
            const word = leaf_bits[w];
            const segment = word & mask;
            const old_count: i32 = @intCast(@popCount(segment));
            const carry_out: u1 = @intCast((segment >> @intCast(seg_lo)) & 1);
            var shifted = (segment >> 1) & mask;
            if (carry == 1) {
                shifted |= @as(u128, 1) << @intCast(seg_hi);
            }
            leaf_bits[w] = (word & ~mask) | shifted;
            const new_count: i32 = @intCast(@popCount(shifted));
            self.applyLeafDelta(counts, w, new_count - old_count);
            carry = carry_out;
            if (w == word_start) break;
            w -= 1;
        }
        return carry;
    }

    fn rank(self: *const Self, leaf_bits: []const u128, counts: []const u32, bit_index_exclusive: usize) u32 {
        const clamped = @min(bit_index_exclusive, self.bit_len);
        if (clamped == 0) return 0;

        const leaf = clamped / leaf_bits_len;
        const offset = clamped % leaf_bits_len;
        const leaf_count = leaf_bits.len;

        var total: u32 = 0;
        if (leaf > 0) {
            total += rankLeaves(self, counts, leaf);
        }

        if (leaf < leaf_count) {
            const mask = if (offset == 0) 0 else (@as(u128, 1) << @intCast(offset)) - 1;
            total += @intCast(@popCount(leaf_bits[leaf] & mask));
        }

        return total;
    }

    fn rankLeaves(self: *const Self, counts: []const u32, leaf_index_exclusive: usize) u32 {
        var total: u32 = 0;
        var level = self.level_count - 1;
        var node_index: usize = 0;
        var node_start_leaf: usize = 0;

        while (level > 0) : (level -= 1) {
            const child_leafs: usize = self.leaf_span_per_level[level - 1];
            const child = (leaf_index_exclusive - node_start_leaf) / child_leafs;
            const child_base = node_index * fanout;

            var i: usize = 0;
            while (i < child) : (i += 1) {
                total += counts[self.level_offsets[level - 1] + child_base + i];
            }

            node_index = child_base + child;
            node_start_leaf += child * child_leafs;
        }

        return total;
    }

    fn select(self: *const Self, leaf_bits: []const u128, counts: []const u32, rank_zero_based: u32) ?usize {
        if (rank_zero_based >= counts[self.level_offsets[self.level_count - 1]]) return null;

        var level = self.level_count - 1;
        var node_index: usize = 0;
        var node_start_leaf: usize = 0;
        var target_rank: u32 = rank_zero_based;

        while (level > 0) : (level -= 1) {
            const child_leafs: usize = self.leaf_span_per_level[level - 1];
            const child_base = node_index * fanout;

            var child: usize = 0;
            var accum: u32 = 0;
            while (child < fanout) : (child += 1) {
                const child_count = counts[self.level_offsets[level - 1] + child_base + child];
                if (accum + child_count > target_rank) break;
                accum += child_count;
            }

            target_rank -= accum;
            node_index = child_base + child;
            node_start_leaf += child * child_leafs;
        }

        const leaf = node_start_leaf;
        const bit = selectBitInU128Broadword(leaf_bits[leaf], target_rank) orelse return null;
        return leaf * leaf_bits_len + bit;
    }

    fn computeLevelCount(leaf_count: usize) usize {
        var levels: usize = 1;
        var n = leaf_count;
        while (n > 1) {
            n = (n + (fanout - 1)) / fanout;
            levels += 1;
        }
        return levels;
    }

    fn selectBitInU64Broadword(word: u64, rank_zero_based: u32) ?usize {
        if (word == 0) return null;

        const wanted: u16 = @intCast(rank_zero_based + 1);
        var x = word;
        x = x - ((x >> 1) & 0x5555_5555_5555_5555);
        x = (x & 0x3333_3333_3333_3333) + ((x >> 2) & 0x3333_3333_3333_3333);
        const per_byte = (x + (x >> 4)) & 0x0f0f_0f0f_0f0f_0f0f;
        const cumulative = per_byte * 0x0101_0101_0101_0101;

        var byte_index: usize = 0;
        var previous: u16 = 0;
        while (byte_index < 8) : (byte_index += 1) {
            const cum_byte: u16 = @intCast((cumulative >> @intCast(byte_index * 8)) & 0xff);
            if (cum_byte >= wanted) break;
            previous = cum_byte;
        }
        if (byte_index == 8) return null;

        const rank_in_byte: usize = @intCast(wanted - previous - 1);
        var byte_bits: u8 = @truncate(word >> @intCast(byte_index * 8));
        var remaining = rank_in_byte;
        while (byte_bits != 0) {
            const bit: usize = @intCast(@ctz(byte_bits));
            if (remaining == 0) return byte_index * 8 + bit;
            byte_bits &= byte_bits - 1;
            remaining -= 1;
        }
        return null;
    }

    fn selectBitInU128Broadword(word: u128, rank_zero_based: u32) ?usize {
        const low: u64 = @truncate(word);
        const low_count: u32 = @intCast(@popCount(low));
        if (rank_zero_based < low_count) {
            return selectBitInU64Broadword(low, rank_zero_based);
        }

        const high: u64 = @truncate(word >> 64);
        const bit = selectBitInU64Broadword(high, rank_zero_based - low_count) orelse return null;
        return 64 + bit;
    }
};

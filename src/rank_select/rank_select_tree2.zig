const std = @import("std");

pub const RankSelectTree = struct {
    const leaf_type = u64;
    allocator: std.mem.Allocator,
    bit_len: usize,
    leaf_base: usize,
    leaf_bits: []leaf_type,
    counts: []u32,

    const Self = @This();
    const fanout = 8;

    const leaf_bits_len = @sizeOf(leaf_type) * 8;

    pub fn init(allocator: std.mem.Allocator, bit_len: usize) !Self {
        const raw_leaf_count = (bit_len + (leaf_bits_len - 1)) / leaf_bits_len;
        const leaf_count = @max(raw_leaf_count, 1);
        const padded_leaf_count = nextPowFanout(leaf_count);
        const leaf_base = (padded_leaf_count - 1) / (fanout - 1);
        const total_nodes = leaf_base + padded_leaf_count;

        const counts = try allocator.alloc(u32, total_nodes);
        errdefer allocator.free(counts);
        @memset(counts, 0);

        const leaf_bits = try allocator.alloc(leaf_type, leaf_count);
        errdefer allocator.free(leaf_bits);
        @memset(leaf_bits, 0);

        return .{
            .allocator = allocator,
            .bit_len = bit_len,
            .leaf_base = leaf_base,
            .leaf_bits = leaf_bits,
            .counts = counts,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.counts);
        self.allocator.free(self.leaf_bits);
        self.* = undefined;
    }

    pub fn count(self: *const Self) u32 {
        return self.counts[0];
    }

    pub fn testBit(self: *const Self, bit_index: usize) bool {
        const leaf = bit_index / leaf_bits_len;
        const offset = bit_index % leaf_bits_len;
        return (self.leaf_bits[leaf] & (@as(leaf_type, 1) << @intCast(offset))) != 0;
    }

    pub fn setBit(self: *Self, bit_index: usize, value: bool) void {
        const leaf = bit_index / leaf_bits_len;
        const offset = bit_index % leaf_bits_len;
        const mask = @as(leaf_type, 1) << @intCast(offset);
        const old = (self.leaf_bits[leaf] & mask) != 0;
        if (old == value) return;

        if (value) {
            self.leaf_bits[leaf] |= mask;
        } else {
            self.leaf_bits[leaf] &= ~mask;
        }

        const delta: i32 = if (value) 1 else -1;
        self.applyLeafDelta(leaf, delta);
    }

    pub fn rank(self: *const Self, bit_index_exclusive: usize) u32 {
        const clamped = @min(bit_index_exclusive, self.bit_len);

        const leaf = clamped / leaf_bits_len;
        const offset = clamped % leaf_bits_len;

        var total: u32 = 0;
        if (leaf > 0) {
            var node = self.leaf_base + leaf;
            while (node > 0) {
                const parent = (node - 1) / fanout;
                const child = (node - 1) % fanout;
                const first_child = parent * fanout + 1;

                var i: usize = 0;
                while (i < child) : (i += 1) {
                    total += self.counts[first_child + i];
                }

                node = parent;
            }
        }

        if (offset != 0 and leaf < self.leaf_bits.len) {
            const mask = (@as(leaf_type, 1) << @intCast(offset)) - 1;
            total += @intCast(@popCount(self.leaf_bits[leaf] & mask));
        }

        return total;
    }

    pub fn select(self: *const Self, rank_zero_based: u32) ?usize {
        if (rank_zero_based >= self.counts[0]) return null;

        var node: usize = 0;
        var target_rank = rank_zero_based;
        while (node < self.leaf_base) {
            const first_child = node * fanout + 1;

            var child: usize = 0;
            while (child < fanout) : (child += 1) {
                const child_count = self.counts[first_child + child];
                if (target_rank < child_count) break;
                target_rank -= child_count;
            }
            if (child == fanout) return null;

            node = first_child + child;
        }

        const leaf = node - self.leaf_base;
        if (leaf >= self.leaf_bits.len) return null;

        const bit = selectBitInLeafTypeBroadword(self.leaf_bits[leaf], target_rank) orelse return null;
        const absolute_bit = leaf * leaf_bits_len + bit;
        if (absolute_bit >= self.bit_len) return null;
        return absolute_bit;
    }

    pub fn shiftRight(self: *Self, start: usize, end_inclusive: usize) void {
        if (start > end_inclusive) return;
        const carry = self.innerShiftRight(start, end_inclusive);
        const out_index = end_inclusive + 1;
        if (out_index < self.bit_len) {
            self.setBit(out_index, carry == 1);
        }
    }

    pub fn shiftLeft(self: *Self, start: usize, end_inclusive: usize) void {
        if (start > end_inclusive) return;
        const carry = self.innerShiftLeft(start, end_inclusive);
        if (start > 0) {
            self.setBit(start - 1, carry == 1);
        }
    }

    fn applyLeafDelta(self: *Self, leaf: usize, delta: i32) void {
        if (delta == 0) return;

        var node = self.leaf_base + leaf;
        while (true) {
            const ptr = &self.counts[node];
            ptr.* = ptr.* +% @as(u32, @bitCast(delta));
            if (node == 0) break;
            node = (node - 1) / fanout;
        }
    }

    fn segmentMask(seg_lo: usize, seg_hi: usize) leaf_type {
        const width = seg_hi - seg_lo + 1;
        if (width >= leaf_bits_len) return ~@as(leaf_type, 0);
        return (@as(leaf_type, 1) << @intCast(width)) - 1 << @intCast(seg_lo);
    }

    fn innerShiftRight(self: *Self, start: usize, end_inclusive: usize) u1 {
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
            const word = self.leaf_bits[w];
            const segment = word & mask;
            const old_count: i32 = @intCast(@popCount(segment));
            const carry_out: u1 = @intCast((segment >> @intCast(seg_hi)) & 1);
            var shifted = (segment << 1) & mask;
            if (carry == 1) {
                shifted |= @as(leaf_type, 1) << @intCast(seg_lo);
            }
            self.leaf_bits[w] = (word & ~mask) | shifted;
            const new_count: i32 = @intCast(@popCount(shifted));
            self.applyLeafDelta(w, new_count - old_count);
            carry = carry_out;
        }
        return carry;
    }

    fn innerShiftLeft(self: *Self, start: usize, end_inclusive: usize) u1 {
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
            const word = self.leaf_bits[w];
            const segment = word & mask;
            const old_count: i32 = @intCast(@popCount(segment));
            const carry_out: u1 = @intCast((segment >> @intCast(seg_lo)) & 1);
            var shifted = (segment >> 1) & mask;
            if (carry == 1) {
                shifted |= @as(leaf_type, 1) << @intCast(seg_hi);
            }
            self.leaf_bits[w] = (word & ~mask) | shifted;
            const new_count: i32 = @intCast(@popCount(shifted));
            self.applyLeafDelta(w, new_count - old_count);
            carry = carry_out;
            if (w == word_start) break;
            w -= 1;
        }
        return carry;
    }

    fn nextPowFanout(n: usize) usize {
        var p: usize = 1;
        while (p < n) {
            p *= fanout;
        }
        return p;
    }

    fn selectBitInU64Broadword(word: u64, rank_zero_based: u32) ?usize {
        if (word == 0) return null;

        const wanted: u16 = @intCast(rank_zero_based + 1);
        var x = word;
        x = x - ((x >> 1) & 0x5555_5555_5555_5555);
        x = (x & 0x3333_3333_3333_3333) + ((x >> 2) & 0x3333_3333_3333_3333);
        const per_byte = (x + (x >> 4)) & 0x0f0f_0f0f_0f0f_0f0f;
        const cumulative = per_byte *% 0x0101_0101_0101_0101;

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

    fn selectBitInLeafTypeBroadword(word: leaf_type, rank_zero_based: u32) ?usize {
        if (leaf_type == u64) {
            return selectBitInU64Broadword(word, rank_zero_based);
        } else {
            const low: u64 = @truncate(word);
            const low_count: u32 = @intCast(@popCount(low));
            if (rank_zero_based < low_count) {
                return selectBitInU64Broadword(low, rank_zero_based);
            }

            const high: u64 = @truncate(word >> 64);
            const bit = selectBitInU64Broadword(high, rank_zero_based - low_count) orelse return null;
            return 64 + bit;
        }
    }
};

fn naiveRank(bits: []const bool, bit_index_exclusive: usize) u32 {
    const clamped = @min(bit_index_exclusive, bits.len);
    var total: u32 = 0;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (bits[i]) total += 1;
    }
    return total;
}

fn naiveSelect(bits: []const bool, rank_zero_based: u32) ?usize {
    var remaining = rank_zero_based;
    var i: usize = 0;
    while (i < bits.len) : (i += 1) {
        if (!bits[i]) continue;
        if (remaining == 0) return i;
        remaining -= 1;
    }
    return null;
}

fn naiveShiftRight(bits: []bool, start: usize, end_inclusive: usize) void {
    if (start > end_inclusive) return;
    var carry: bool = false;
    var i: usize = start;
    while (i <= end_inclusive) : (i += 1) {
        const next_carry = bits[i];
        bits[i] = carry;
        carry = next_carry;
    }
    const out_index = end_inclusive + 1;
    if (out_index < bits.len) bits[out_index] = carry;
}

fn naiveShiftLeft(bits: []bool, start: usize, end_inclusive: usize) void {
    if (start > end_inclusive) return;
    var carry: bool = false;
    var i: usize = end_inclusive + 1;
    while (i > start) {
        i -= 1;
        const next_carry = bits[i];
        bits[i] = carry;
        carry = next_carry;
    }
    if (start > 0) bits[start - 1] = carry;
}

fn assertTreeEquals(tree: *const RankSelectTree, bits: []const bool) !void {
    try std.testing.expectEqual(@as(u32, @intCast(naiveRank(bits, bits.len))), tree.count());

    var i: usize = 0;
    while (i < bits.len) : (i += 1) {
        try std.testing.expectEqual(bits[i], tree.testBit(i));
    }

    i = 0;
    while (i <= bits.len) : (i += 1) {
        try std.testing.expectEqual(naiveRank(bits, i), tree.rank(i));
    }

    const total = tree.count();
    var r: u32 = 0;
    while (r < total) : (r += 1) {
        try std.testing.expectEqual(naiveSelect(bits, r), tree.select(r));
    }
    try std.testing.expectEqual(@as(?usize, null), tree.select(total));
}

fn nowNs() u64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const sec: u64 = @intCast(tv.sec);
    const usec: u64 = @intCast(tv.usec);
    return sec * std.time.ns_per_s + usec * std.time.ns_per_us;
}

test "rank_select_tree set/rank/select matches naive model" {
    const allocator = std.testing.allocator;
    const bit_len: usize = 777;
    var tree_a = try RankSelectTree.init(allocator, bit_len);
    defer tree_a.deinit();
    var tree_b = try RankSelectTree.init(allocator, bit_len);
    defer tree_b.deinit();

    const bits_a = try allocator.alloc(bool, bit_len);
    defer allocator.free(bits_a);
    @memset(bits_a, false);

    const bits_b = try allocator.alloc(bool, bit_len);
    defer allocator.free(bits_b);
    @memset(bits_b, false);

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    for (0..4000) |_| {
        const idx = random.uintLessThan(usize, bit_len);
        const set_a = random.boolean();
        const set_b = random.boolean();
        if (set_a) {
            tree_a.setBit(idx, true);
        } else {
            tree_a.setBit(idx, false);
        }
        if (set_b) {
            tree_b.setBit(idx, true);
        } else {
            tree_b.setBit(idx, false);
        }
        bits_a[idx] = set_a;
        bits_b[idx] = set_b;
    }

    try assertTreeEquals(&tree_a, bits_a);
    try assertTreeEquals(&tree_b, bits_b);
}

test "rank_select_tree shift helpers match naive model" {
    const allocator = std.testing.allocator;
    const bit_len: usize = 513;
    var tree = try RankSelectTree.init(allocator, bit_len);
    defer tree.deinit();

    const bits = try allocator.alloc(bool, bit_len);
    defer allocator.free(bits);
    @memset(bits, false);

    for (0..bit_len) |i| {
        const value = (i % 3) == 0 or (i % 11) == 0;
        if (value) {
            tree.setBit(i, true);
        } else {
            tree.setBit(i, false);
        }
        bits[i] = value;
    }

    const start: usize = 17;
    const end_inclusive: usize = bit_len - 9;
    tree.shiftRight(start, end_inclusive);
    naiveShiftRight(bits, start, end_inclusive);

    tree.shiftLeft(start + 3, end_inclusive - 5);
    naiveShiftLeft(bits, start + 3, end_inclusive - 5);

    try assertTreeEquals(&tree, bits);
}

test "benchmark rank_select_tree set/rank/select" {
    const allocator = std.testing.allocator;
    const bit_len: usize = 1 << 20;
    var tree = try RankSelectTree.init(allocator, bit_len);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(0xA11CE5EED);
    const random = prng.random();

    var t0 = nowNs();
    for (0..bit_len) |i| {
        if (random.boolean()) {
            tree.setBit(i, true);
        } else {
            tree.setBit(i, false);
        }
    }
    const set_ns = nowNs() - t0;

    t0 = nowNs();
    var rank_accum: u64 = 0;
    for (0..200_000) |_| {
        rank_accum +%= tree.rank(random.uintLessThan(usize, bit_len));
    }
    const rank_ns = nowNs() - t0;

    const total = tree.count();
    t0 = nowNs();
    var sel_accum: u64 = 0;
    for (0..200_000) |_| {
        if (total == 0) break;
        const r = random.uintLessThan(u32, total);
        sel_accum +%= @as(u64, @intCast(tree.select(r) orelse 0));
    }
    const select_ns = nowNs() - t0;

    std.mem.doNotOptimizeAway(rank_accum);
    std.mem.doNotOptimizeAway(sel_accum);

    std.debug.print(
        "bench rank_select_tree: set={d}ns rank={d}ns select={d}ns count={d}\n",
        .{ set_ns, rank_ns, select_ns, total },
    );
}

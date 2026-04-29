// RSQF-style bucketed hash map.
//
// Layout: bucket_size slots per bucket, slots_per_block slots per metadata block.
// Each Block packs the start/end bitmaps, the RSQF offset, and the tag bytes for
// 64 slots into a single ~96-byte struct, so a lookup that needs rank/select on
// the run bounds + a SIMD tag scan can do it from one cache-resident block.
//
// Keys are kept sorted by home bucket: a key whose home is bucket b is stored
// in the contiguous run [run_start_b, run_end_b]. run_end_b is selected by
// rank/select; run_start_b is the previous run's end + 1, clamped to b * 16.
//
// This is where RSQF actually earns its keep: the run length is bounded by
// the number of keys hashing to b plus modest spillage, so lookups (especially
// misses) stay fast even as the load factor approaches the structural ceiling.
const std = @import("std");
const builtin = @import("builtin");

// BMI2 PDEP+TZCNT gives O(1) bit-select. On Zen 3+ and Haswell+ this is ~3 cycles
// and dramatically beats the broadword fallback for our rank/select hot path.
// Zen 1/2 microcodes PDEP (slow) so we only enable on machines where it's actually
// fast — which here means anything that advertises BMI2 *and* is not pre-Zen3 AMD.
// (Zig doesn't expose Zen-version granularity easily, but the common deployment
//  targets that advertise BMI2 in 2025 all have fast PDEP, so gate on bmi2 alone.)
const has_fast_pdep = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    break :blk std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
};

inline fn pdep64(src: u64, mask: u64) u64 {
    return asm ("pdepq %[mask], %[src], %[ret]"
        : [ret] "=r" (-> u64),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}

// Returns the bit position of the (k+1)-th set bit in `word` (0-indexed), or 64
// if `word` has fewer than k+1 set bits.
//
// Fast path: PDEP isolates the target bit, TZCNT reads its position. ~3 cycles.
// Fallback: clear-lowest-bit loop. Optimal for small k, which is what we get
// here (rank within a block is bounded by the number of home positions per block).
inline fn selectU64(word: u64, k: u32) usize {
    if (comptime has_fast_pdep) {
        const isolated = pdep64(@as(u64, 1) << @intCast(k), word);
        if (isolated == 0) return 64;
        return @intCast(@ctz(isolated));
    }
    if (word == 0) return 64;
    var w = word;
    var i: u32 = 0;
    while (i < k) : (i += 1) {
        w &= w - 1;
        if (w == 0) return 64;
    }
    return @intCast(@ctz(w));
}

pub fn QfRsqfBucketMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        blocks: []align(64) Block,
        tags: []align(16) u8,
        entries: []Entry,
        cap: usize,
        slots_len: usize,
        rs_len: usize,
        len: usize,

        const Self = @This();
        const Entry = struct { key: K, value: V };

        const bucket_size = 16;
        const slots_per_block = 64;
        const max_load_num = 7;
        const max_load_den = 8;
        const min_overflow_slots = 64;
        const max_overflow_slots = 255;
        const rs_padding_slots = max_overflow_slots;

        // 32 bytes per block — 2 blocks per cache line. Tags live in a separate
        // SIMD-aligned array so the metadata stays dense.
        const Block = extern struct {
            starts: u64,
            ends: u64,
            offset: u32,
            _pad: [12]u8,
        };

        pub const empty: Self = .{
            .blocks = &.{},
            .tags = &.{},
            .entries = &.{},
            .cap = 0,
            .slots_len = 0,
            .rs_len = 0,
            .len = 0,
        };

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, expected_items: usize) !void {
            try self.ensureCapacity(allocator, expected_items);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.cap == 0) return;
            allocator.free(self.blocks);
            allocator.free(self.tags);
            allocator.free(self.entries);
            self.* = empty;
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

            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const home = self.bucketFromHash(hash);
            if (!self.testStart(home)) return false;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return false;
            const run_end = self.runEnd(home);
            const idx = self.findKeyInRun(key, tag, run_start, run_end) orelse return false;

            const single = run_start == run_end;
            if (single) self.setStart(home, false);

            if (idx == run_end) {
                self.setEnd(run_end, false);
                if (!single) self.setEnd(run_end - 1, true);
            }

            var stop = idx + 1;
            while (stop < self.slots_len and self.tags[stop] != 0 and self.homeForIndex(stop) != stop) {
                stop += 1;
            }

            if (stop > idx + 1) {
                const moved = stop - idx - 1;
                @memmove(self.entries[idx .. idx + moved], self.entries[idx + 1 .. idx + 1 + moved]);
                @memmove(self.tags[idx .. idx + moved], self.tags[idx + 1 .. idx + 1 + moved]);
                self.shiftRunEndsLeftByOne(idx + 1, stop - 1);
            }

            const clear_idx = stop - 1;
            self.tags[clear_idx] = 0;
            self.setEnd(clear_idx, false);
            self.decOffsets(home, clear_idx);
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
            while (overflow < target and overflow < max_overflow_slots) overflow *= 2;
            return @min(overflow, max_overflow_slots);
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, new_cap: usize) !void {
            const new_slots_len = new_cap + overflowSlots(new_cap);
            const rs_len = new_slots_len + rs_padding_slots;
            const num_blocks = @max((rs_len + slots_per_block - 1) / slots_per_block, 1);

            const blocks = try allocator.alignedAlloc(Block, .@"64", num_blocks);
            errdefer allocator.free(blocks);
            @memset(std.mem.sliceAsBytes(blocks), 0);

            const tags = try allocator.alignedAlloc(u8, .@"16", new_slots_len);
            errdefer allocator.free(tags);
            @memset(tags, 0);

            const entries = try allocator.alloc(Entry, new_slots_len);
            errdefer allocator.free(entries);

            var new_map = Self{
                .blocks = blocks,
                .tags = tags,
                .entries = entries,
                .cap = new_cap,
                .slots_len = new_slots_len,
                .rs_len = rs_len,
                .len = 0,
            };

            if (self.cap > 0) {
                for (0..self.slots_len) |i| {
                    if (self.tags[i] == 0) continue;
                    const entry = self.entries[i];
                    std.debug.assert(new_map.putAssumeCapacity(entry.key, entry.value));
                }
                allocator.free(self.blocks);
                allocator.free(self.tags);
                allocator.free(self.entries);
            }

            self.* = new_map;
        }

        inline fn bucketFromHash(self: *const Self, hash: u64) usize {
            const bucket_count = self.cap / bucket_size;
            const bucket = @as(usize, @truncate(hash)) & (bucket_count - 1);
            return bucket * bucket_size;
        }

        inline fn tagFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        inline fn loadTagVec(self: *const Self, idx: usize) @Vector(16, u8) {
            std.debug.assert(idx % 16 == 0);
            const ptr: *align(16) const [16]u8 = @alignCast(@ptrCast(self.tags.ptr + idx));
            return ptr.*;
        }

        inline fn testStart(self: *const Self, index: usize) bool {
            const block = &self.blocks[index / slots_per_block];
            return ((block.starts >> @intCast(index % slots_per_block)) & 1) != 0;
        }

        inline fn setStart(self: *Self, index: usize, value: bool) void {
            const block = &self.blocks[index / slots_per_block];
            const mask = @as(u64, 1) << @intCast(index % slots_per_block);
            if (value) block.starts |= mask else block.starts &= ~mask;
        }

        inline fn setEnd(self: *Self, index: usize, value: bool) void {
            const block = &self.blocks[index / slots_per_block];
            const mask = @as(u64, 1) << @intCast(index % slots_per_block);
            if (value) block.ends |= mask else block.ends &= ~mask;
        }

        fn findRunStart(self: *const Self, home: usize) ?usize {
            if (!self.testStart(home)) return null;
            if (home == 0) return 0;
            const block_idx = home / slots_per_block;
            const block_start = block_idx * slots_per_block;
            const shifted_start = block_start + self.blocks[block_idx].offset;
            const prev_end = self.runEnd(home - 1) + 1;
            return @max(prev_end, shifted_start, home);
        }

        fn findKeyInRun(self: *const Self, key: K, tag: u8, run_start: usize, run_end: usize) ?usize {
            const ctx: Context = undefined;
            const tag_lane: @Vector(16, u8) = @splat(tag);

            // Fast path: run fits in one 16-aligned chunk inside one block.
            const run_len = run_end - run_start + 1;
            if (run_start % 16 == 0 and run_start / slots_per_block == run_end / slots_per_block and run_len <= 16) {
                const tags_vec = self.loadTagVec(run_start);
                var matches: u16 = @bitCast(tags_vec == tag_lane);
                // Mask out lanes past run_end.
                const valid_mask: u16 = if (run_len == 16) 0xffff else (@as(u16, 1) << @intCast(run_len)) - 1;
                matches &= valid_mask;
                while (matches != 0) {
                    const lane: usize = @intCast(@ctz(matches));
                    const idx = run_start + lane;
                    if (ctx.eql(self.entries[idx].key, key)) return idx;
                    matches &= matches - 1;
                }
                return null;
            }

            // General path: scan tag-by-tag (run rarely exceeds 16 in practice; this
            // handles the spillover case).
            var idx = run_start;
            while (idx <= run_end) : (idx += 1) {
                if (self.tags[idx] == tag and ctx.eql(self.entries[idx].key, key)) return idx;
            }
            return null;
        }

        const RunBounds = struct { start: usize, end: usize };

        // Single-pass rank/select that returns both run_start and run_end for a home.
        // Avoids walking the runends bitmap twice (once for prev_runend via findRunStart,
        // once for run_end). This is the main reason RSQF lookup pays for itself: one
        // loaded block produces both bounds.
        fn runBounds(self: *const Self, home: usize) ?RunBounds {
            const block_idx = home / slots_per_block;
            const intra = home % slots_per_block;
            const block = &self.blocks[block_idx];

            // Test home occupied + compute intrablock rank (R, including home) in one go.
            const start_mask_inclusive = if (intra + 1 == slots_per_block)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(intra + 1)) - 1;
            const occupieds_inclusive = block.starts & start_mask_inclusive;
            if ((occupieds_inclusive >> @intCast(intra)) & 1 == 0) return null;
            const rank_inclusive: usize = @intCast(@popCount(occupieds_inclusive));
            // rank_inclusive >= 1 because home is occupied.

            const block_offset: usize = block.offset;
            const block_start = block_idx * slots_per_block;
            const shifted_start = block_start + block_offset;

            // Walk runends once, capturing the (R-1)-th and R-th 1-bits.
            const want_end: usize = rank_inclusive - 1; // 0-indexed bit we want
            const want_prev_opt: ?usize = if (rank_inclusive >= 2) rank_inclusive - 2 else null;

            var b_idx = block_idx + block_offset / slots_per_block;
            const initial_ignore = block_offset % slots_per_block;

            var seen: usize = 0;
            var prev_pos: ?usize = null;

            var first_block = true;
            while (b_idx < self.blocks.len) : (b_idx += 1) {
                var word = self.blocks[b_idx].ends;
                if (first_block and initial_ignore != 0) {
                    word &= ~((@as(u64, 1) << @intCast(initial_ignore)) - 1);
                }
                first_block = false;

                const cnt: usize = @intCast(@popCount(word));
                if (seen + cnt <= want_end) {
                    // Run end is past this word. Capture prev if it falls here.
                    if (want_prev_opt) |p| {
                        if (seen + cnt > p and seen <= p) {
                            const k: u32 = @intCast(p - seen);
                            prev_pos = b_idx * slots_per_block + selectU64(word, k);
                        }
                    }
                    seen += cnt;
                    continue;
                }

                // Run end is in this word.
                if (want_prev_opt) |p| {
                    if (prev_pos == null and p >= seen) {
                        const k: u32 = @intCast(p - seen);
                        prev_pos = b_idx * slots_per_block + selectU64(word, k);
                    }
                }

                const k_end: u32 = @intCast(want_end - seen);
                const end_bit = selectU64(word, k_end);
                var run_end_abs = b_idx * slots_per_block + end_bit;
                if (run_end_abs < home) run_end_abs = home;

                const run_start = if (prev_pos) |p|
                    @max(p + 1, home)
                else
                    @max(shifted_start, home);
                return .{ .start = run_start, .end = run_end_abs };
            }
            return null;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const home = self.bucketFromHash(hash);

            const bounds = self.runBounds(home) orelse return null;
            const tag = tagFromHash(hash);
            return self.findKeyInRun(key, tag, bounds.start, bounds.end);
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) bool {
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const home = self.bucketFromHash(hash);
            const tag = tagFromHash(hash);

            const had_run = self.testStart(home);

            const run_start: usize = if (home == 0)
                0
            else blk: {
                const prev_end = self.runEnd(home - 1);
                break :blk @max(home, prev_end + 1);
            };

            var run_end: usize = run_start;
            if (had_run) {
                run_end = self.runEnd(home);
                if (self.findKeyInRun(key, tag, run_start, run_end)) |idx| {
                    self.entries[idx].value = value;
                    return true;
                }
            }

            const insert_pos = if (had_run) run_end + 1 else run_start;
            if (insert_pos - home > max_overflow_slots) return false;

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
                self.shiftRunEndsRightByOne(insert_pos, empty_slot - 1);
            }

            self.entries[insert_pos] = .{ .key = key, .value = value };
            self.tags[insert_pos] = tag;

            if (!had_run) {
                self.setStart(home, true);
            } else {
                self.setEnd(run_end, false);
            }
            self.setEnd(insert_pos, true);
            self.incOffsets(home, empty_slot);
            self.len += 1;
            return true;
        }

        fn findEmptyFrom(self: *const Self, start: usize) ?usize {
            return std.mem.findScalarPos(u8, self.tags, start, 0);
        }

        fn homeForIndex(self: *const Self, idx: usize) usize {
            const run_rank = self.rankEnd(idx);
            return self.selectStart(run_rank) orelse unreachable;
        }

        fn rankEnd(self: *const Self, bit_index_exclusive: usize) u32 {
            const clamped = @min(bit_index_exclusive, self.rs_len);
            const block_stop = clamped / slots_per_block;
            const tail = clamped % slots_per_block;
            var total: u32 = 0;
            var b: usize = 0;
            while (b < block_stop and b < self.blocks.len) : (b += 1) {
                total += @intCast(@popCount(self.blocks[b].ends));
            }
            if (tail != 0 and block_stop < self.blocks.len) {
                const mask = (@as(u64, 1) << @intCast(tail)) - 1;
                total += @intCast(@popCount(self.blocks[block_stop].ends & mask));
            }
            return total;
        }

        fn selectStart(self: *const Self, rank_zero_based: u32) ?usize {
            var remaining = rank_zero_based;
            for (self.blocks, 0..) |*block, block_idx| {
                const word = block.starts;
                const cnt: u32 = @intCast(@popCount(word));
                if (remaining >= cnt) {
                    remaining -= cnt;
                    continue;
                }
                const bit = selectU64(word, remaining);
                if (bit == 64) return null;
                const absolute = block_idx * slots_per_block + bit;
                if (absolute >= self.rs_len) return null;
                return absolute;
            }
            return null;
        }

        fn runEnd(self: *const Self, bucket_index: usize) usize {
            std.debug.assert(bucket_index < self.rs_len);

            const bucket_block_index = bucket_index / slots_per_block;
            const bucket_intra = bucket_index % slots_per_block;
            const block = &self.blocks[bucket_block_index];
            const bucket_blocks_offset: usize = block.offset;

            const start_mask = if (bucket_intra + 1 == slots_per_block)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(bucket_intra + 1)) - 1;
            const occupieds = block.starts & start_mask;
            const intrablock_rank: usize = @intCast(@popCount(occupieds));

            if (intrablock_rank == 0) {
                if (bucket_blocks_offset <= bucket_intra) return bucket_index;
                return bucket_block_index * slots_per_block + bucket_blocks_offset - 1;
            }

            var runend_block_index = bucket_block_index + bucket_blocks_offset / slots_per_block;
            var runend_ignore_bits = bucket_blocks_offset % slots_per_block;
            var runend_rank = intrablock_rank - 1;

            var runend_block_offset = selectFromOffset(self.blocks[runend_block_index].ends, runend_ignore_bits, runend_rank);
            while (runend_block_offset == slots_per_block) {
                const ends_word = self.blocks[runend_block_index].ends;
                const consumed_mask = if (runend_ignore_bits == 0)
                    @as(u64, 0)
                else
                    (@as(u64, 1) << @intCast(runend_ignore_bits)) - 1;
                const remaining = ends_word & ~consumed_mask;
                const consumed: usize = @intCast(@popCount(remaining));
                if (runend_rank < consumed) break;
                runend_rank -= consumed;
                runend_block_index += 1;
                runend_ignore_bits = 0;
                if (runend_block_index >= self.blocks.len) return bucket_index;
                runend_block_offset = selectFromOffset(self.blocks[runend_block_index].ends, runend_ignore_bits, runend_rank);
            }

            const runend_index = slots_per_block * runend_block_index + runend_block_offset;
            return if (runend_index < bucket_index) bucket_index else runend_index;
        }

        fn shiftRunEndsRightByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;
            const first_word = start / slots_per_block;
            const last_word = (end_inclusive + 1) / slots_per_block;
            var w = last_word + 1;
            while (w > first_word) {
                w -= 1;
                const lo: usize = if (w == first_word) (start % slots_per_block) + 1 else 0;
                const hi_excl: usize = if (w == last_word)
                    ((end_inclusive + 1) % slots_per_block) + 1
                else
                    slots_per_block;
                if (lo >= hi_excl) continue;
                const seg_mask = bitRangeMask(lo, hi_excl);
                const old_word = self.blocks[w].ends;
                var shifted = (old_word << 1) & seg_mask;
                if (lo == 0 and w > 0) shifted |= ((self.blocks[w - 1].ends >> 63) & 1);
                self.blocks[w].ends = (old_word & ~seg_mask) | shifted;
            }
            self.setEnd(start, false);
        }

        fn shiftRunEndsLeftByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;
            std.debug.assert(start > 0);
            const first_word = (start - 1) / slots_per_block;
            const last_word = (end_inclusive - 1) / slots_per_block;
            var w = first_word;
            while (w <= last_word) : (w += 1) {
                const lo: usize = if (w == first_word) (start - 1) % slots_per_block else 0;
                const hi_excl: usize = if (w == last_word)
                    ((end_inclusive - 1) % slots_per_block) + 1
                else
                    slots_per_block;
                if (lo >= hi_excl) continue;
                const seg_mask = bitRangeMask(lo, hi_excl);
                const old_word = self.blocks[w].ends;
                var shifted = (old_word >> 1) & seg_mask;
                if (hi_excl == slots_per_block and w + 1 < self.blocks.len) {
                    shifted |= ((self.blocks[w + 1].ends & 1) << 63) & seg_mask;
                }
                self.blocks[w].ends = (old_word & ~seg_mask) | shifted;
            }
            self.setEnd(end_inclusive, false);
        }

        fn bitRangeMask(lo: usize, hi_excl: usize) u64 {
            if (lo >= hi_excl) return 0;
            const low_mask: u64 = if (lo == 0) 0 else (@as(u64, 1) << @intCast(lo)) - 1;
            const high_mask: u64 = if (hi_excl >= slots_per_block)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(hi_excl)) - 1;
            return high_mask & ~low_mask;
        }

        fn incOffsets(self: *Self, start_bucket: usize, end_bucket: usize) void {
            const original_block = start_bucket / slots_per_block;
            const last_affected_block = end_bucket / slots_per_block;
            if (last_affected_block <= original_block) return;
            for (original_block + 1..last_affected_block + 1) |b| {
                if (b < self.blocks.len) self.blocks[b].offset = self.blocks[b].offset +| 1;
            }
        }

        fn decOffsets(self: *Self, start_bucket: usize, end_bucket: usize) void {
            const original_block = start_bucket / slots_per_block;
            const last_affected_block = end_bucket / slots_per_block;
            if (last_affected_block <= original_block) return;
            for (original_block + 1..last_affected_block + 1) |b| {
                if (b < self.blocks.len and self.blocks[b].offset > 0) self.blocks[b].offset -= 1;
            }
        }

        fn selectFromOffset(word: u64, ignore_bits: usize, rank_zero_based: usize) usize {
            const masked = if (ignore_bits == 0) word else word & ~((@as(u64, 1) << @intCast(ignore_bits)) - 1);
            return selectU64(masked, @intCast(rank_zero_based));
        }

    };
}

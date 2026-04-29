const std = @import("std");

pub fn QfBlocksBucketHashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        entries: []Entry,
        tags: []u8,
        starts: []u64,
        ends: []u64,
        offsets: []u8,
        cap: usize,
        slots_len: usize,
        rs_len: usize,
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
        const rs_padding_slots = max_overflow_slots;
        const tag_scan_chunk = @max(std.simd.suggestVectorLength(u8) orelse 1, @sizeOf(usize));
        const bucket_size = 16;

        const bits_per_block = 64;

        pub const empty: Self = .{
            .entries = &.{},
            .tags = &.{},
            .starts = &.{},
            .ends = &.{},
            .offsets = &.{},
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
            allocator.free(self.entries);
            allocator.free(self.tags);
            allocator.free(self.starts);
            allocator.free(self.ends);
            allocator.free(self.offsets);
            self.* = .{
                .entries = &.{},
                .tags = &.{},
                .starts = &.{},
                .ends = &.{},
                .offsets = &.{},
                .cap = 0,
                .slots_len = 0,
                .rs_len = 0,
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
                if (self.putAssumeCapacity(key, value)) {
                    return;
                }

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
            while (stop < self.slots_len and self.isSlotOccupied(stop) and self.homeForIndex(stop) != stop) {
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
            while (overflow < target and overflow < max_overflow_slots) {
                overflow *= 2;
            }
            return @min(overflow, max_overflow_slots);
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, new_cap: usize) !void {
            const new_slots_len = new_cap + overflowSlots(new_cap);
            const rs_len = new_slots_len + rs_padding_slots;
            const num_blocks = @max((rs_len + bits_per_block - 1) / bits_per_block, 1);

            var new_map = Self{
                .entries = try allocator.alloc(Entry, new_slots_len),
                .tags = try allocator.alloc(u8, new_slots_len),
                .starts = try allocator.alloc(u64, num_blocks),
                .ends = try allocator.alloc(u64, num_blocks),
                .offsets = try allocator.alloc(u8, num_blocks),
                .cap = new_cap,
                .slots_len = new_slots_len,
                .rs_len = rs_len,
                .len = 0,
            };
            errdefer {
                allocator.free(new_map.entries);
                allocator.free(new_map.tags);
                allocator.free(new_map.starts);
                allocator.free(new_map.ends);
                allocator.free(new_map.offsets);
            }
            @memset(new_map.tags, 0);
            @memset(new_map.starts, 0);
            @memset(new_map.ends, 0);
            @memset(new_map.offsets, 0);
            new_map.offsets[0] = 0;

            if (self.cap > 0) {
                for (0..self.slots_len) |i| {
                    if (!self.isSlotOccupied(i)) continue;
                    const entry = self.entries[i];
                    std.debug.assert(new_map.putAssumeCapacity(entry.key, entry.value));
                }

                allocator.free(self.entries);
                allocator.free(self.tags);
                allocator.free(self.starts);
                allocator.free(self.ends);
                allocator.free(self.offsets);
            }

            self.* = new_map;
        }

        fn bucketFromHash(self: *const Self, hash: u64) usize {
            const bucket_count = self.cap / bucket_size;
            const bucket = @as(usize, @truncate(hash)) & (bucket_count - 1);
            return bucket * bucket_size;
        }

        fn tagFromHash(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        fn isSlotOccupied(self: *const Self, idx: usize) bool {
            return self.tags[idx] != 0;
        }

        fn homeForIndex(self: *const Self, idx: usize) usize {
            const run_rank = self.rankEnd(idx);
            return self.selectStart(run_rank) orelse unreachable;
        }

        fn findEmptyFrom(self: *const Self, start: usize) ?usize {
            return std.mem.findScalarPos(u8, self.tags, start, 0);
        }

        fn findRunStart(self: *const Self, home: usize) ?usize {
            if (!self.testStart(home)) return null;
            if (home == 0) return 0;

            const block_index = home / bits_per_block;
            const block_start = block_index * bits_per_block;
            const shifted_start = block_start + self.offsets[block_index];

            const run_start = self.runEnd(home - 1) + 1;
            return @max(run_start, shifted_start, home);
        }

        fn shiftRunEndsRightByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;

            const first_word = start / bits_per_block;
            const last_word = (end_inclusive + 1) / bits_per_block;

            var w = last_word + 1;
            while (w > first_word) {
                w -= 1;

                const lo: usize = if (w == first_word) (start % bits_per_block) + 1 else 0;
                const hi_excl: usize = if (w == last_word)
                    ((end_inclusive + 1) % bits_per_block) + 1
                else
                    bits_per_block;
                if (lo >= hi_excl) continue;

                const seg_mask = bitRangeMask(lo, hi_excl);
                const old_word = self.ends[w];
                var shifted = (old_word << 1) & seg_mask;

                if (lo == 0 and w > 0) {
                    shifted |= ((self.ends[w - 1] >> 63) & 1);
                }

                self.ends[w] = (old_word & ~seg_mask) | shifted;
            }

            setBit(self.ends, start, false);
        }

        fn shiftRunEndsLeftByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;
            std.debug.assert(start > 0);

            const first_word = (start - 1) / bits_per_block;
            const last_word = (end_inclusive - 1) / bits_per_block;

            var w = first_word;
            while (w <= last_word) : (w += 1) {
                const lo: usize = if (w == first_word) (start - 1) % bits_per_block else 0;
                const hi_excl: usize = if (w == last_word)
                    ((end_inclusive - 1) % bits_per_block) + 1
                else
                    bits_per_block;
                if (lo >= hi_excl) continue;

                const seg_mask = bitRangeMask(lo, hi_excl);
                const old_word = self.ends[w];
                var shifted = (old_word >> 1) & seg_mask;

                if (hi_excl == bits_per_block and w + 1 < self.ends.len) {
                    shifted |= ((self.ends[w + 1] & 1) << 63) & seg_mask;
                }

                self.ends[w] = (old_word & ~seg_mask) | shifted;
            }

            setBit(self.ends, end_inclusive, false);
        }

        fn bitRangeMask(lo: usize, hi_excl: usize) u64 {
            if (lo >= hi_excl) return 0;

            const low_mask: u64 = if (lo == 0)
                0
            else
                (@as(u64, 1) << @intCast(lo)) - 1;
            const high_mask: u64 = if (hi_excl >= bits_per_block)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(hi_excl)) - 1;
            return high_mask & ~low_mask;
        }

        fn setBitWords(words: []u64, index: usize, value: bool) void {
            const w = index / 64;
            const b = index % 64;
            const mask = @as(u64, 1) << @intCast(b);
            if (value) {
                words[w] |= mask;
            } else {
                words[w] &= ~mask;
            }
        }

        fn testBitWords(words: []const u64, index: usize) bool {
            const w = index / 64;
            const b = index % 64;
            return ((words[w] >> @intCast(b)) & 1) != 0;
        }

        fn findKeyInRun(self: *const Self, key: K, tag: u8, run_start: usize, run_end: usize) ?usize {
            const ctx: Context = undefined;

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
                        if (ctx.eql(self.entries[candidate].key, key)) return candidate;
                        matches &= matches - 1;
                    }
                }
            }

            while (idx <= run_end) : (idx += 1) {
                if (self.tags[idx] == tag and ctx.eql(self.entries[idx].key, key)) return idx;
            }
            return null;
        }

        fn findIndex(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;

            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const home = self.bucketFromHash(hash);
            if (!self.testStart(home)) return null;

            const tag = tagFromHash(hash);

            const home_tag = self.tags[home];

            // Common fast path: exact key is in canonical slot.
            if (home_tag != 0 and home_tag == tag and ctx.eql(self.entries[home].key, key)) {
                return home;
            }

            const run_start = self.findRunStart(home) orelse return null;
            const run_end = self.runEnd(home);
            return self.findKeyInRun(key, tag, run_start, run_end);
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) bool {
            const ctx: Context = undefined;
            const hash = ctx.hash(key);
            const home = self.bucketFromHash(hash);
            const tag = tagFromHash(hash);
            const home_tag = self.tags[home];

            if (home_tag == 0) {
                self.entries[home] = .{ .key = key, .value = value };
                self.tags[home] = tag;
                self.setStart(home, true);
                self.setEnd(home, true);
                self.incOffsets(home, home);
                self.len += 1;
                return true;
            }

            // Common fast path: update value in canonical slot.
            if (home_tag == tag and ctx.eql(self.entries[home].key, key)) {
                self.entries[home].value = value;
                return true;
            }

            const had_run = self.testStart(home);
            const run_start = if (home == 0)
                @as(usize, 0)
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

        inline fn testStart(self: *const Self, index: usize) bool {
            return testBit(self.starts, index);
        }

        inline fn setStart(self: *Self, index: usize, comptime value: bool) void {
            setBit(self.starts, index, value);
        }

        inline fn setEnd(self: *Self, index: usize, comptime value: bool) void {
            setBit(self.ends, index, value);
        }

        inline fn rankEnd(self: *const Self, bit_index_exclusive: usize) u32 {
            return rankBits(self.ends, self.rs_len, bit_index_exclusive);
        }

        inline fn selectStart(self: *const Self, rank_zero_based: u32) ?usize {
            return selectBits(self.starts, self.rs_len, rank_zero_based);
        }

        fn runEnd(self: *const Self, bucket_index: usize) usize {
            std.debug.assert(bucket_index < self.rs_len);

            const bucket_block_index = bucket_index / bits_per_block;
            const bucket_intrablock_offset = bucket_index % bits_per_block;
            const bucket_blocks_offset = self.offsets[bucket_block_index];

            const start_mask = if (bucket_intrablock_offset + 1 == bits_per_block)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(bucket_intrablock_offset + 1)) - 1;
            const occupieds = self.starts[bucket_block_index] & start_mask;
            const bucket_intrablock_rank: usize = @intCast(@popCount(occupieds));

            if (bucket_intrablock_rank == 0) {
                if (bucket_blocks_offset <= bucket_intrablock_offset) {
                    return bucket_index;
                }
                return bucket_block_index * bits_per_block + bucket_blocks_offset - 1;
            }

            var runend_block_index = bucket_block_index + bucket_blocks_offset / bits_per_block;
            var runend_ignore_bits = bucket_blocks_offset % bits_per_block;
            var runend_rank = bucket_intrablock_rank - 1;

            var runend_block_offset = selectFromOffset(self.ends[runend_block_index], runend_ignore_bits, runend_rank);
            while (runend_block_offset == bits_per_block) {
                const runends = self.ends[runend_block_index];
                const consumed_mask = if (runend_ignore_bits == 0)
                    @as(u64, 0)
                else
                    (@as(u64, 1) << @intCast(runend_ignore_bits)) - 1;
                const remaining = runends & ~consumed_mask;
                const consumed: usize = @intCast(@popCount(remaining));

                if (runend_rank < consumed) break;
                runend_rank -= consumed;
                runend_block_index += 1;
                runend_ignore_bits = 0;
                if (runend_block_index >= self.ends.len) return bucket_index;
                runend_block_offset = selectFromOffset(self.ends[runend_block_index], runend_ignore_bits, runend_rank);
            }

            const runend_index = bits_per_block * runend_block_index + runend_block_offset;
            return if (runend_index < bucket_index) bucket_index else runend_index;
        }

        fn adjustBlockOffset(self: *Self, block_index: usize, inc: bool) void {
            const block = block_index % self.offsets.len;
            const current = self.offsets[block];
            const new_value: u8 = if (inc)
                current +| 1
            else
                current -| 1;
            self.offsets[block] = new_value;
        }

        fn incOffsets(self: *Self, start_bucket: usize, end_bucket: usize) void {
            const original_block = start_bucket / bits_per_block;
            const last_affected_block = end_bucket / bits_per_block;
            if (last_affected_block <= original_block) return;

            for (original_block + 1..last_affected_block + 1) |b| {
                self.adjustBlockOffset(b, true);
            }
        }

        fn decOffsets(self: *Self, start_bucket: usize, end_bucket: usize) void {
            const original_block = start_bucket / bits_per_block;
            const last_affected_block = end_bucket / bits_per_block;
            if (last_affected_block <= original_block) return;

            for (original_block + 1..last_affected_block + 1) |b| {
                self.adjustBlockOffset(b, false);
            }
        }

        fn testBit(bits: []const u64, index: usize) bool {
            const block_index = index / bits_per_block;
            const bit_index = index % bits_per_block;
            const mask = @as(u64, 1) << @intCast(bit_index);
            return (bits[block_index] & mask) != 0;
        }

        fn setBit(bits: []u64, index: usize, comptime value: bool) void {
            const block_index = index / bits_per_block;
            const bit_index = index % bits_per_block;
            const mask = @as(u64, 1) << @intCast(bit_index);
            if (value) {
                bits[block_index] |= mask;
            } else {
                bits[block_index] &= ~mask;
            }
        }

        fn rankBits(bits: []const u64, bit_len: usize, bit_index_exclusive: usize) u32 {
            const clamped = @min(bit_index_exclusive, bit_len);
            const block_stop = clamped / bits_per_block;
            const tail = clamped % bits_per_block;

            var total: u32 = 0;
            var block: usize = 0;
            while (block < block_stop and block < bits.len) : (block += 1) {
                total += @intCast(@popCount(bits[block]));
            }

            if (tail != 0 and block_stop < bits.len) {
                const mask = (@as(u64, 1) << @intCast(tail)) - 1;
                total += @intCast(@popCount(bits[block_stop] & mask));
            }
            return total;
        }

        fn selectBits(bits: []const u64, bit_len: usize, rank_zero_based: u32) ?usize {
            var remaining = rank_zero_based;
            for (bits, 0..) |word, block_index| {
                const cnt: u32 = @intCast(@popCount(word));
                if (remaining >= cnt) {
                    remaining -= cnt;
                    continue;
                }

                const bit = selectBitInU64Broadword(word, remaining) orelse return null;
                const absolute = block_index * bits_per_block + bit;
                if (absolute >= bit_len) return null;
                return absolute;
            }
            return null;
        }

        fn selectFromOffset(word: u64, ignore_bits: usize, rank_zero_based: usize) usize {
            const masked = if (ignore_bits == 0)
                word
            else
                word & ~((@as(u64, 1) << @intCast(ignore_bits)) - 1);
            if (masked == 0) return bits_per_block;

            var bits = masked;
            var remaining = rank_zero_based;
            while (remaining > 0) : (remaining -= 1) {
                bits &= bits - 1;
                if (bits == 0) return bits_per_block;
            }
            return @intCast(@ctz(bits));
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
    };
}

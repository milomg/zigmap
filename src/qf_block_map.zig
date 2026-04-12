const std = @import("std");

pub fn QfBlocksHashMap(comptime K: type, comptime V: type) type {
    const Context = std.hash_map.AutoContext(K);
    const hashFn = std.hash_map.getAutoHashFn(K, Context);
    const eqlFn = std.hash_map.getAutoEqlFn(K, Context);

    return struct {
        ctx: Context,
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
        const verify_after_mutation = false;

        const bits_per_block = 64;
        const saturated_offset = std.math.maxInt(u8);

        pub const empty: Self = .{
            .ctx = .{},
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
                .ctx = self.ctx,
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
                    if (verify_after_mutation) self.verifyMetadata();
                    return;
                }

                const next_cap = if (self.cap == 0) 64 else self.cap * 2;
                try self.growTo(allocator, next_cap);
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.len == 0) return false;

            const hash = hashFn(self.ctx, key);
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
            self.len -= 1;
            if (verify_after_mutation) self.verifyMetadata();
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
                .ctx = self.ctx,
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
            return @as(usize, @truncate(hash)) & (self.cap - 1);
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

        fn keyHomeForIndex(self: *const Self, idx: usize) usize {
            return self.bucketFromHash(hashFn(self.ctx, self.entries[idx].key));
        }

        fn findEmptyFrom(self: *const Self, start: usize) ?usize {
            var idx = start;
            while (idx < self.slots_len and self.isSlotOccupied(idx)) : (idx += 1) {}
            if (idx == self.slots_len) return null;
            return idx;
        }

        fn findRunStart(self: *const Self, home: usize) ?usize {
            if (!self.testStart(home)) return null;
            if (home == 0) return 0;

            var run_start = self.runEnd(home - 1) + 1;
            if (run_start < home) run_start = home;
            return run_start;
        }

        fn endBit(self: *const Self, index: usize) bool {
            return self.rankEnd(index + 1) != self.rankEnd(index);
        }

        fn setEndIfChanged(self: *Self, index: usize, value: bool) void {
            if (self.endBit(index) == value) return;
            self.setEnd(index, value);
        }

        fn shiftRunEndsRightByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;

            var i = end_inclusive + 1;
            while (i > start) {
                i -= 1;
                self.setEndIfChanged(i + 1, self.endBit(i));
            }
            self.setEndIfChanged(start, false);
            self.afterShiftEndRight(start, end_inclusive);
        }

        fn shiftRunEndsLeftByOne(self: *Self, start: usize, end_inclusive: usize) void {
            if (start > end_inclusive) return;
            std.debug.assert(start > 0);

            var i = start;
            while (i <= end_inclusive) : (i += 1) {
                self.setEndIfChanged(i - 1, self.endBit(i));
            }
            self.setEndIfChanged(end_inclusive, false);
            self.afterShiftEndLeft(start, end_inclusive);
        }

        fn verifyMetadata(self: *const Self) void {
            const allocator = std.heap.page_allocator;

            const expected_start_words = (self.cap + 63) / 64;
            const expected_end_words = (self.slots_len + 63) / 64;

            const starts = allocator.alloc(u64, expected_start_words) catch unreachable;
            defer allocator.free(starts);
            @memset(starts, 0);

            const ends = allocator.alloc(u64, expected_end_words) catch unreachable;
            defer allocator.free(ends);
            @memset(ends, 0);

            var prev_home: ?usize = null;
            var prev_slot: ?usize = null;
            var live_count: usize = 0;

            for (0..self.slots_len) |i| {
                if (!self.isSlotOccupied(i)) continue;
                live_count += 1;

                const key_home = self.keyHomeForIndex(i);
                setBitWords(starts, key_home, true);

                const meta_home = self.homeForIndex(i);
                if (meta_home != key_home) {
                    std.debug.print(
                        "home divergence at slot {} meta_home={} key_home={}\\n",
                        .{ i, meta_home, key_home },
                    );
                }

                if (prev_home) |ph| {
                    if (key_home != ph) setBitWords(ends, prev_slot.?, true);
                }
                prev_home = key_home;
                prev_slot = i;
            }

            if (prev_slot) |slot| {
                setBitWords(ends, slot, true);
            }

            if (live_count != self.len) {
                std.debug.panic("live count mismatch len={} live={}", .{ self.len, live_count });
            }

            for (0..self.cap) |i| {
                if (self.testStart(i) != testBitWords(starts, i)) {
                    std.debug.panic("start mismatch at bucket {}", .{i});
                }
            }

            for (0..self.slots_len) |i| {
                if (self.endBit(i) != testBitWords(ends, i)) {
                    std.debug.panic("runend mismatch at slot {}", .{i});
                }
            }
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
            if (!self.testStart(home)) return null;

            const tag = tagFromHash(hash);
            const run_start = self.findRunStart(home) orelse return null;
            const run_end = self.runEnd(home);
            return self.findKeyInRun(key, tag, run_start, run_end);
        }

        fn putAssumeCapacity(self: *Self, key: K, value: V) bool {
            const hash = hashFn(self.ctx, key);
            const home = self.bucketFromHash(hash);
            const tag = tagFromHash(hash);

            if (!self.isSlotOccupied(home)) {
                self.entries[home] = .{ .key = key, .value = value };
                self.tags[home] = tag;
                self.setStart(home, true);
                self.setEnd(home, true);
                self.len += 1;
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

            self.setStart(home, true);
            if (had_run) {
                self.setEnd(run_end, false);
            }
            self.setEnd(insert_pos, true);
            self.afterInsert(home, insert_pos);
            self.len += 1;
            return true;
        }

        fn testStart(self: *const Self, index: usize) bool {
            return testBit(self.starts, index);
        }

        fn setStart(self: *Self, index: usize, value: bool) void {
            if (testBit(self.starts, index) == value) return;
            setBit(self.starts, index, value);
            self.refreshOffsetsFromBit(index, true);
        }

        fn setEnd(self: *Self, index: usize, value: bool) void {
            if (testBit(self.ends, index) == value) return;
            setBit(self.ends, index, value);
            self.refreshOffsetsFromBit(index, true);
        }

        fn rankEnd(self: *const Self, bit_index_exclusive: usize) u32 {
            return rankBits(self.ends, self.rs_len, bit_index_exclusive);
        }

        fn selectStart(self: *const Self, rank_zero_based: u32) ?usize {
            return selectBits(self.starts, self.rs_len, rank_zero_based);
        }

        fn runEnd(self: *const Self, bucket_index: usize) usize {
            std.debug.assert(bucket_index < self.rs_len);

            const bucket_block_index = bucket_index / bits_per_block;
            const bucket_intrablock_offset = bucket_index % bits_per_block;
            const bucket_blocks_offset = self.blockOffset(bucket_block_index);

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

        fn afterShiftEndRight(self: *Self, start: usize, end_inclusive: usize) void {
            _ = end_inclusive;
            self.refreshOffsetsFromBit(start, false);
        }

        fn afterShiftEndLeft(self: *Self, start: usize, end_inclusive: usize) void {
            _ = end_inclusive;
            const earliest = if (start == 0) self.rs_len - 1 else start - 1;
            self.refreshOffsetsFromBit(earliest, false);
        }

        fn afterInsert(self: *Self, home: usize, insert_pos: usize) void {
            const earliest = @min(home, insert_pos);
            self.refreshOffsetsFromBit(earliest, false);
        }

        fn blockOffset(self: *const Self, block_index: usize) usize {
            const raw = self.offsets[block_index];
            if (raw < saturated_offset) return raw;
            if (block_index == 0) return 0;

            const block_start = block_index * bits_per_block;
            const prev_run_end = self.runEnd(block_start - 1);
            if (prev_run_end + 1 <= block_start) return 0;
            return prev_run_end - block_start + 1;
        }

        fn refreshOffsetsFromBit(self: *Self, bit_index: usize, allow_early_stop: bool) void {
            if (self.offsets.len <= 1) return;
            var block = bit_index / bits_per_block + 1;
            if (block >= self.offsets.len) block = 1;
            self.refreshOffsetsFromBlock(block, allow_early_stop);
        }

        fn refreshOffsetsFromBlock(self: *Self, block_index: usize, allow_early_stop: bool) void {
            if (self.offsets.len == 0) return;
            if (block_index >= self.offsets.len) return;
            var block = @max(block_index, @as(usize, 1));
            while (block < self.offsets.len) : (block += 1) {
                const old_offset = self.offsets[block];
                const block_start = block * bits_per_block;
                const prev_slot = block_start - 1;
                const prev_run_end = self.runEnd(prev_slot);
                if (prev_run_end + 1 <= block_start) {
                    self.offsets[block] = 0;
                    if (allow_early_stop and old_offset == 0) break;
                    continue;
                }

                const raw = prev_run_end - block_start + 1;
                const new_offset: u8 = if (raw >= saturated_offset)
                    saturated_offset
                else
                    @intCast(raw);
                self.offsets[block] = new_offset;

                if (allow_early_stop and new_offset == old_offset and new_offset < saturated_offset) break;
            }
        }

        fn testBit(bits: []const u64, index: usize) bool {
            const block_index = index / bits_per_block;
            const bit_index = index % bits_per_block;
            const mask = @as(u64, 1) << @intCast(bit_index);
            return (bits[block_index] & mask) != 0;
        }

        fn setBit(bits: []u64, index: usize, value: bool) void {
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
            const bit = selectBitInU64Broadword(masked, @intCast(rank_zero_based)) orelse return bits_per_block;
            return bit;
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

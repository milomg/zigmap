const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn HashMapUnmanaged(
    K: type,
    V: type,
    /// This type provides the implementations of the hash and equality
    /// functions, it therefore must have the two following methods:
    ///
    /// - `pub fn eql(Context, K, K) bool`
    /// - `pub fn hash(Context, K) Hash`
    Context: type,
    max_load_percentage: comptime_int,
) type {
    if (max_load_percentage <= 0 or 100 <= max_load_percentage)
        @compileError("max load percentage must be in range (0, 100)");
    return struct {
        /// Pointers to the key and value of an entry stored in the map.
        pub const Entry = struct {
            key_ptr: *K,
            value_ptr: *V,
        };

        /// A key value pair.
        pub const KV = struct {
            key: K,
            value: V,
        };

        /// The return type of operations in the `getOrPut` family.
        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        /// The type used to denote sizes in the map.
        pub const Size = u32;

        /// The return type of hash operations.
        pub const Hash = u64;

        /// An empty map.
        pub const empty: @This() = .{
            // Logically this constant is a map of raw capacity one; which, by
            // the at-least-one-empty-slot invariant means it must be empty. We
            // must make sure not to accidentally modify this map's remote
            // memory.
            .ctrl = _: {
                const size = @sizeOf(KV) + chunk;
                const algn = 1 << @ctz(@as(usize, @max(@sizeOf(KV), @alignOf(KV))));
                const bytefill = empty_slot;
                // We use a type-in-a-type to deduplicate the amount of globals
                // we make. All maps whose `KV` type is of the same (positive)
                // size will refer to the same memory location - and all maps
                // whose `KV` is zero-sized, and of the same alignemnt, will
                // refer to the same memory location, too.
                break :_ @constCast(struct {
                    const mem: [size]u8 align(algn) = @splat(bytefill);
                }.mem[@sizeOf(KV)..]);
            },
            .items = 0,
            .budget = 0,
            .cap_mask = 0,
        };

        pub fn contains(self: @This(), key: K) bool {
            return self.containsContext(key, inferCtx("contains"));
        }

        pub fn containsContext(self: @This(), key: K, ctx: Context) bool {
            return self.containsAdapted(key, ctx);
        }

        pub fn containsAdapted(self: @This(), key: anytype, ctx: anytype) bool {
            return self.getEntryAdapted(key, ctx) != null;
        }

        pub fn get(self: @This(), key: K) ?V {
            return self.getContext(key, inferCtx("get"));
        }

        pub fn getContext(self: @This(), key: K, ctx: Context) ?V {
            return self.getAdapted(key, ctx);
        }

        pub fn getAdapted(self: @This(), key: anytype, ctx: anytype) ?V {
            return if (self.getEntryAdapted(key, ctx)) |entry| entry.value_ptr.* else null;
        }

        pub fn getKey(self: @This(), key: K) ?K {
            return self.getKeyContext(key, inferCtx("getKey"));
        }

        pub fn getKeyContext(self: @This(), key: K, ctx: Context) ?K {
            return self.getKeyAdapted(key, ctx);
        }

        pub fn getKeyAdapted(self: @This(), key: anytype, ctx: anytype) ?K {
            return if (self.getEntryAdapted(key, ctx)) |entry| entry.key_ptr.* else null;
        }

        pub fn getPtr(self: @This(), key: K) ?*V {
            return self.getPtrContext(key, inferCtx("getPtr"));
        }

        pub fn getPtrContext(self: @This(), key: K, ctx: Context) ?*V {
            return self.getPtrAdapted(key, ctx);
        }

        pub fn getPtrAdapted(self: @This(), key: anytype, ctx: anytype) ?*V {
            return if (self.getEntryAdapted(key, ctx)) |entry| entry.value_ptr else null;
        }

        pub fn getKeyPtr(self: @This(), key: K) ?*K {
            return self.getKeyPtrContext(key, inferCtx("getKeyPtr"));
        }

        pub fn getKeyPtrContext(self: @This(), key: K, ctx: Context) ?*K {
            return self.getKeyPtrAdapted(key, ctx);
        }

        pub fn getKeyPtrAdapted(self: @This(), key: anytype, ctx: anytype) ?*K {
            return if (self.getEntryAdapted(key, ctx)) |entry| entry.key_ptr else null;
        }

        pub fn getEntry(self: @This(), key: K) ?Entry {
            return self.getEntryContext(key, inferCtx("getEntry"));
        }

        pub fn getEntryContext(self: @This(), key: K, ctx: Context) ?Entry {
            return self.getEntryAdapted(key, ctx);
        }

        pub fn getEntryAdapted(self: @This(), key: anytype, ctx: anytype) ?Entry {
            const i = self.findKey(ctx.hash(key), key, ctx) orelse return null;
            return .{ .key_ptr = &self.kv(i).key, .value_ptr = &self.kv(i).value };
        }

        pub fn put(self: *@This(), allocator: Allocator, key: K, value: V) Allocator.Error!void {
            self.pointer_stability.assertUnlocked();
            return self.putContext(allocator, key, value, inferCtx("put"));
        }

        pub fn putContext(self: *@This(), allocator: Allocator, key: K, value: V, ctx: Context) Allocator.Error!void {
            (try self.getOrPutContext(allocator, key, ctx)).value_ptr.* = value;
        }

        pub fn putNoClobber(self: *@This(), allocator: Allocator, key: K, value: V) Allocator.Error!void {
            return self.putNoClobberContext(allocator, key, value, inferCtx("putNoClobber"));
        }

        pub fn putNoClobberContext(self: *@This(), allocator: Allocator, key: K, value: V, ctx: Context) Allocator.Error!void {
            try self.confirmBudget(allocator, ctx);
            self.putAssumeCapacityNoClobberContext(key, value, ctx);
        }

        pub fn putAssumeCapacity(self: *@This(), key: K, value: V) void {
            return self.putAssumeCapacityContext(key, value, inferCtx("putAssumeCapacity"));
        }

        pub fn putAssumeCapacityContext(self: *@This(), key: K, value: V, ctx: Context) void {
            self.getOrPutAssumeCapacityContext(key, ctx).value_ptr.* = value;
        }

        pub fn putAssumeCapacityNoClobber(self: *@This(), key: K, value: V) void {
            return self.putAssumeCapacityNoClobberContext(key, value, inferCtx("putAssumeCapacityNoClobber"));
        }

        pub fn putAssumeCapacityNoClobberContext(self: *@This(), key: K, value: V, ctx: Context) void {
            const hash = ctx.hash(key);
            const i = self.findVacancy(hash);
            self.items += 1;
            self.budget -= @intFromBool(self.ctrl[i] == empty_slot);
            self.setCtrl(i, fingerprint(hash));
            self.kv(i).* = .{ .key = key, .value = value };
        }

        pub fn getOrPut(self: *@This(), allocator: Allocator, key: K) Allocator.Error!GetOrPutResult {
            return self.getOrPutContext(allocator, key, inferCtx("getOrPut"));
        }

        pub fn getOrPutAdapted(self: *@This(), allocator: Allocator, key: anytype, key_ctx: anytype) Allocator.Error!GetOrPutResult {
            return self.getOrPutContextAdapted(allocator, key, key_ctx, inferCtx("getOrPutAdapted"));
        }

        pub fn getOrPutContext(self: *@This(), allocator: Allocator, key: K, ctx: Context) Allocator.Error!GetOrPutResult {
            const gop = try self.getOrPutContextAdapted(allocator, key, ctx, ctx);
            if (!gop.found_existing) gop.key_ptr.* = key;
            return gop;
        }

        pub fn getOrPutContextAdapted(self: *@This(), allocator: Allocator, key: anytype, key_ctx: anytype, ctx: Context) Allocator.Error!GetOrPutResult {
            const hash = key_ctx.hash(key);
            if (self.findKey(hash, key, key_ctx)) |i| return .{
                .key_ptr = &self.kv(i).key,
                .value_ptr = &self.kv(i).value,
                .found_existing = true,
            };
            try self.confirmBudget(allocator, ctx);
            const i = self.findVacancy(hash);
            self.items += 1;
            self.budget -= @intFromBool(self.ctrl[i] == empty_slot);
            self.setCtrl(i, fingerprint(hash));
            return .{
                .key_ptr = &self.kv(i).key,
                .value_ptr = &self.kv(i).value,
                .found_existing = false,
            };
        }

        pub fn getOrPutAssumeCapacity(self: *@This(), key: K) GetOrPutResult {
            return self.getOrPutAssumeCapacityContext(key, inferCtx("getOrPutAssumeCapacity"));
        }

        pub fn getOrPutAssumeCapacityContext(self: *@This(), key: K, ctx: Context) GetOrPutResult {
            const gop = self.getOrPutAssumeCapacityAdapted(key, ctx);
            if (!gop.found_existing) gop.key_ptr.* = key;
            return gop;
        }

        pub fn getOrPutAssumeCapacityAdapted(self: *@This(), key: anytype, ctx: anytype) GetOrPutResult {
            const hash = ctx.hash(key);
            if (self.findKey(hash, key, ctx)) |i| return .{
                .key_ptr = &self.kv(i).key,
                .value_ptr = &self.kv(i).value,
                .found_existing = true,
            };
            const i = self.findVacancy(hash);
            self.items += 1;
            self.budget -= @intFromBool(self.ctrl[i] == empty_slot);
            self.setCtrl(i, fingerprint(hash));
            return .{
                .key_ptr = &self.kv(i).key,
                .value_ptr = &self.kv(i).value,
                .found_existing = false,
            };
        }

        pub fn getOrPutValue(self: *@This(), allocator: Allocator, key: K, value: V) Allocator.Error!Entry {
            return self.getOrPutValueContext(allocator, key, value, inferCtx("getOrPutValue"));
        }

        pub fn getOrPutValueContext(self: *@This(), allocator: Allocator, key: K, value: V, ctx: Context) Allocator.Error!Entry {
            const gop = try self.getOrPutContext(allocator, key, ctx);
            if (!gop.found_existing) gop.value_ptr.* = value;
            return .{ .key_ptr = gop.key_ptr, .value_ptr = gop.value_ptr };
        }

        pub fn fetchPut(self: *@This(), allocator: Allocator, key: K, value: V) Allocator.Error!?KV {
            return self.fetchPutContext(allocator, key, value, inferCtx("fetchPut"));
        }

        pub fn fetchPutContext(self: *@This(), allocator: Allocator, key: K, value: V, ctx: Context) Allocator.Error!?KV {
            const gop = try self.getOrPutAdapted(allocator, key, ctx);
            defer gop.key_ptr.* = key;
            defer gop.value_ptr.* = value;
            return if (gop.found_existing) .{
                .key = gop.key_ptr.*,
                .value = gop.value_ptr.*,
            } else null;
        }

        pub fn fetchPutAssumeCapacity(self: *@This(), key: K, value: V) ?KV {
            return self.fetchPutAssumeCapacityContext(key, value, inferCtx("fetchPutAssumeCapacity"));
        }

        pub fn fetchPutAssumeCapacityContext(self: *@This(), key: K, value: V, ctx: Context) ?KV {
            const gop = self.getOrPutAssumeCapacityAdapted(key, ctx);
            defer gop.key_ptr.* = key;
            defer gop.value_ptr.* = value;
            return if (gop.found_existing) .{
                .key = gop.key_ptr.*,
                .value = gop.value_ptr.*,
            } else null;
        }

        pub fn remove(self: *@This(), key: K) bool {
            return self.removeContext(key, inferCtx("remove"));
        }

        pub fn removeContext(self: *@This(), key: K, ctx: Context) bool {
            return self.removeAdapted(key, ctx);
        }

        pub fn removeAdapted(self: *@This(), key: anytype, ctx: anytype) bool {
            return self.fetchRemoveAdapted(key, ctx) != null;
        }

        pub fn removeByPtr(self: *@This(), key_ptr: *const K) void {
            const kv_ptr: *align(1) const KV = @fieldParentPtr("key", key_ptr);
            const i = if (@sizeOf(K) == 0) 0 else kv_ptr - self.kv(0);
            const erase = @intFromBool(self.erasable(i));
            self.items -= 1;
            self.budget += erase;
            self.setCtrl(i, tombstone_slot + erase);
            self.kv(i).* = undefined;
        }

        pub fn fetchRemove(self: *@This(), key: K) ?KV {
            return self.fetchRemoveContext(key, inferCtx("fetchRemove"));
        }

        pub fn fetchRemoveContext(self: *@This(), key: K, ctx: Context) ?KV {
            return self.fetchRemoveAdapted(key, ctx);
        }

        pub fn fetchRemoveAdapted(self: *@This(), key: anytype, ctx: anytype) ?KV {
            const i = self.findKey(ctx.hash(key), key, ctx) orelse return null;
            const erase = @intFromBool(self.erasable(i));
            self.items -= 1;
            self.budget += erase;
            self.setCtrl(i, tombstone_slot + erase);
            defer self.kv(i).* = undefined;
            return self.kv(i).*;
        }

        pub fn ensureTotalCapacity(self: *@This(), allocator: Allocator, total: Size) Allocator.Error!void {
            return self.ensureTotalCapacityContext(allocator, total, inferCtx("ensureTotalCapacity"));
        }

        pub fn ensureTotalCapacityContext(self: *@This(), allocator: Allocator, total: Size, ctx: Context) Allocator.Error!void {
            return self.ensureUnusedCapacityContext(allocator, total -| self.items, ctx);
        }

        pub fn ensureUnusedCapacity(self: *@This(), allocator: Allocator, additional: Size) Allocator.Error!void {
            return self.ensureUnusedCapacityContext(allocator, additional, inferCtx("ensureUnusedCapacity"));
        }

        pub fn ensureUnusedCapacityContext(self: *@This(), allocator: Allocator, additional: Size, ctx: Context) Allocator.Error!void {
            if (self.budget >= additional) return;
            const cap_mask = try computeCapMask(self.items +| additional);
            if (cap_mask <= self.cap_mask) {
                self.rehash(ctx);
            } else {
                const new = try self.cloneGivenCapacity(allocator, ctx, cap_mask);
                self.deinit(allocator);
                self.* = new;
            }
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            if (self.cap_mask == 0) return;

            const size = (@sizeOf(KV) + 1) * (@as(usize, self.cap_mask) + 1) + (chunk - 1);
            const memory: [*]align(@alignOf(KV)) u8 = @ptrCast(self.kv(0));
            allocator.free(memory[0..size]);
            self.* = undefined;
        }

        pub fn move(self: *@This()) @This() {
            defer self.* = .empty;
            return self.*;
        }

        pub fn clearAndFree(self: *@This(), allocator: Allocator) void {
            self.deinit(allocator);
            self.* = .empty;
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            if (self.cap_mask == 0) return;

            const kvs: [*]KV = self.kv(0)[0..1];
            @memset(kvs[0 .. @as(usize, self.cap_mask) + 1], undefined);
            @memset(self.ctrl[0 .. @as(usize, self.cap_mask) + chunk], empty_slot);
            self.items = 0;
            self.budget = computeBudget(self.cap_mask);
        }

        pub fn clone(self: @This(), allocator: Allocator) Allocator.Error!@This() {
            return self.cloneContext(allocator, inferCtx("clone"));
        }

        pub fn cloneContext(self: @This(), allocator: Allocator, new_ctx: anytype) Allocator.Error!HashMapUnmanaged(K, V, @TypeOf(new_ctx), max_load_percentage) {
            return self.cloneGivenCapacity(allocator, new_ctx, computeCapMask(self.items) catch unreachable);
        }

        // pub fn promote(self: @This(), allocator: Allocator) Managed {
        //     return self.promoteContext(allocator, inferCtx("promote"));
        // }

        // pub fn promoteContext(self: @This(), allocator: Allocator, ctx: Context) Managed {
        //     return .{
        //         .unmanaged = self,
        //         .allocator = allocator,
        //         .ctx = ctx,
        //     };
        // }

        // pub const Managed = HashMap(K, V, Context, max_load_percentage);

        pub fn iterator(self: @This()) Iterator {
            return .{
                .cur_kv = @ptrCast(self.kv(0)),
                .cur_ctrl = self.ctrl,
                .end_ctrl = self.ctrl[@as(usize, self.cap_mask) + 1 ..],
            };
        }

        pub const Iterator = struct {
            cur_kv: [*]KV,
            cur_ctrl: [*]u8,
            end_ctrl: [*]u8,

            pub fn next(self: *@This()) ?Entry {
                // TODO: make this search SIMD, perhaps?
                while (self.cur_ctrl != self.end_ctrl) {
                    defer self.cur_kv = self.cur_kv[1..];
                    defer self.cur_ctrl = self.cur_ctrl[1..];
                    if (self.cur_ctrl[0] < tombstone_slot) return .{
                        .key_ptr = &self.cur_kv[0].key,
                        .value_ptr = &self.cur_kv[0].value,
                    };
                }
                return null;
            }
        };

        pub fn keyIterator(self: @This()) KeyIterator {
            return .{ .iter = self.iterator() };
        }

        pub const KeyIterator = struct {
            iter: Iterator,

            pub fn next(self: *@This()) ?*K {
                return if (self.iter.next()) |entry| entry.key_ptr else null;
            }
        };

        pub fn valueIterator(self: @This()) ValueIterator {
            return .{ .iter = self.iterator() };
        }

        pub const ValueIterator = struct {
            iter: Iterator,

            pub fn next(self: *@This()) ?*V {
                return if (self.iter.next()) |entry| entry.value_ptr else null;
            }
        };

        pub fn capacity(self: @This()) Size {
            return self.items + self.budget;
        }

        pub fn count(self: @This()) Size {
            return self.items;
        }

        pub fn lockPointers(self: *@This()) void {
            self.pointer_stability.lock();
        }

        pub fn unlockPointers(self: *@This()) void {
            self.pointer_stability.unlock();
        }

        pub fn rehash(self: *@This(), ctx: anytype) void {
            if (self.cap_mask == 0) return;
            const ideal_budget = computeBudget(self.cap_mask) - self.items;
            if (self.budget == ideal_budget) return;

            // TODO: make this SIMD maybe?
            const end = @as(usize, self.cap_mask) + 1;
            for (self.ctrl[0..end]) |*meta| {
                meta.* = tombstone_slot + @intFromBool(meta.* >= 0x80);
            }

            // From this point onwards:
            // - empty slots mark non-occupied slots
            // - tombstone slots mark yet-to-be-rehashed entries
            // - occupied slots mark rehashed entries

            var i: usize = 0;
            // Every iteration increases `i` by one, removes one tombstone, or
            // both. The loop therefore terminates.
            while (i <= self.cap_mask) {
                if (self.ctrl[i] != tombstone_slot) {
                    i += 1;
                    continue;
                }
                const hash = ctx.hash(self.kv(i).key);
                const index = self.findVacancy(hash);

                if (index == i) {
                    i += 1;
                } else if (self.ctrl[index] == tombstone_slot) {
                    mem.swap(KV, self.kv(index), self.kv(i));
                } else {
                    self.kv(index).* = self.kv(i).*;
                    self.kv(i).* = undefined;
                    self.setCtrl(i, empty_slot);
                    i += 1;
                }
                self.setCtrl(index, fingerprint(hash));
            }
            self.budget = ideal_budget;
        }

        // The map's data consists of a single allocation, segmented into two
        // parts:
        // - The first part contains space for `2ⁿ` naturally-aligned `KV`s.
        // - The second part consists of `2ⁿ + chunk - 1` ctrl slots, each
        //   being an initialised byte. The byte at index `i` contains the
        //   information for slot ` i % 2ⁿ` (i.e. the last `chunk - 1` values
        //   repeat the first ones).
        //
        // The repetition of the first `chunk - 1` elements is put in place in
        // order to allow SIMD lookup operations: a SIMD read of those values
        // is logically equivalent to it wrapping back around and reading the
        // first few values.
        //
        // A ctrl entry consists of one of three states:
        // - Occupied: holding a fragment of the relevent key's hash, for quick
        //   filtering.
        // - Empty: denoting that the slot is vacant.
        // - Tombstone: denoting that the slot is vacant, but previously held a
        //   value, and should not indicate the end a search walk.
        //
        // The "raw capacity" of the map is the number of slots allocated for
        // the `KV`s, which is always a power of two. The raw capacity minus
        // one is stored in `cap_mask`, this representation both makes for
        // quick bit-masking and allows for maps whose raw capacity is as high
        // as 2³². Note that on 32-bit systems the raw capacity will never get
        // to that maximal value, as we can't allocate so much memory.
        //
        // Map invariants:
        // - At least one slot in the map is always empty, so as to allow
        //   search operations to eventually terminate without an explicit
        //   countdown.
        // - Raw capacity is a multiple of `chunk`, or 1 for the empty map, so
        //   at most two writes are required to update the ctrl for particular
        //   slot.

        /// Pointer to the ctrl segment of the allocation.
        ctrl: [*]align(@alignOf(KV)) u8,
        /// Current number of entries in the map.
        items: Size,
        /// Minimal number of available insertions that won't require a
        /// reallocation/rehash.
        budget: Size,
        cap_mask: Size,
        pointer_stability: std.debug.SafetyLock = .{},

        /// Infer a `Context` argument, or report a compilation error if such
        /// cannot be done.
        fn inferCtx(comptime fn_name: []const u8) Context {
            if (@sizeOf(Context) != 0) @compileError("Cannot infer context " ++
                @typeName(Context) ++ ", call " ++ fn_name ++ "Context instead.");
            return undefined;
        }

        const chunk = @max(std.simd.suggestVectorLength(u8) orelse 1, @sizeOf(usize));

        const empty_slot: u8 = 0xff;
        const tombstone_slot: u8 = 0xfe;

        fn desiredIndex(self: @This(), hash: Hash) Size {
            if (@sizeOf(K) == 0) return 0;
            return @intCast(hash & self.cap_mask);
        }

        fn fingerprint(hash: Hash) u8 {
            return @intCast(hash >> (@bitSizeOf(Hash) - 7));
        }

        /// Searches for the index situating the given key. Returns `null` if
        /// such key does not exist.
        fn findKey(self: @This(), hash: Hash, key: anytype, ctx: anytype) ?Size {
            const vacants: @Vector(chunk, u8) = @splat(0x80);
            const mask: @Vector(chunk, u8) = @splat(fingerprint(hash));

            var step: Size = chunk;
            var index = self.desiredIndex(hash);
            while (true) {
                const group: @Vector(chunk, u8) = self.ctrl[index..][0..chunk].*;
                var matches: @Int(.unsigned, chunk) = @bitCast(group == mask);
                while (matches != 0) {
                    const i = (index +% @ctz(matches)) & self.cap_mask;
                    if (ctx.eql(key, self.kv(i).key)) return i;
                    matches &= matches - 1;
                }
                if (@reduce(.Or, group >= vacants)) return null;
                index = (index +% step) & self.cap_mask;
                step +%= chunk;
            }
        }

        /// Finds an insertion slot for an entry with the given hash.
        fn findVacancy(self: @This(), hash: Hash) Size {
            const vacants: @Vector(chunk, u8) = @splat(0x80);

            var step: Size = chunk;
            var index = self.desiredIndex(hash);
            while (true) {
                const group: @Vector(chunk, u8) = self.ctrl[index..][0..chunk].*;
                const matches: @Int(.unsigned, chunk) = @bitCast(group >= vacants);
                if (matches != 0) return (index +% @ctz(matches)) & self.cap_mask;
                index = (index +% step) & self.cap_mask;
                step +%= chunk;
            }
        }

        /// Returns whether the given index in the map may be marked as removed
        /// by changing its ctrl to `empty_slot` - if `false`, `tombstone_slot`
        /// must be used.
        fn erasable(self: @This(), index: usize) bool {
            const empties: @Vector(chunk, u8) = @splat(empty_slot);
            const prev_index = (index -% chunk) & self.cap_mask;

            const prev_chunk: @Vector(chunk, u8) = self.ctrl[prev_index..][0..chunk].*;
            const curr_chunk: @Vector(chunk, u8) = self.ctrl[index..][0..chunk].*;

            const prev: @Int(.unsigned, chunk) = @bitCast(prev_chunk == empties);
            const curr: @Int(.unsigned, chunk) = @bitCast(curr_chunk == empties);

            return @clz(prev) < chunk - @ctz(curr);
        }

        fn setCtrl(self: *@This(), index: usize, value: u8) void {
            const wrap: usize = chunk - 1;
            self.ctrl[index] = value;
            self.ctrl[((index -% wrap) & self.cap_mask) + wrap] = value;
        }

        fn kv(self: @This(), index: usize) *KV {
            const ptr: [*]KV = @ptrCast(self.ctrl);
            return &(ptr - self.cap_mask - 1)[index];
        }

        /// Potentially reallocate or rehash the map to guarantee a positive
        /// insertion budget. This function may over-allocate so as to avoid a
        /// pathological case, where rehashing is done to clean up only a few
        /// tombstones.
        fn confirmBudget(self: *@This(), allocator: Allocator, ctx: Context) Allocator.Error!void {
            if (self.budget > 0) {
                @branchHint(.likely);
            } else if (self.cap_mask == 0) {
                self.* = try self.cloneGivenCapacity(allocator, ctx, chunk - 1);
            } else if (self.items < computeBudget(self.cap_mask) / 2) {
                // tombstones occupy more than half of the available space
                self.rehash(ctx);
            } else {
                if (self.cap_mask == math.maxInt(Size)) return error.OutOfMemory;
                const new = try self.cloneGivenCapacity(allocator, ctx, self.cap_mask * 2 + 1);
                self.deinit(allocator);
                self.* = new;
            }
        }

        /// Value of `budget` for a fresh map of maximal raw capacity.
        const budget_4gb: Size = (max_load_percentage << @bitSizeOf(Size)) / 100;
        /// Value of `budget` for a fresh map of `chunk` raw capacity.
        const budget_chunk: Size = max_load_percentage * chunk / 100;

        /// Minimal value for map's `cap_mask` (but no less than `chunk - 1`)
        /// which can accomodate at least `budget` insertions without needing a
        /// reallocation.
        fn computeCapMask(budget: Size) error{OutOfMemory}!Size {
            if (budget > budget_4gb) return error.OutOfMemory;
            if (budget <= budget_chunk) return chunk - 1;
            return ~@as(Size, 0) >> math.log2_int(Size, budget_4gb / budget);
        }

        /// Inertion budget for a fresh map of raw capacity equal to
        /// `cap_mask + 1`.
        ///
        /// Asserts `cap_mask > 0`.
        fn computeBudget(cap_mask: Size) Size {
            assert(cap_mask > 0);
            return budget_4gb >> @intCast(@clz(cap_mask));
        }

        /// Clones the input map's items into a newly allocated map of the
        /// given raw capacity, using the given context for hashing.
        ///
        /// Asserts that `cap_mask` constitutes a valid raw capacity not less
        /// than `chunk`, asserts that the capacity given is enough to hold all
        /// of the to-be-cloned items.
        fn cloneGivenCapacity(
            self: @This(),
            allocator: Allocator,
            new_ctx: anytype,
            cap_mask: Size,
        ) Allocator.Error!HashMapUnmanaged(K, V, @TypeOf(new_ctx), max_load_percentage) {
            assert(cap_mask & (cap_mask +% 1) == 0);
            assert(cap_mask >= chunk - 1);
            assert(computeBudget(cap_mask) >= self.items);

            if (cap_mask >= (math.maxInt(usize) + 1 - chunk) / (@sizeOf(KV) + 1))
                return error.OutOfMemory;
            const capm: usize = cap_mask;
            const size = (@sizeOf(KV) + 1) * (capm + 1) + (chunk - 1);
            const kvs: [*]KV = @ptrCast(try allocator.alignedAlloc(u8, .of(KV), size));
            errdefer comptime unreachable;

            var res: HashMapUnmanaged(K, V, @TypeOf(new_ctx), max_load_percentage) = .{
                .ctrl = @ptrCast(kvs[capm + 1 ..]),
                .items = self.items,
                .budget = computeBudget(cap_mask) - self.items,
                .cap_mask = cap_mask,
            };
            @memset(res.ctrl[0 .. capm + chunk], empty_slot);

            var it = self.iterator();
            while (it.next()) |entry| {
                const hash = new_ctx.hash(entry.key_ptr.*);
                const i = res.findVacancy(hash);
                res.setCtrl(i, fingerprint(hash));
                kvs[i] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
            }
            return res;
        }
    };
}

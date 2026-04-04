const std = @import("std");

const Slot = struct {
    occupied: bool = false,
    home: usize = 0,
    id: u64 = 0,
};

const Model = struct {
    allocator: std.mem.Allocator,
    cap: usize,
    slots: []Slot,
    direct_used: []bool,
    run_end: []bool,

    fn init(allocator: std.mem.Allocator, cap: usize) !Model {
        const m = Model{
            .allocator = allocator,
            .cap = cap,
            .slots = try allocator.alloc(Slot, cap),
            .direct_used = try allocator.alloc(bool, cap),
            .run_end = try allocator.alloc(bool, cap),
        };
        @memset(m.slots, .{});
        @memset(m.direct_used, false);
        @memset(m.run_end, false);
        return m;
    }

    fn deinit(self: *Model) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.direct_used);
        self.allocator.free(self.run_end);
    }

    fn clone(self: *const Model, allocator: std.mem.Allocator) !Model {
        const out = try init(allocator, self.cap);
        @memcpy(out.slots, self.slots);
        @memcpy(out.direct_used, self.direct_used);
        @memcpy(out.run_end, self.run_end);
        return out;
    }

    fn mask(self: *const Model) usize {
        return self.cap - 1;
    }

    // Toy ordered insertion: keep runs grouped by home and sorted by home.
    // This model intentionally avoids wraparound complexity.
    fn insertOrdered(self: *Model, home: usize, id: u64) void {
        var empty = home;
        while (empty < self.cap and self.slots[empty].occupied) : (empty += 1) {}
        std.debug.assert(empty < self.cap);

        var pos = home;
        while (pos < empty and self.slots[pos].occupied and self.slots[pos].home <= home) : (pos += 1) {}

        var i = empty;
        while (i > pos) : (i -= 1) {
            self.slots[i] = self.slots[i - 1];
        }
        self.slots[pos] = .{ .occupied = true, .home = home, .id = id };
    }

    fn recomputeBits(self: *Model) void {
        @memset(self.direct_used, false);
        @memset(self.run_end, false);

        for (self.slots) |s| {
            if (s.occupied) self.direct_used[s.home] = true;
        }

        for (0..self.cap) |i| {
            if (!self.slots[i].occupied) continue;
            if (i + 1 == self.cap or !self.slots[i + 1].occupied or self.slots[i + 1].home != self.slots[i].home) {
                self.run_end[i] = true;
            }
        }
    }

    fn findById(self: *const Model, id: u64) ?usize {
        for (self.slots, 0..) |s, i| {
            if (s.occupied and s.id == id) return i;
        }
        return null;
    }

    fn countOccupied(self: *const Model) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.occupied) n += 1;
        }
        return n;
    }

    fn nextUsedHome(self: *const Model, home: usize) usize {
        var h = home + 1;
        while (h < self.cap and !self.direct_used[h]) : (h += 1) {}
        if (h == self.cap) {
            h = 0;
            while (!self.direct_used[h]) : (h += 1) {}
        }
        return h;
    }

    fn shouldShift(home: usize, hole: usize, idx: usize) bool {
        // For the non-wrapping toy model, this is sufficient.
        _ = idx;
        return home <= hole;
    }

    fn deleteCascade(self: *Model, start_idx: usize, start_home: usize) void {
        var hole = start_idx;
        var curr_home = start_home;
        if (self.run_end[start_idx]) {
            curr_home = self.nextUsedHome(curr_home);
        }

        while (true) {
            const run_start = hole + 1;
            if (run_start >= self.cap or !self.slots[run_start].occupied) break;
            if (!shouldShift(curr_home, hole, run_start)) break;

            var run_end_idx = run_start;
            while (!self.run_end[run_end_idx]) : (run_end_idx += 1) {}

            var dst = hole;
            var src = run_start;
            while (true) {
                self.slots[dst] = self.slots[src];
                if (src == run_end_idx) break;
                dst += 1;
                src += 1;
            }

            self.run_end[run_end_idx] = false;
            self.run_end[dst] = true;
            hole = run_end_idx;
            curr_home = self.nextUsedHome(curr_home);
        }

        self.slots[hole] = .{};
        self.run_end[hole] = false;
    }

    fn deleteReference(self: *Model, start_idx: usize) void {
        var hole = start_idx;
        var scan = hole + 1;

        while (scan < self.cap and self.slots[scan].occupied) {
            const home = self.slots[scan].home;
            if (shouldShift(home, hole, scan)) {
                self.slots[hole] = self.slots[scan];
                hole = scan;
            }
            scan += 1;
        }

        self.slots[hole] = .{};
    }

    fn eqlState(a: *const Model, b: *const Model) bool {
        for (a.slots, b.slots) |sa, sb| {
            if (sa.occupied != sb.occupied) return false;
            if (sa.occupied and (sa.home != sb.home or sa.id != sb.id)) return false;
        }
        return true;
    }
};

test "ordered insertion keeps homes grouped" {
    var m = try Model.init(std.testing.allocator, 16);
    defer m.deinit();

    m.insertOrdered(2, 1);
    m.insertOrdered(3, 2);
    m.insertOrdered(2, 3);

    try std.testing.expect(m.slots[2].occupied and m.slots[2].home == 2);
    try std.testing.expect(m.slots[3].occupied and m.slots[3].home == 2);
    try std.testing.expect(m.slots[4].occupied and m.slots[4].home == 3);
}

test "run cascade delete matches reference backshift" {
    var prng = std.Random.DefaultPrng.init(0xdecafbad);
    const rnd = prng.random();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cap = 4096;
    var m = try Model.init(a, cap);
    defer m.deinit();

    var next_id: u64 = 1;
    for (0..1000) |_| {
        if (m.countOccupied() + 2 >= cap) {
            const victim_id = rnd.intRangeLessThan(u64, 1, next_id);
            if (m.findById(victim_id)) |idx_force| {
                const start_home_force = m.slots[idx_force].home;
                m.deleteCascade(idx_force, start_home_force);
                m.recomputeBits();
            }
        }

        const home = rnd.intRangeLessThan(usize, 0, 64);
        m.insertOrdered(home, next_id);
        next_id += 1;
        m.recomputeBits();

        if (rnd.uintLessThan(usize, 3) == 0) {
            const victim_id = rnd.intRangeLessThan(u64, 1, next_id);
            const idx = m.findById(victim_id) orelse continue;
            const start_home = m.slots[idx].home;

            var ref = try m.clone(a);
            defer ref.deinit();

            m.deleteCascade(idx, start_home);
            ref.deleteReference(idx);
            m.recomputeBits();
            ref.recomputeBits();

            try std.testing.expect(Model.eqlState(&m, &ref));
        }
    }
}

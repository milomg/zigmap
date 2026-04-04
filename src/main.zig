// zig build --release=fast run
const std = @import("std");
const qf = @import("qf_swiss_map.zig");
const qf_meta_tree_runend = @import("qf_swiss_qfmeta_tree_runend.zig");
const boost = @import("boost_flat_map.zig");
const cuckoo = @import("cuckoo_simd_map.zig");

const Io = std.Io;
const StdMap = std.AutoHashMap(u64, u64);
const QfMap = qf.QfHashMap(u64, u64);
const QfMetaTreeRunEndMap = qf_meta_tree_runend.QfMetaTreeRunEndHashMap(u64, u64);
const CuckooMap = cuckoo.CuckooSimdHashMap(u64, u64);
const BoostMap = boost.BoostStyleFlatMap(u64, u64);
const StdBench = BenchmarkFns(StdMap);
const QfBench = BenchmarkFns(QfMap);
const QfMetaTreeRunEndBench = BenchmarkFns(QfMetaTreeRunEndMap);
const CuckooBench = BenchmarkFns(CuckooMap);
const BoostBench = BenchmarkFns(BoostMap);

const BenchSpec = struct {
    short_label: []const u8,
    size_label: []const u8,
    Map: type,
    Bench: type,
};

const BenchmarkRun = struct {
    label: []const u8,
    fn_name: []const u8,
};

const bench_specs = [_]BenchSpec{
    .{ .short_label = "std", .size_label = "std.AutoHashMap(u64,u64):", .Map = StdMap, .Bench = StdBench },
    .{ .short_label = "qf", .size_label = "QfHashMap(u64,u64):", .Map = QfMap, .Bench = QfBench },
    .{ .short_label = "qf_meta_tree_runend", .size_label = "QfMetaTreeRunEndHashMap(u64,u64):", .Map = QfMetaTreeRunEndMap, .Bench = QfMetaTreeRunEndBench },
    .{ .short_label = "cuckoo", .size_label = "CuckooSimdHashMap(u64,u64):", .Map = CuckooMap, .Bench = CuckooBench },
    .{ .short_label = "boost_flat", .size_label = "BoostStyleFlatMap(u64,u64):", .Map = BoostMap, .Bench = BoostBench },
};

const config_benchmarks = [_]BenchmarkRun{
    .{ .label = "delete_churn", .fn_name = "deleteChurn" },
    .{ .label = "alternate_reuse", .fn_name = "alternatingReuse" },
    .{ .label = "insert_light", .fn_name = "insertLight" },
    .{ .label = "insert_nearfull", .fn_name = "insertNearFull" },
};

const load_benchmarks = [_]BenchmarkRun{
    .{ .label = "lookup_hit", .fn_name = "lookupHit" },
    .{ .label = "lookup_miss", .fn_name = "lookupMiss" },
    .{ .label = "insert_load", .fn_name = "insertLoad" },
};

const Config = struct {
    working_set: usize,
    operations: usize,
};

const Result = struct {
    ns_per_op: u64,
    checksum: u64,
};

const LoadCase = struct {
    capacity: usize,
    load_num: usize,
    load_den: usize,
    operations: usize,
};

fn BenchmarkFns(comptime MapType: type) type {
    return struct {
        fn initMap(allocator: std.mem.Allocator, capacity: usize, comptime reserve_for_std: bool) !MapType {
            if (MapType == StdMap) {
                var map = MapType.init(allocator);
                if (reserve_for_std) {
                    try map.ensureTotalCapacity(@intCast(capacity));
                }
                return map;
            }

            return try MapType.initCapacity(allocator, capacity);
        }

        fn deleteChurn(io: Io, allocator: std.mem.Allocator, cfg: Config) !Result {
            var map = try initMap(allocator, cfg.working_set * 2, false);
            defer map.deinit();

            var live_keys = try allocator.alloc(u64, cfg.working_set);
            defer allocator.free(live_keys);

            for (0..cfg.working_set) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
                live_keys[i] = key;
            }

            const start = Io.Timestamp.now(io, .awake);

            var next_key = @as(u64, @intCast(cfg.working_set));
            var checksum: u64 = 0;
            for (0..cfg.operations) |i| {
                const slot = i % cfg.working_set;
                const old_key = live_keys[slot];

                if (MapType != StdMap and map.get(old_key) == null) {
                    std.debug.print("missing key {d}\n", .{old_key});
                    std.debug.print("map type: {s}\n", .{@typeName(MapType)});
                    return error.BenchmarkInvariantFailed;
                }
                if (!map.remove(old_key)) return error.BenchmarkInvariantFailed;

                const new_key = next_key;
                next_key += 1;
                try map.put(new_key, new_key);
                live_keys[slot] = new_key;

                const miss = map.get(next_key) == null;
                checksum ^= @as(u64, @intFromBool(miss)) +% new_key;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            if (map.count() != cfg.working_set) return error.BenchmarkInvariantFailed;
            return .{
                .ns_per_op = @as(u64, @intCast(elapsed_ns / cfg.operations)),
                .checksum = checksum,
            };
        }

        fn alternatingReuse(io: Io, allocator: std.mem.Allocator, cfg: Config) !Result {
            var map = try initMap(allocator, cfg.working_set * 2, false);
            defer map.deinit();

            for (0..cfg.working_set) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
            }

            const start = Io.Timestamp.now(io, .awake);

            var checksum: u64 = 0;
            for (0..cfg.operations) |i| {
                const key = @as(u64, @intCast(i % cfg.working_set));

                if (!map.remove(key)) return error.BenchmarkInvariantFailed;
                try map.put(key, key +% @as(u64, @intCast(i)));

                checksum +%= map.get(key).?;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            if (map.count() != cfg.working_set) return error.BenchmarkInvariantFailed;
            return .{
                .ns_per_op = @as(u64, @intCast(elapsed_ns / cfg.operations)),
                .checksum = checksum,
            };
        }

        fn insertLight(io: Io, allocator: std.mem.Allocator, cfg: Config) !Result {
            var map = try initMap(allocator, cfg.operations * 2, true);
            defer map.deinit();

            var queue = try allocator.alloc(u64, cfg.operations);
            defer allocator.free(queue);
            var head: usize = 0;
            var tail: usize = 0;
            var deletes: usize = 0;

            const start = Io.Timestamp.now(io, .awake);
            var checksum: u64 = 0;

            for (0..cfg.operations) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
                queue[tail] = key;
                tail += 1;

                if ((i & 255) == 255 and head < tail) {
                    const victim = queue[head];
                    head += 1;
                    if (!map.remove(victim)) return error.BenchmarkInvariantFailed;
                    deletes += 1;
                }

                checksum +%= map.get(key).?;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            const expected = cfg.operations - deletes;
            if (map.count() != expected) return error.BenchmarkInvariantFailed;
            return .{
                .ns_per_op = @as(u64, @intCast(elapsed_ns / cfg.operations)),
                .checksum = checksum,
            };
        }

        fn insertNearFull(io: Io, allocator: std.mem.Allocator, cfg: Config) !Result {
            var map = try initMap(allocator, cfg.working_set, true);
            defer map.deinit();

            const prefill = cfg.working_set - cfg.working_set / 8;
            var queue = try allocator.alloc(u64, prefill + cfg.operations);
            defer allocator.free(queue);
            var head: usize = 0;
            var tail: usize = 0;

            for (0..prefill) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
                queue[tail] = key;
                tail += 1;
            }

            var deletes: usize = 0;
            const start = Io.Timestamp.now(io, .awake);
            var checksum: u64 = 0;

            for (0..cfg.operations) |i| {
                const key = @as(u64, @intCast(prefill + i));
                try map.put(key, key);
                queue[tail] = key;
                tail += 1;

                if ((i & 127) == 127 and head < tail) {
                    const victim = queue[head];
                    head += 1;
                    if (!map.remove(victim)) return error.BenchmarkInvariantFailed;
                    deletes += 1;
                }

                checksum +%= map.get(key).?;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            const expected = prefill + cfg.operations - deletes;
            if (map.count() != expected) return error.BenchmarkInvariantFailed;
            return .{
                .ns_per_op = @as(u64, @intCast(elapsed_ns / cfg.operations)),
                .checksum = checksum,
            };
        }

        fn lookupHit(io: Io, allocator: std.mem.Allocator, case: LoadCase) !Result {
            const items = loadItemCount(case);
            var map = try initMap(allocator, items, true);
            defer map.deinit();

            for (0..items) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
            }

            const start = Io.Timestamp.now(io, .awake);
            var checksum: u64 = 0;
            for (0..case.operations) |i| {
                const key = @as(u64, @intCast(i % items));
                checksum +%= map.get(key).?;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            return .{
                .ns_per_op = nsPerOp(elapsed_ns, case.operations),
                .checksum = checksum,
            };
        }

        fn lookupMiss(io: Io, allocator: std.mem.Allocator, case: LoadCase) !Result {
            const items = loadItemCount(case);
            var map = try initMap(allocator, items, true);
            defer map.deinit();

            for (0..items) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
            }

            const start = Io.Timestamp.now(io, .awake);
            var checksum: u64 = 0;
            for (0..case.operations) |i| {
                const key = @as(u64, @intCast(items + i));
                const miss = map.get(key) == null;
                checksum ^= @as(u64, @intFromBool(miss)) +% key;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            return .{
                .ns_per_op = nsPerOp(elapsed_ns, case.operations),
                .checksum = checksum,
            };
        }

        fn insertLoad(io: Io, allocator: std.mem.Allocator, case: LoadCase) !Result {
            const items = loadItemCount(case);
            var map = try initMap(allocator, items, true);
            defer map.deinit();

            const start = Io.Timestamp.now(io, .awake);
            var checksum: u64 = 0;
            for (0..items) |i| {
                const key = @as(u64, @intCast(i));
                try map.put(key, key);
                checksum +%= key;
            }

            const end = Io.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(start.durationTo(end).toNanoseconds());
            if (map.count() != items) return error.BenchmarkInvariantFailed;
            return .{
                .ns_per_op = @as(u64, @intCast(elapsed_ns / items)),
                .checksum = checksum,
            };
        }
    };
}

fn loadItemCount(case: LoadCase) usize {
    return case.capacity * case.load_num / case.load_den;
}

fn nsPerOp(elapsed_ns: u64, ops: usize) u64 {
    const div = elapsed_ns / ops;
    return if (div == 0) 1 else div;
}

fn ratioAgainstStd(std_ns_per_op: u64, ns_per_op: u64) f64 {
    return @as(f64, @floatFromInt(std_ns_per_op)) / @as(f64, @floatFromInt(ns_per_op));
}

fn runConfigBenchmark(comptime fn_name: []const u8, io: Io, allocator: std.mem.Allocator, cfg: Config) ![bench_specs.len]Result {
    var results: [bench_specs.len]Result = undefined;
    inline for (bench_specs, 0..) |spec, idx| {
        results[idx] = try @field(spec.Bench, fn_name)(io, allocator, cfg);
    }
    return results;
}

fn runLoadBenchmark(comptime fn_name: []const u8, io: Io, allocator: std.mem.Allocator, case: LoadCase) ![bench_specs.len]Result {
    var results: [bench_specs.len]Result = undefined;
    inline for (bench_specs, 0..) |spec, idx| {
        results[idx] = try @field(spec.Bench, fn_name)(io, allocator, case);
    }
    return results;
}

fn printBenchmarkLine(stdout: anytype, comptime show_ratio: bool, label: []const u8, results: [bench_specs.len]Result) !void {
    try stdout.print("  {s:<16}", .{label});
    inline for (bench_specs, 0..) |spec, idx| {
        if (show_ratio and idx != 0) {
            try stdout.print(
                " {s}={d:>8} ({d:.2}x)",
                .{ spec.short_label, results[idx].ns_per_op, ratioAgainstStd(results[0].ns_per_op, results[idx].ns_per_op) },
            );
        } else {
            try stdout.print(" {s}={d:>8}", .{ spec.short_label, results[idx].ns_per_op });
        }
    }
    try stdout.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [0x400]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const configs = [_]Config{
        .{ .working_set = 256, .operations = 5_000 },
        .{ .working_set = 2 * 1024, .operations = 20_000 },
        .{ .working_set = 4 * 1024, .operations = 40_000 },
    };

    for (configs, 0..) |cfg, i| {
        try stdout.print(
            "case {d}: working_set={d} operations={d}\n",
            .{ i + 1, cfg.working_set, cfg.operations },
        );
        try stdout.flush();

        inline for (config_benchmarks) |benchmark| {
            const results = try runConfigBenchmark(benchmark.fn_name, io, arena, cfg);
            try printBenchmarkLine(stdout, true, benchmark.label, results);
            try stdout.flush();
        }
    }

    const load_cases = [_]LoadCase{
        .{ .capacity = 1 << 16, .load_num = 4, .load_den = 8, .operations = 2_000_000 },
        .{ .capacity = 1 << 16, .load_num = 5, .load_den = 8, .operations = 2_000_000 },
        .{ .capacity = 1 << 16, .load_num = 6, .load_den = 8, .operations = 2_000_000 },
        .{ .capacity = 1 << 16, .load_num = 7, .load_den = 8, .operations = 2_000_000 },
    };

    try stdout.print("\n=== Load Benchmarks ===\n", .{});
    try stdout.flush();

    for (load_cases) |case| {
        const items = loadItemCount(case);
        try stdout.print(
            "load {d}/{d} (items={d})\n",
            .{ case.load_num, case.load_den, items },
        );
        try stdout.flush();

        inline for (load_benchmarks) |benchmark| {
            const results = try runLoadBenchmark(benchmark.fn_name, io, arena, case);
            try printBenchmarkLine(stdout, false, benchmark.label, results);
            try stdout.flush();
        }
    }
}

test "QfHashMap delete churn preserves entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map = try QfMap.initCapacity(allocator, 256 * 2);
    defer map.deinit();

    var live = try allocator.alloc(u64, 256);
    for (0..256) |i| {
        const key: u64 = @intCast(i);
        try map.put(key, key);
        live[i] = key;
    }

    var next: u64 = 256;
    for (0..5000) |i| {
        const slot = i % 256;
        const old = live[slot];

        try std.testing.expect(map.get(old) != null);
        try std.testing.expect(map.remove(old));

        const key = next;
        next += 1;
        try map.put(key, key);
        live[slot] = key;

        try std.testing.expectEqual(key, map.get(key).?);
    }

    try std.testing.expectEqual(@as(usize, 256), map.count());
}

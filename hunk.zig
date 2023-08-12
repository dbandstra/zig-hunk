const std = @import("std");
const builtin = @import("builtin");

pub const HunkSide = struct {
    pub const VTable = struct {
        alloc: *const fn (self: *Hunk, n: usize, alignment: u8) ?[*]u8,
        getMark: *const fn (self: *Hunk) usize,
        freeToMark: *const fn (self: *Hunk, pos: usize) void,
    };

    hunk: *Hunk,
    vtable: *const VTable,

    const allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = &allocFn,
        .resize = &resizeFn,
        .free = &freeFn,
    };

    fn init(hunk: *Hunk, vtable: *const VTable) HunkSide {
        return .{
            .hunk = hunk,
            .vtable = vtable,
        };
    }

    pub fn allocator(self: *const HunkSide) std.mem.Allocator {
        return .{
            .ptr = @constCast(self),
            .vtable = &allocator_vtable,
        };
    }

    pub fn getMark(self: HunkSide) usize {
        return self.vtable.getMark(self.hunk);
    }

    pub fn freeToMark(self: HunkSide, pos: usize) void {
        self.vtable.freeToMark(self.hunk, pos);
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *const HunkSide = @ptrCast(@alignCast(ctx));
        return self.vtable.alloc(self.hunk, len, ptr_align);
    }

    fn resizeFn(_: *anyopaque, old_mem: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = buf_align;
        _ = ret_addr;
        return new_len <= old_mem.len;
    }

    fn freeFn(_: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
    }
};

pub const Hunk = struct {
    low_used: usize,
    high_used: usize,
    buffer: []u8,

    pub fn init(buffer: []u8) Hunk {
        return .{
            .low_used = 0,
            .high_used = 0,
            .buffer = buffer,
        };
    }

    pub fn low(self: *Hunk) HunkSide {
        const GlobalStorage = struct {
            const vtable: HunkSide.VTable = .{
                .alloc = &allocLow,
                .getMark = &getLowMark,
                .freeToMark = &freeToLowMark,
            };
        };
        return HunkSide.init(self, &GlobalStorage.vtable);
    }

    pub fn high(self: *Hunk) HunkSide {
        const GlobalStorage = struct {
            const vtable: HunkSide.VTable = .{
                .alloc = &allocHigh,
                .getMark = &getHighMark,
                .freeToMark = &freeToHighMark,
            };
        };
        return HunkSide.init(self, &GlobalStorage.vtable);
    }

    pub fn allocLow(self: *Hunk, n: usize, ptr_align: u8) ?[*]u8 {
        const alignment = @as(u29, 1) << @as(u5, @intCast(ptr_align));
        const start = @intFromPtr(self.buffer.ptr);
        const adjusted_index = std.mem.alignForward(usize, start + self.low_used, alignment) - start;
        const new_low_used = adjusted_index + n;
        if (new_low_used > self.buffer.len - self.high_used) {
            return null;
        }
        const result = self.buffer[adjusted_index..new_low_used];
        self.low_used = new_low_used;
        return result.ptr;
    }

    pub fn allocHigh(self: *Hunk, n: usize, ptr_align: u8) ?[*]u8 {
        const alignment = @as(u29, 1) << @as(u5, @intCast(ptr_align));
        const addr = @intFromPtr(self.buffer.ptr) + self.buffer.len - self.high_used;
        const rem = @rem(addr, alignment);
        const march_backward_bytes = rem;
        const adjusted_index = self.high_used + march_backward_bytes;
        const new_high_used = adjusted_index + n;
        if (new_high_used > self.buffer.len - self.low_used) {
            return null;
        }
        const start = self.buffer.len - adjusted_index - n;
        const result = self.buffer[start .. start + n];
        self.high_used = new_high_used;
        return result.ptr;
    }

    pub fn getLowMark(self: *Hunk) usize {
        return self.low_used;
    }

    pub fn getHighMark(self: *Hunk) usize {
        return self.high_used;
    }

    pub fn freeToLowMark(self: *Hunk, pos: usize) void {
        std.debug.assert(pos <= self.low_used);
        if (pos < self.low_used) {
            if (builtin.mode == .Debug) {
                @memset(self.buffer[pos..self.low_used], 0xcc);
            }
            self.low_used = pos;
        }
    }

    pub fn freeToHighMark(self: *Hunk, pos: usize) void {
        std.debug.assert(pos <= self.high_used);
        if (pos < self.high_used) {
            if (builtin.mode == .Debug) {
                const i = self.buffer.len - self.high_used;
                const n = self.high_used - pos;
                @memset(self.buffer[i .. i + n], 0xcc);
            }
            self.high_used = pos;
        }
    }
};

test "Hunk" {
    // test a few random operations. very low coverage. write more later
    var buf: [100]u8 = undefined;
    var hunk = Hunk.init(buf[0..]);

    const high_mark = hunk.getHighMark();

    var hunk_low = hunk.low();
    var hunk_high = hunk.high();

    _ = try hunk_low.allocator().alloc(u8, 7);
    _ = try hunk_high.allocator().alloc(u8, 8);

    try std.testing.expectEqual(@as(usize, 7), hunk.low_used);
    try std.testing.expectEqual(@as(usize, 8), hunk.high_used);

    _ = try hunk_high.allocator().alloc(u8, 8);

    try std.testing.expectEqual(@as(usize, 16), hunk.high_used);

    const low_mark = hunk.getLowMark();

    _ = try hunk_low.allocator().alloc(u8, 100 - 7 - 16);

    try std.testing.expectEqual(@as(usize, 100 - 16), hunk.low_used);

    try std.testing.expectError(error.OutOfMemory, hunk_high.allocator().alloc(u8, 1));

    hunk.freeToLowMark(low_mark);

    _ = try hunk_high.allocator().alloc(u8, 1);

    hunk.freeToHighMark(high_mark);

    try std.testing.expectEqual(@as(usize, 0), hunk.high_used);
}

test "resizing" {
    var buf: [100]u8 = undefined;
    var hunk = Hunk.init(buf[0..]);
    var hunk_low = hunk.low();
    const allocator = hunk_low.allocator();
    const memory = try allocator.alloc(u8, 7);
    try std.testing.expect(!allocator.resize(memory, 8));
    try std.testing.expect(allocator.resize(memory, 7));
    try std.testing.expect(allocator.resize(memory, 6));
}

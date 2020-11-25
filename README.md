# zig-hunk
A basic "Hunk" memory allocator, based on (and name taken from) the hunk system from id Software's Quake engine. A more descriptive name might be "double-sided stack allocator based on a fixed block of memory".

Requires Zig 0.7.0.

## Usage
A new `Hunk` must be provided with an array of bytes. This block of memory is all there is - hunk allocators will return "out of memory" errors when the block is full.

```zig
var mem: [100000]u8 = undefined;
var hunk = Hunk.init(mem);
```

The `Hunk` has two "sides", low and high. They're basically stacks which start at opposite ends of the memory buffer and grow inward. When the two stacks collide, you've run out of memory.

The hunk sides act as Zig allocators, but `free` has no effect. Instead, you free memory using two special methods, `getMark` and `freeToMark`.

You call `getMark`, then allocate some memory using the allocator API, then when you're done, call `freeToMark` with the value you got from `getMark`. This "frees" everything you allocated since you called `getMark`.

Example:

```zig
var side = hunk.low(); // or hunk.high()

const mark = side.getMark();
defer side.freeToMark();

var memory = try side.allocator.alloc(u8, 123);
var memory2 = try side.allocator.alloc(u8, 456);
var memory3 = try std.mem.dupe(&side.allocator, u8, "hello");
```

The two sides can be used independently. You could for example use one side for more persistent allocations, and the other side for temporary allocations.

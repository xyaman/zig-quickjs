# zig-quickjs

Zig bindings for [quickjs-ng](https://github.com/quickjs-ng/quickjs).

## Installation

Requires Zig `0.16.0`.

```
zig fetch --save=quickjs \
  https://github.com/nDimensional/zig-quickjs/archive/{COMMIT}.tar.gz
```

## Documentation

https://ndimensional.github.io/zig-quickjs/

## Usage

```zig
const std = @import("std");
const quickjs = @import("quickjs");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Create a runtime and context
    const rt = try quickjs.Runtime.init(allocator);
    defer rt.deinit();

    const ctx = quickjs.Context.init(rt);
    defer ctx.deinit();

    // Evaluate JavaScript
    const result = try ctx.eval("1 + 2", "test.js", .{});
    defer ctx.freeValue(result);

    const num = try ctx.toInt32(result);
    std.debug.print("1 + 2 = {d}\n", .{num});
}
```

## Values and Properties

```zig
const global = ctx.getGlobalObject();
defer ctx.freeValue(global);

const obj = ctx.newObject();
defer ctx.freeValue(obj);

// Set properties
const key = ctx.newAtom("greeting");
defer ctx.freeAtom(key);
const val = ctx.newString("hello");
try ctx.setProperty(obj, key, val);
defer ctx.freeValue(val);

// Read properties
const got = ctx.getProperty(obj, key);
defer ctx.freeValue(got);
```

## UTF-16 strings

`Context.toCStringUTF16(value)` returns a `[]const u16` with no NUL terminator.
The length counts UTF-16 code units. The result can contain unmatched surrogates.
The caller releases the result with `Context.freeCStringUTF16(text.ptr)` or
`Runtime.freeCStringUTF16(text.ptr)`. The result stays valid until that release,
even if the caller releases the JavaScript value first.

## Calling JavaScript Functions

```zig
const result = try ctx.eval("(function(x, y) { return x * y; })", "test.js", .{});
defer ctx.freeValue(result);

var args = [_]quickjs.Value{ ctx.newInt32(6), ctx.newInt32(7) };
defer for (args) |a| ctx.freeValue(a);

const ret = ctx.call(result, quickjs.NULL, &args);
defer ctx.freeValue(ret);

const product = try ctx.toInt32(ret);
std.debug.print("6 * 7 = {d}\n", .{product});
```

## Exposing Functions to JavaScript

```zig
const jsAdd = struct {
    fn call(ctx: quickjs.Context, this_val: quickjs.Value, args: []const quickjs.Value) quickjs.Value {
        if (args.len < 2) return quickjs.NULL;
        const a = ctx.toInt32(args[0]) catch return quickjs.NULL;
        const b = ctx.toInt32(args[1]) catch return quickjs.NULL;
        return ctx.newInt32(a + b);
    }
};

const func = ctx.newFunction("add", 2, jsAdd.call);
// setPropertyStr takes ownership of func
try ctx.setPropertyStr(global, "add", func);
```

## Interrupt Handlers

```zig
const Handler = struct {
    counter: u32 = 0,

    pub fn onInterrupt(self: *Handler) bool {
        self.counter += 1;
        return self.counter >= 1000;
    }
};

var handler = Handler{};
runtime.setInterruptHandler(&handler);
```

## Custom Classes

```zig
const MyClass = struct {
    pub fn finalizer(rt: quickjs.RuntimeHandle, val: quickjs.Value) void {
        // cleanup when instance is GC'd
    }
};

const class_id = runtime.newClassID();
try runtime.newClass(class_id, .{
    .name = "MyClass",
    .finalizer = MyClass.finalizer,
});

const obj = ctx.newObjectClass(class_id);
```

## License

MIT

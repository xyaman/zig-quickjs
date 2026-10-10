//! Zig bindings for QuickJS values, contexts, and runtimes.
const std = @import("std");
const c = @import("c");

pub const ClassID = u32;

pub const ArrayBuffer = struct {
    buffer: Value,
    byte_offset: usize,
    byte_length: usize,
    bytes_per_element: usize,
};

pub const Atom = c.JSAtom;
pub const Value = c.JSValue;

/// A lightweight handle to a runtime, passed to callbacks that receive
/// a `JSRuntime*` from C. Unlike `Runtime` (which is heap-allocated and
/// owns the allocator), this is a value type that wraps the raw C pointer.
pub const RuntimeHandle = struct {
    ptr: ?*c.JSRuntime,

    pub inline fn freeValue(self: RuntimeHandle, val: Value) void {
        c.JS_FreeValueRT(self.ptr, val);
    }

    pub inline fn dupValue(self: RuntimeHandle, val: Value) Value {
        return c.JS_DupValueRT(self.ptr, val);
    }
};

/// A property enumeration entry, returned by `Context.getOwnPropertyNames`.
pub const PropertyEnum = extern struct {
    is_enumerable: bool,
    atom: Atom,
};

/// GC marker passed to class `gc_mark` callbacks. Call `mark` for each
/// reachable `Value` to prevent it from being collected.
pub const Marker = struct {
    rt: ?*c.JSRuntime,
    func: c.JS_MarkFunc,

    pub inline fn mark(self: Marker, val: Value) void {
        c.JS_MarkValue(self.rt, val, self.func);
    }
};

/// Definition for a custom class, passed to `Runtime.newClass`.
/// All callbacks are optional — set to `null` if not needed.
pub const ClassDef = struct {
    name: [*:0]const u8,
    finalizer: ?*const fn (RuntimeHandle, Value) void = null,
    gc_mark: ?*const fn (RuntimeHandle, Value, Marker) void = null,
    call: ?*const fn (Context, Value, Value, []const Value, c_int) Value = null,
};

pub const PromiseHookType = enum(c_int) {
    Init = c.JS_PROMISE_HOOK_INIT,
    Before = c.JS_PROMISE_HOOK_BEFORE,
    After = c.JS_PROMISE_HOOK_AFTER,
    Resolve = c.JS_PROMISE_HOOK_RESOLVE,
};

pub const NULL = Value{ .tag = c.JS_TAG_NULL, .u = .{ .int32 = 0 } };
pub const UNDEFINED = Value{ .tag = c.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } };
pub const FALSE = Value{ .tag = c.JS_TAG_BOOL, .u = .{ .int32 = 0 } };
pub const TRUE = Value{ .tag = c.JS_TAG_BOOL, .u = .{ .int32 = 1 } };
pub const UNINITIALIZED = Value{ .tag = c.JS_TAG_UNINITIALIZED, .u = .{ .int32 = 0 } };

// pub const EXCEPTION = c.JS_EXCEPTION;

pub const TypedArrayType = enum(c_int) {
    Uint8ClampedArray = c.JS_TYPED_ARRAY_UINT8C,
    Int8Array = c.JS_TYPED_ARRAY_INT8,
    Uint8Array = c.JS_TYPED_ARRAY_UINT8,
    Int16Array = c.JS_TYPED_ARRAY_INT16,
    Uint16Array = c.JS_TYPED_ARRAY_UINT16,
    Int32Array = c.JS_TYPED_ARRAY_INT32,
    Uint32Array = c.JS_TYPED_ARRAY_UINT32,
    BigInt64Array = c.JS_TYPED_ARRAY_BIG_INT64,
    BigUint64Array = c.JS_TYPED_ARRAY_BIG_UINT64,
    Float16Array = c.JS_TYPED_ARRAY_FLOAT16,
    Float32Array = c.JS_TYPED_ARRAY_FLOAT32,
    Float64Array = c.JS_TYPED_ARRAY_FLOAT64,
    _,
};

pub inline fn getVersion() [*:0]const u8 {
    return c.JS_GetVersion();
}

pub inline fn newRuntime() ?*c.JSRuntime {
    return c.JS_NewRuntime();
}

const S = @sizeOf(usize);
const H = @max(8, S);

fn makeFinalizerThunk(comptime f: *const fn (RuntimeHandle, Value) void) ?*const c.JSClassFinalizer {
    const Thunk = struct {
        fn call(rt: ?*c.JSRuntime, val: c.JSValue) callconv(.c) void {
            f(.{ .ptr = rt }, val);
        }
    };
    return @ptrCast(&Thunk.call);
}

fn makeGcMarkThunk(comptime gm: *const fn (RuntimeHandle, Value, Marker) void) ?*const c.JSClassGCMark {
    const Thunk = struct {
        fn call(rt: ?*c.JSRuntime, val: c.JSValue, mark_func: c.JS_MarkFunc) callconv(.c) void {
            gm(.{ .ptr = rt }, val, .{ .rt = rt, .func = mark_func });
        }
    };
    return @ptrCast(&Thunk.call);
}

fn makeCallThunk(comptime cl: *const fn (Context, Value, Value, []const Value, c_int) Value) ?*const c.JSClassCall {
    const Thunk = struct {
        fn call(ctx: ?*c.JSContext, func_obj: c.JSValue, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue, flags: c_int) callconv(.c) c.JSValue {
            const ctx_wrapper = Context{ .ptr = ctx };
            const args: []const Value = @as([*]const Value, @ptrCast(argv))[0..@as(usize, @intCast(argc))];
            return cl(ctx_wrapper, func_obj, this_val, args, flags);
        }
    };
    return @ptrCast(&Thunk.call);
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    ptr: ?*c.JSRuntime,

    fn js_calloc(runtime_ptr: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
        const runtime: *const Runtime = @ptrCast(@alignCast(runtime_ptr));
        const len = count * size;
        const result = runtime.allocator.alloc(u8, H + len) catch return null;
        @memset(result, 0);
        std.mem.writeInt(usize, result[0..S], len, .little);
        return result[H..].ptr;
    }

    fn js_malloc(runtime_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const runtime: *const Runtime = @ptrCast(@alignCast(runtime_ptr));
        const result = runtime.allocator.alloc(u8, H + size) catch return null;
        std.mem.writeInt(usize, result[0..S], size, .little);
        return result[H..].ptr;
    }

    fn js_free(runtime_ptr: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const runtime: *const Runtime = @ptrCast(@alignCast(runtime_ptr));
        const result: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - H);
        const len = std.mem.readInt(usize, result[0..S], .little);
        runtime.allocator.free(result[0 .. H + len]);
    }

    fn js_realloc(runtime_ptr: ?*anyopaque, ptr: ?*anyopaque, new_len: usize) callconv(.c) ?*anyopaque {
        const runtime: *const Runtime = @ptrCast(@alignCast(runtime_ptr));
        const old_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - H);
        const old_len = std.mem.readInt(usize, old_ptr[0..S], .little);
        const result = runtime.allocator.realloc(old_ptr[0 .. H + old_len], H + new_len) catch return null;
        std.mem.writeInt(usize, result[0..S], new_len, .little);
        return result[H..].ptr;
    }

    fn js_malloc_usable_size(_: ?*const anyopaque) callconv(.c) usize {
        return 0;
    }

    const malloc_functions = c.JSMallocFunctions{
        .js_calloc = &js_calloc,
        .js_malloc = &js_malloc,
        .js_free = &js_free,
        .js_realloc = &js_realloc,
        .js_malloc_usable_size = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*Runtime {
        const runtime = try allocator.create(Runtime);
        runtime.allocator = allocator;
        runtime.ptr = c.JS_NewRuntime2(&malloc_functions, @constCast(runtime));
        return runtime;
    }

    pub fn deinit(self: *const Runtime) void {
        c.JS_FreeRuntime(self.ptr);
        self.allocator.destroy(self);
    }

    /// use 0 to disable memory limit
    pub inline fn setMemoryLimit(self: *const Runtime, limit: usize) void {
        c.JS_SetMemoryLimit(self.ptr, limit);
    }

    pub inline fn setGCThreshold(self: *const Runtime, gc_threshold: usize) void {
        c.JS_SetGCThreshold(self.ptr, gc_threshold);
    }

    pub inline fn getGCThreshold(self: *const Runtime) usize {
        return c.JS_GetGCThreshold(self.ptr);
    }

    pub inline fn setMaxStackSize(self: *const Runtime, stack_size: usize) void {
        c.JS_SetMaxStackSize(self.ptr, stack_size);
    }

    pub inline fn updateStackTop(self: *const Runtime) void {
        c.JS_UpdateStackTop(self.ptr);
    }

    pub inline fn setRuntimeInfo(self: *const Runtime, info: []const u8) void {
        c.JS_SetRuntimeInfo(self.ptr, info.ptr);
    }

    pub inline fn setDumpFlags(self: *const Runtime, flags: u64) void {
        c.JS_SetDumpFlags(self.ptr, flags);
    }

    pub inline fn getDumpFlags(self: *const Runtime) u64 {
        return c.JS_GetDumpFlags(self.ptr);
    }

    pub inline fn setRuntimeOpaque(self: *const Runtime, ptr: ?*anyopaque) void {
        c.JS_SetRuntimeOpaque(self.ptr, ptr);
    }

    pub inline fn getRuntimeOpaque(self: *const Runtime) ?*anyopaque {
        return c.JS_GetRuntimeOpaque(self.ptr);
    }

    pub inline fn runGC(self: *const Runtime) void {
        c.JS_RunGC(self.ptr);
    }

    pub inline fn isLiveObject(self: *const Runtime, obj: Value) bool {
        return c.JS_IsLiveObject(self.ptr, obj);
    }

    pub inline fn freeValue(self: *const Runtime, val: Value) void {
        c.JS_FreeValueRT(self.ptr, val);
    }

    pub inline fn dupValue(self: *const Runtime, val: Value) Value {
        return c.JS_DupValueRT(self.ptr, val);
    }

    pub inline fn dupAtom(self: *const Runtime, atom: Atom) Atom {
        return c.JS_DupAtomRT(self.ptr, atom);
    }

    pub inline fn freeAtom(self: *const Runtime, atom: Atom) void {
        c.JS_FreeAtomRT(self.ptr, atom);
    }

    pub inline fn freeCString(self: *const Runtime, ptr: [*:0]const u8) void {
        c.JS_FreeCStringRT(self.ptr, ptr);
    }

    /// Release a UTF-16 result from this runtime. The pointer has no terminator. This does not fail.
    pub inline fn freeCStringUTF16(self: *const Runtime, ptr: [*]const u16) void {
        c.JS_FreeCStringRT_UTF16(self.ptr, ptr);
    }

    pub inline fn newClassID(self: *const Runtime) ClassID {
        var class_id: ClassID = 0;
        _ = c.JS_NewClassID(self.ptr, &class_id);
        return class_id;
    }

    pub inline fn isRegisteredClass(self: *const Runtime, class_id: ClassID) bool {
        return c.JS_IsRegisteredClass(self.ptr, class_id);
    }

    pub fn newClass(self: *const Runtime, class_id: ClassID, comptime def: ClassDef) !void {
        const c_def = c.JSClassDef{
            .class_name = def.name,
            .finalizer = if (def.finalizer) |f| makeFinalizerThunk(f) else null,
            .gc_mark = if (def.gc_mark) |gm| makeGcMarkThunk(gm) else null,
            .call = if (def.call) |cl| makeCallThunk(cl) else null,
            .exotic = null,
        };
        if (c.JS_NewClass(self.ptr, class_id, &c_def) < 0)
            return error.NewClassFailed;
    }

    pub inline fn getClassName(self: *const Runtime, class_id: ClassID) Atom {
        return c.JS_GetClassName(self.ptr, class_id);
    }

    // Job queue management
    pub inline fn isJobPending(self: *const Runtime) bool {
        return c.JS_IsJobPending(self.ptr);
    }

    pub inline fn executePendingJob(self: *const Runtime) !?Context {
        var pctx: ?*c.JSContext = null;
        const ret = c.JS_ExecutePendingJob(self.ptr, &pctx);
        if (ret < 0) return error.ExecuteJobFailed;
        if (pctx == null) return null;
        return Context{ .ptr = pctx };
    }

    pub const MemoryUsage = packed struct {
        malloc_size: i64,
        malloc_limit: i64,
        memory_used_size: i64,
        malloc_count: i64,
        memory_used_count: i64,
        atom_count: i64,
        atom_size: i64,
        str_count: i64,
        str_size: i64,
        obj_count: i64,
        obj_size: i64,
        prop_count: i64,
        prop_size: i64,
        shape_count: i64,
        shape_size: i64,
        js_func_count: i64,
        js_func_size: i64,
        js_func_code_size: i64,
        js_func_pc2line_count: i64,
        js_func_pc2line_size: i64,
        c_func_count: i64,
        array_count: i64,
        fast_array_count: i64,
        fast_array_elements: i64,
        binary_object_count: i64,
        binary_object_size: i64,
    };

    // Memory management utilities
    pub inline fn computeMemoryUsage(self: *const Runtime) MemoryUsage {
        var usage: c.JSMemoryUsage = undefined;
        c.JS_ComputeMemoryUsage(self.ptr, &usage);
        return .{
            .malloc_size = usage.malloc_size,
            .malloc_limit = usage.malloc_limit,
            .memory_used_size = usage.memory_used_size,
            .malloc_count = usage.malloc_count,
            .memory_used_count = usage.memory_used_count,
            .atom_count = usage.atom_count,
            .atom_size = usage.atom_size,
            .str_count = usage.str_count,
            .str_size = usage.str_size,
            .obj_count = usage.obj_count,
            .obj_size = usage.obj_size,
            .prop_count = usage.prop_count,
            .prop_size = usage.prop_size,
            .shape_count = usage.shape_count,
            .shape_size = usage.shape_size,
            .js_func_count = usage.js_func_count,
            .js_func_size = usage.js_func_size,
            .js_func_code_size = usage.js_func_code_size,
            .js_func_pc2line_count = usage.js_func_pc2line_count,
            .js_func_pc2line_size = usage.js_func_pc2line_size,
            .c_func_count = usage.c_func_count,
            .array_count = usage.array_count,
            .fast_array_count = usage.fast_array_count,
            .fast_array_elements = usage.fast_array_elements,
            .binary_object_count = usage.binary_object_count,
            .binary_object_size = usage.binary_object_size,
        };
    }

    pub inline fn dumpMemoryUsage(self: *const Runtime, usage: *const MemoryUsage, file: std.fs.File) void {
        c.JS_DumpMemoryUsage(file.handle, &.{
            .malloc_size = usage.malloc_size,
            .malloc_limit = usage.malloc_limit,
            .memory_used_size = usage.memory_used_size,
            .malloc_count = usage.malloc_count,
            .memory_used_count = usage.memory_used_count,
            .atom_count = usage.atom_count,
            .atom_size = usage.atom_size,
            .str_count = usage.str_count,
            .str_size = usage.str_size,
            .obj_count = usage.obj_count,
            .obj_size = usage.obj_size,
            .prop_count = usage.prop_count,
            .prop_size = usage.prop_size,
            .shape_count = usage.shape_count,
            .shape_size = usage.shape_size,
            .js_func_count = usage.js_func_count,
            .js_func_size = usage.js_func_size,
            .js_func_code_size = usage.js_func_code_size,
            .js_func_pc2line_count = usage.js_func_pc2line_count,
            .js_func_pc2line_size = usage.js_func_pc2line_size,
            .c_func_count = usage.c_func_count,
            .array_count = usage.array_count,
            .fast_array_count = usage.fast_array_count,
            .fast_array_elements = usage.fast_array_elements,
            .binary_object_count = usage.binary_object_count,
            .binary_object_size = usage.binary_object_size,
        }, self.ptr);
    }

    /// Set an interrupt handler. The handler struct must have an `onInterrupt` method
    /// that returns `bool` (true to interrupt execution).
    /// The handler pointer must outlive the runtime.
    pub fn setInterruptHandler(self: *const Runtime, handler: anytype) void {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(_: ?*c.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                return if (h.onInterrupt()) 1 else 0;
            }
        };
        c.JS_SetInterruptHandler(self.ptr, @ptrCast(&trampoline.call), @ptrCast(handler));
    }

    /// Set a promise rejection tracker. The handler struct must have an `onRejection` method
    /// with signature `fn(self, ctx: Context, promise: Value, reason: Value, is_handled: bool) void`.
    /// The handler pointer must outlive the runtime.
    pub fn setHostPromiseRejectionTracker(self: *const Runtime, handler: anytype) void {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(ctx: ?*c.JSContext, promise: c.JSValue, reason: c.JSValue, is_handled: bool, opaque_ptr: ?*anyopaque) callconv(.c) void {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                h.onRejection(Context{ .ptr = ctx }, promise, reason, is_handled);
            }
        };
        c.JS_SetHostPromiseRejectionTracker(self.ptr, @ptrCast(&trampoline.call), @ptrCast(handler));
    }

    /// Set a promise hook. The handler struct must have an `onPromiseHook` method
    /// with signature `fn(self, ctx: Context, hook_type: PromiseHookType, promise: Value, parent: Value) void`.
    /// The handler pointer must outlive the runtime.
    pub fn setPromiseHook(self: *const Runtime, handler: anytype) void {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(ctx: ?*c.JSContext, hook_type: c.JSPromiseHookType, promise: c.JSValue, parent_promise: c.JSValue, opaque_ptr: ?*anyopaque) callconv(.c) void {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                h.onPromiseHook(Context{ .ptr = ctx }, @enumFromInt(hook_type), promise, parent_promise);
            }
        };
        c.JS_SetPromiseHook(self.ptr, @ptrCast(&trampoline.call), @ptrCast(handler));
    }

    /// Set a module loader. The handler struct must have an `onLoadModule` method
    /// with signature `fn(self, ctx: Context, name: []const u8) ?Module`.
    /// It may optionally have an `onNormalize` method
    /// with signature `fn(self, ctx: Context, base_name: []const u8, module_name: []const u8) ?[:0]u8`.
    /// The handler pointer must outlive the runtime.
    pub fn setModuleLoader(self: *const Runtime, handler: anytype) void {
        const Handler = @TypeOf(handler);

        const loader_trampoline = struct {
            fn call(ctx: ?*c.JSContext, module_name: [*c]const u8, opaque_ptr: ?*anyopaque) callconv(.c) ?*c.JSModuleDef {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                const name_len = std.mem.len(module_name);
                const result = h.onLoadModule(Context{ .ptr = ctx }, module_name[0..name_len]);
                return if (result) |m| m.ptr else null;
            }
        };

        const has_normalize = @hasDecl(std.meta.Child(Handler), "onNormalize");
        const normalize_ptr: ?*const c.JSModuleNormalizeFunc = if (has_normalize) blk: {
            const trampoline = struct {
                fn call(ctx: ?*c.JSContext, module_base_name: [*c]const u8, module_name: [*c]const u8, opaque_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
                    const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                    const base_len = std.mem.len(module_base_name);
                    const name_len = std.mem.len(module_name);
                    const result = h.onNormalize(Context{ .ptr = ctx }, module_base_name[0..base_len], module_name[0..name_len]);
                    return if (result) |s| s.ptr else null;
                }
            };
            break :blk @ptrCast(&trampoline.call);
        } else null;

        c.JS_SetModuleLoaderFunc(self.ptr, normalize_ptr, @ptrCast(&loader_trampoline.call), @ptrCast(handler));
    }

    pub fn setModuleLoader2(self: *const Runtime, handler: anytype) void {
        const Handler = @TypeOf(handler);
        const Child = std.meta.Child(Handler);

        const loader_trampoline = struct {
            fn call(ctx: ?*c.JSContext, module_name: [*c]const u8, opaque_ptr: ?*anyopaque, attributes: c.JSValue) callconv(.c) ?*c.JSModuleDef {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                const name_len = std.mem.len(module_name);
                const result = h.onLoadModule(Context{ .ptr = ctx }, module_name[0..name_len], attributes);
                return if (result) |m| m.ptr else null;
            }
        };

        const has_normalize = @hasDecl(Child, "onNormalize");
        const normalize_ptr: ?*const c.JSModuleNormalizeFunc = if (has_normalize) blk: {
            const trampoline = struct {
                fn call(ctx: ?*c.JSContext, module_base_name: [*c]const u8, module_name: [*c]const u8, opaque_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
                    const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                    const base_len = std.mem.len(module_base_name);
                    const name_len = std.mem.len(module_name);
                    const result = h.onNormalize(Context{ .ptr = ctx }, module_base_name[0..base_len], module_name[0..name_len]);
                    return if (result) |s| s.ptr else null;
                }
            };
            break :blk @ptrCast(&trampoline.call);
        } else null;

        const has_check = @hasDecl(Child, "onCheckImportAttributes");
        const check_ptr: ?*const c.JSModuleCheckSupportedImportAttributes = if (has_check) blk: {
            const trampoline = struct {
                fn call(ctx: ?*c.JSContext, opaque_ptr: ?*anyopaque, attributes: c.JSValue) callconv(.c) c_int {
                    const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                    return h.onCheckImportAttributes(Context{ .ptr = ctx }, attributes);
                }
            };
            break :blk @ptrCast(&trampoline.call);
        } else null;

        c.JS_SetModuleLoaderFunc2(self.ptr, normalize_ptr, @ptrCast(&loader_trampoline.call), check_ptr, @ptrCast(handler));
    }

    /// Add a runtime finalizer. The handler struct must have an `onFinalize` method
    /// with signature `fn(self) void`.
    /// The handler pointer must outlive the runtime.
    pub fn addRuntimeFinalizer(self: *const Runtime, handler: anytype) !void {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(rt: ?*c.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) void {
                _ = rt;
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                h.onFinalize();
            }
        };
        const ret = c.JS_AddRuntimeFinalizer(self.ptr, @ptrCast(&trampoline.call), @ptrCast(handler));
        if (ret < 0) return error.AddFinalizerFailed;
    }

    pub inline fn getPendingJobContext(self: *const Runtime) ?Context {
        const ctx = c.JS_GetPendingJobContext(self.ptr);
        if (ctx == null) return null;
        return Context{ .ptr = ctx };
    }

    pub inline fn setCanBlock(self: *const Runtime, can_block: bool) void {
        c.JS_SetCanBlock(self.ptr, can_block);
    }
};

pub const Context = struct {
    ptr: ?*c.JSContext,

    pub inline fn init(runtime: *const Runtime) Context {
        return .{ .ptr = c.JS_NewContext(runtime.ptr) };
    }

    pub inline fn initRaw(runtime: *const Runtime) Context {
        return .{ .ptr = c.JS_NewContextRaw(runtime.ptr) };
    }

    pub inline fn deinit(self: Context) void {
        c.JS_FreeContext(self.ptr);
    }

    pub inline fn getRuntime(self: Context) ?*c.JSRuntime {
        return c.JS_GetRuntime(self.ptr);
    }

    pub inline fn dupContext(self: Context) Context {
        return .{ .ptr = c.JS_DupContext(self.ptr) };
    }

    pub inline fn getContextOpaque(self: Context) ?*anyopaque {
        return c.JS_GetContextOpaque(self.ptr);
    }

    pub inline fn setContextOpaque(self: Context, ptr: ?*anyopaque) void {
        c.JS_SetContextOpaque(self.ptr, ptr);
    }

    pub inline fn isEqual(self: Context, a: Value, b: Value) bool {
        return c.JS_IsEqual(self.ptr, a, b);
    }

    pub inline fn isStrictEqual(self: Context, a: Value, b: Value) bool {
        return c.JS_IsStrictEqual(self.ptr, a, b);
    }

    pub inline fn isSameValue(self: Context, a: Value, b: Value) bool {
        return c.JS_IsSameValue(self.ptr, a, b);
    }

    pub inline fn isSameValueZero(self: Context, a: Value, b: Value) bool {
        return c.JS_IsSameValueZero(self.ptr, a, b);
    }

    // Value creation methods

    pub inline fn dupValue(self: Context, value: Value) Value {
        return c.JS_DupValue(self.ptr, value);
    }

    pub inline fn newBool(self: Context, val: bool) Value {
        return c.JS_NewBool(self.ptr, val);
    }

    pub inline fn newInt32(self: Context, val: i32) Value {
        return c.JS_NewInt32(self.ptr, val);
    }

    pub inline fn newFloat64(self: Context, val: f64) Value {
        return c.JS_NewFloat64(self.ptr, val);
    }

    pub inline fn newInt64(self: Context, val: i64) Value {
        return c.JS_NewInt64(self.ptr, val);
    }

    pub inline fn newUint32(self: Context, val: u32) Value {
        return c.JS_NewUint32(self.ptr, val);
    }

    pub inline fn newUint64(self: Context, val: u64) Value {
        return c.JS_NewUint64(self.ptr, val);
    }

    pub inline fn newNumber(self: Context, val: f64) Value {
        return c.JS_NewNumber(self.ptr, val);
    }

    pub inline fn newString(self: Context, str: []const u8) Value {
        return c.JS_NewStringLen(self.ptr, str.ptr, str.len);
    }

    pub inline fn newStringZ(self: Context, str: [*:0]const u8) Value {
        return c.JS_NewString(self.ptr, str);
    }

    pub inline fn newStringUTF16(self: Context, buf: [*]const u16, len: usize) Value {
        return c.JS_NewStringUTF16(self.ptr, buf, len);
    }

    pub inline fn newSymbol(self: Context, description: []const u8, is_global: bool) Value {
        return c.JS_NewSymbol(self.ptr, description.ptr, is_global);
    }

    pub inline fn newAtomString(self: Context, str: []const u8) Value {
        return c.JS_NewAtomString(self.ptr, str.ptr);
    }

    pub inline fn newObject(self: Context) Value {
        return c.JS_NewObject(self.ptr);
    }

    pub inline fn newObjectClass(self: Context, class_id: ClassID) Value {
        return c.JS_NewObjectClass(self.ptr, class_id);
    }

    pub inline fn newObjectProtoClass(self: Context, proto: Value, class_id: ClassID) Value {
        return c.JS_NewObjectProtoClass(self.ptr, proto, class_id);
    }

    pub inline fn newObjectProto(self: Context, proto: Value) Value {
        return c.JS_NewObjectProto(self.ptr, proto);
    }

    pub inline fn newObjectFrom(self: Context, count: c_int, props: [*]const Atom, values: [*]const Value) Value {
        return c.JS_NewObjectFrom(self.ptr, count, props, values);
    }

    pub inline fn newObjectFromStr(self: Context, count: c_int, props: [*][*:0]const u8, values: [*]const Value) Value {
        return c.JS_NewObjectFromStr(self.ptr, count, props, values);
    }

    pub inline fn newArray(self: Context) Value {
        return c.JS_NewArray(self.ptr);
    }

    pub inline fn newArrayFrom(self: Context, values: []const Value) Value {
        return c.JS_NewArrayFrom(self.ptr, @intCast(values.len), @constCast(values.ptr));
    }

    pub inline fn newDate(self: Context, epoch_ms: f64) Value {
        return c.JS_NewDate(self.ptr, epoch_ms);
    }

    pub inline fn newBigInt64(self: Context, val: i64) Value {
        return c.JS_NewBigInt64(self.ptr, val);
    }

    pub inline fn newBigUint64(self: Context, val: u64) Value {
        return c.JS_NewBigUint64(self.ptr, val);
    }

    pub inline fn newTypedArray(self: Context, args: []const Value, array_type: TypedArrayType) Value {
        return c.JS_NewTypedArray(self.ptr, @intCast(args.len), @constCast(args.ptr), @intFromEnum(array_type));
    }

    // Value conversion methods
    pub inline fn toBool(self: Context, val: Value) !bool {
        const result = c.JS_ToBool(self.ptr, val);
        if (result == -1) return error.Exception;
        return result != 0;
    }

    pub inline fn toBoolean(self: Context, val: Value) Value {
        return self.newBool(c.JS_ToBool(self.ptr, val) != 0);
    }

    pub inline fn toNumber(self: Context, val: Value) Value {
        return c.JS_ToNumber(self.ptr, val);
    }

    pub inline fn toInt32(self: Context, val: Value) !i32 {
        var result: i32 = undefined;
        const ret = c.JS_ToInt32(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toUint32(self: Context, val: Value) !u32 {
        var result: u32 = undefined;
        const ret = c.JS_ToUint32(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toInt64(self: Context, val: Value) !i64 {
        var result: i64 = undefined;
        const ret = c.JS_ToInt64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toFloat64(self: Context, val: Value) !f64 {
        var result: f64 = undefined;
        const ret = c.JS_ToFloat64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toBigInt64(self: Context, val: Value) !i64 {
        var result: i64 = undefined;
        const ret = c.JS_ToBigInt64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toBigUint64(self: Context, val: Value) !u64 {
        var result: u64 = undefined;
        const ret = c.JS_ToBigUint64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toString(self: Context, val: Value) Value {
        return c.JS_ToString(self.ptr, val);
    }

    pub inline fn toCString(self: Context, val: Value) ![*:0]const u8 {
        return c.JS_ToCString(self.ptr, val) orelse error.Exception;
    }

    pub inline fn toCStringLen(self: Context, val: Value) ![:0]const u8 {
        var len: usize = undefined;
        const ptr = c.JS_ToCStringLen(self.ptr, &len, val) orelse
            return error.Exception;
        return ptr[0..len :0];
    }

    pub inline fn toCStringLen2(self: Context, val: Value, cesu8: bool) ![:0]const u8 {
        var len: usize = undefined;
        const ptr = c.JS_ToCStringLen2(self.ptr, &len, val, cesu8) orelse
            return error.Exception;
        return ptr[0..len :0];
    }

    /// Read UTF-16 code units without a terminator. The caller releases the result with freeCStringUTF16. A conversion or allocation failure returns Exception.
    pub inline fn toCStringUTF16(self: Context, val: Value) error{Exception}![]const u16 {
        var len: usize = undefined;
        const ptr = c.JS_ToCStringLenUTF16(self.ptr, &len, val) orelse return error.Exception;
        return ptr[0..len];
    }

    pub inline fn freeCString(self: Context, ptr: [*:0]const u8) void {
        c.JS_FreeCString(self.ptr, ptr);
    }

    /// Release a UTF-16 result from this context. The pointer has no terminator. This does not fail.
    pub inline fn freeCStringUTF16(self: Context, ptr: [*]const u16) void {
        c.JS_FreeCStringUTF16(self.ptr, ptr);
    }

    pub inline fn toIndex(self: Context, val: Value) !u64 {
        var result: u64 = undefined;
        const ret = c.JS_ToIndex(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toInt64Ext(self: Context, val: Value) !i64 {
        var result: i64 = undefined;
        const ret = c.JS_ToInt64Ext(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toPropertyKey(self: Context, val: Value) Value {
        return c.JS_ToPropertyKey(self.ptr, val);
    }

    pub inline fn toObject(self: Context, val: Value) Value {
        return c.JS_ToObject(self.ptr, val);
    }

    pub inline fn toObjectString(self: Context, val: Value) Value {
        return c.JS_ToObjectString(self.ptr, val);
    }

    // Function, object, class, and prototype related methods
    pub inline fn isNumber(_: Context, self: Value) bool {
        return c.JS_IsNumber(self);
    }

    pub inline fn isNull(_: Context, self: Value) bool {
        return c.JS_IsNull(self);
    }

    pub inline fn isUndefined(_: Context, self: Value) bool {
        return c.JS_IsUndefined(self);
    }

    pub inline fn isUninitialized(_: Context, self: Value) bool {
        return c.JS_IsUninitialized(self);
    }

    pub inline fn isString(_: Context, self: Value) bool {
        return c.JS_IsString(self);
    }

    pub inline fn isSymbol(_: Context, self: Value) bool {
        return c.JS_IsSymbol(self);
    }

    pub inline fn isObject(_: Context, self: Value) bool {
        return c.JS_IsObject(self);
    }

    pub inline fn isBool(_: Context, self: Value) bool {
        return c.JS_IsBool(self);
    }

    pub inline fn isModule(_: Context, self: Value) bool {
        return c.JS_IsModule(self);
    }

    pub inline fn isArray(_: Context, self: Value) bool {
        return c.JS_IsArray(self);
    }

    pub inline fn isDate(_: Context, self: Value) bool {
        return c.JS_IsDate(self);
    }

    pub inline fn isException(_: Context, self: Value) bool {
        return c.JS_IsException(self);
    }

    pub inline fn isPromise(_: Context, self: Value) bool {
        return c.JS_IsPromise(self);
    }

    pub inline fn isProxy(_: Context, self: Value) bool {
        return c.JS_IsProxy(self);
    }

    pub inline fn isArrayBuffer(_: Context, self: Value) bool {
        return c.JS_IsArrayBuffer(self);
    }

    pub inline fn isFunction(self: Context, val: Value) bool {
        return c.JS_IsFunction(self.ptr, val);
    }

    pub inline fn isConstructor(self: Context, val: Value) bool {
        return c.JS_IsConstructor(self.ptr, val);
    }

    pub inline fn isError(_: Context, val: Value) bool {
        return c.JS_IsError(val);
    }

    pub inline fn isBigInt(_: Context, val: Value) bool {
        return c.JS_IsBigInt(val);
    }

    pub inline fn isAsyncFunction(_: Context, val: Value) bool {
        return c.JS_IsAsyncFunction(val);
    }

    pub inline fn isDataView(_: Context, val: Value) bool {
        return c.JS_IsDataView(val);
    }

    pub inline fn isSet(_: Context, val: Value) bool {
        return c.JS_IsSet(val);
    }

    pub inline fn isWeakRef(_: Context, val: Value) bool {
        return c.JS_IsWeakRef(val);
    }

    pub inline fn isWeakSet(_: Context, val: Value) bool {
        return c.JS_IsWeakSet(val);
    }

    pub inline fn isWeakMap(_: Context, val: Value) bool {
        return c.JS_IsWeakMap(val);
    }

    pub inline fn isRegExp(_: Context, val: Value) bool {
        return c.JS_IsRegExp(val);
    }

    pub inline fn isMap(_: Context, val: Value) bool {
        return c.JS_IsMap(val);
    }

    pub inline fn isNaN(_: Context, val: Value) bool {
        return c.JS_VALUE_IS_NAN(val);
    }

    pub inline fn getClassID(_: Context, val: Value) ClassID {
        return c.JS_GetClassID(val);
    }

    pub inline fn getPrototype(self: Context, val: Value) Value {
        return c.JS_GetPrototype(self.ptr, val);
    }

    pub inline fn setPrototype(self: Context, obj: Value, proto: Value) !void {
        const ret = c.JS_SetPrototype(self.ptr, obj, proto);
        if (ret < 0) return error.Exception;
    }

    pub inline fn getProxyTarget(self: Context, proxy: Value) Value {
        return c.JS_GetProxyTarget(self.ptr, proxy);
    }

    pub inline fn getProxyHandler(self: Context, proxy: Value) Value {
        return c.JS_GetProxyHandler(self.ptr, proxy);
    }

    pub inline fn newProxy(self: Context, target: Value, handler: Value) Value {
        return c.JS_NewProxy(self.ptr, target, handler);
    }

    // Error handling
    pub inline fn throwTypeError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowTypeError(self.ptr, fmt);
    }

    pub inline fn throwSyntaxError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowSyntaxError(self.ptr, fmt);
    }

    pub inline fn throwReferenceError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowReferenceError(self.ptr, fmt);
    }

    pub inline fn throwRangeError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowRangeError(self.ptr, fmt);
    }

    pub inline fn throwInternalError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowInternalError(self.ptr, fmt);
    }

    pub inline fn throwPlainError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_ThrowPlainError(self.ptr, fmt);
    }

    pub inline fn throwDOMException(self: Context, name: [*:0]const u8, fmt: [*:0]const u8) Value {
        return c.JS_ThrowDOMException(self.ptr, name, fmt);
    }

    pub inline fn throwOutOfMemory(self: Context) Value {
        return c.JS_ThrowOutOfMemory(self.ptr);
    }

    pub inline fn throw(self: Context, obj: Value) Value {
        return c.JS_Throw(self.ptr, obj);
    }

    pub inline fn getException(self: Context) Value {
        return c.JS_GetException(self.ptr);
    }

    pub inline fn hasException(self: Context) bool {
        return c.JS_HasException(self.ptr);
    }

    // Error construction (without throwing)
    pub inline fn newError(self: Context) Value {
        return c.JS_NewError(self.ptr);
    }

    pub inline fn newInternalError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewInternalError(self.ptr, fmt);
    }

    pub inline fn newPlainError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewPlainError(self.ptr, fmt);
    }

    pub inline fn newRangeError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewRangeError(self.ptr, fmt);
    }

    pub inline fn newReferenceError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewReferenceError(self.ptr, fmt);
    }

    pub inline fn newSyntaxError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewSyntaxError(self.ptr, fmt);
    }

    pub inline fn newTypeError(self: Context, fmt: [*:0]const u8) Value {
        return c.JS_NewTypeError(self.ptr, fmt);
    }

    // Uncatchable error API
    pub inline fn isUncatchableError(_: Context, val: Value) bool {
        return c.JS_IsUncatchableError(val);
    }

    pub inline fn setUncatchableError(self: Context, val: Value) void {
        c.JS_SetUncatchableError(self.ptr, val);
    }

    pub inline fn clearUncatchableError(self: Context, val: Value) void {
        c.JS_ClearUncatchableError(self.ptr, val);
    }

    pub inline fn resetUncatchableError(self: Context) void {
        c.JS_ResetUncatchableError(self.ptr);
    }

    // Value lifecycle management
    pub inline fn freeValue(self: Context, val: Value) void {
        c.JS_FreeValue(self.ptr, val);
    }

    // Property access
    pub inline fn getProperty(self: Context, obj: Value, prop: Atom) Value {
        return c.JS_GetProperty(self.ptr, obj, prop);
    }

    pub inline fn getPropertyStr(self: Context, obj: Value, prop: [*:0]const u8) Value {
        return c.JS_GetPropertyStr(self.ptr, obj, prop);
    }

    pub inline fn getPropertyUint32(self: Context, obj: Value, idx: u32) Value {
        return c.JS_GetPropertyUint32(self.ptr, obj, idx);
    }

    pub inline fn getPropertyInt64(self: Context, obj: Value, idx: i64) Value {
        return c.JS_GetPropertyInt64(self.ptr, obj, idx);
    }

    pub inline fn setProperty(self: Context, obj: Value, prop: Atom, val: Value) !void {
        const ret = c.JS_SetProperty(self.ptr, obj, prop, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyStr(self: Context, obj: Value, prop: [*:0]const u8, val: Value) !void {
        const ret = c.JS_SetPropertyStr(self.ptr, obj, prop, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyUint32(self: Context, obj: Value, idx: u32, val: Value) !void {
        const ret = c.JS_SetPropertyUint32(self.ptr, obj, idx, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyInt64(self: Context, obj: Value, idx: i64, val: Value) !void {
        const ret = c.JS_SetPropertyInt64(self.ptr, obj, idx, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn hasProperty(self: Context, obj: Value, prop: Atom) !bool {
        const ret = c.JS_HasProperty(self.ptr, obj, prop);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn deleteProperty(self: Context, obj: Value, prop: Atom, flags: c_int) !bool {
        const ret = c.JS_DeleteProperty(self.ptr, obj, prop, flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    // Execution and evaluation

    pub const EvalType = enum {
        global,
        module,
    };

    pub const EvalFlags = struct {
        type: EvalType = .global,
        strict: bool = false,
        compile_only: bool = false,
        backtrace_barrier: bool = false,
        async: bool = false,
    };

    /// QuickJS reads `input[input.len]`, so the input must end in a NUL byte.
    pub inline fn eval(self: Context, input: [:0]const u8, filename: [*:0]const u8, flags: EvalFlags) error{Exception}!Value {
        var c_flags: c_int = 0;

        // Set eval type flag
        switch (flags.type) {
            .global => c_flags |= c.JS_EVAL_TYPE_GLOBAL,
            .module => c_flags |= c.JS_EVAL_TYPE_MODULE,
        }

        // Set other flags
        if (flags.strict) c_flags |= c.JS_EVAL_FLAG_STRICT;
        if (flags.compile_only) c_flags |= c.JS_EVAL_FLAG_COMPILE_ONLY;
        if (flags.backtrace_barrier) c_flags |= c.JS_EVAL_FLAG_BACKTRACE_BARRIER;
        if (flags.async) c_flags |= c.JS_EVAL_FLAG_ASYNC;

        const result = c.JS_Eval(self.ptr, input.ptr, input.len, filename, c_flags);
        if (c.JS_IsException(result)) {
            return error.Exception;
        } else {
            return result;
        }
    }

    pub inline fn evalThis(self: Context, this_obj: Value, input: [:0]const u8, filename: [*:0]const u8, flags: EvalFlags) error{Exception}!Value {
        var c_flags: c_int = 0;
        switch (flags.type) {
            .global => c_flags |= c.JS_EVAL_TYPE_GLOBAL,
            .module => c_flags |= c.JS_EVAL_TYPE_MODULE,
        }
        if (flags.strict) c_flags |= c.JS_EVAL_FLAG_STRICT;
        if (flags.compile_only) c_flags |= c.JS_EVAL_FLAG_COMPILE_ONLY;
        if (flags.backtrace_barrier) c_flags |= c.JS_EVAL_FLAG_BACKTRACE_BARRIER;
        if (flags.async) c_flags |= c.JS_EVAL_FLAG_ASYNC;

        const result = c.JS_EvalThis(self.ptr, this_obj, input.ptr, input.len, filename, c_flags);
        if (c.JS_IsException(result)) return error.Exception;
        return result;
    }

    pub inline fn getGlobalObject(self: Context) Value {
        return c.JS_GetGlobalObject(self.ptr);
    }

    pub inline fn isInstanceOf(self: Context, val: Value, obj: Value) !bool {
        const ret = c.JS_IsInstanceOf(self.ptr, val, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn call(self: Context, func_obj: Value, this_obj: Value, args: []const Value) Value {
        return c.JS_Call(self.ptr, func_obj, this_obj, @intCast(args.len), @constCast(args.ptr));
    }

    pub inline fn invoke(self: Context, this_val: Value, atom: Atom, args: []const Value) Value {
        return c.JS_Invoke(self.ptr, this_val, atom, @intCast(args.len), @constCast(args.ptr));
    }

    pub inline fn callConstructor(self: Context, func_obj: Value, args: []const Value) Value {
        return c.JS_CallConstructor(self.ptr, func_obj, @intCast(args.len), args.ptr);
    }

    pub inline fn callConstructor2(self: Context, func_obj: Value, new_target: Value, args: []const Value) Value {
        return c.JS_CallConstructor2(self.ptr, func_obj, new_target, @intCast(args.len), @constCast(args.ptr));
    }

    // ArrayBuffer related methods
    pub inline fn getArrayBuffer(self: Context, val: Value) ![]u8 {
        var size: usize = undefined;
        const ptr = c.JS_GetArrayBuffer(self.ptr, &size, val);
        if (ptr == null) return error.NotArrayBuffer;
        return ptr[0..size];
    }

    /// Create an ArrayBuffer backed by `buf`. QuickJS takes ownership of the buffer.
    /// When the buffer is no longer needed, `handler.onFree(rt: RuntimeHandle, data: ?*anyopaque) void`
    /// is called, where `data` is the buffer pointer. The handler pointer must outlive the array buffer.
    pub fn newArrayBuffer(self: Context, buf: []u8, handler: anytype, is_shared: bool) Value {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(rt: ?*c.JSRuntime, opaque_ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                h.onFree(.{ .ptr = rt }, data);
            }
        };
        return c.JS_NewArrayBuffer(self.ptr, buf.ptr, buf.len, buf.len, @ptrCast(&trampoline.call), @ptrCast(handler), is_shared);
    }

    pub inline fn newArrayBufferCopy(self: Context, buf: []const u8) Value {
        return c.JS_NewArrayBufferCopy(self.ptr, buf.ptr, buf.len);
    }

    pub inline fn detachArrayBuffer(self: Context, obj: Value) void {
        c.JS_DetachArrayBuffer(self.ptr, obj);
    }

    pub inline fn isImmutableArrayBuffer(_: Context, obj: Value) bool {
        return c.JS_IsImmutableArrayBuffer(obj) != 0;
    }

    pub inline fn setImmutableArrayBuffer(_: Context, obj: Value, immutable: bool) c_int {
        return c.JS_SetImmutableArrayBuffer(obj, immutable);
    }

    pub inline fn getUint8Array(self: Context, obj: Value) ![]u8 {
        var size: usize = undefined;
        const ptr = c.JS_GetUint8Array(self.ptr, &size, obj);
        if (ptr == null) return error.TypeError;
        return ptr[0..size];
    }

    /// Create a Uint8Array backed by `buf`. QuickJS takes ownership of the buffer.
    /// When the buffer is no longer needed, `handler.onFree(rt: RuntimeHandle, data: ?*anyopaque) void`
    /// is called, where `data` is the buffer pointer. The handler pointer must outlive the array buffer.
    pub fn newUint8Array(self: Context, buf: []u8, handler: anytype, is_shared: bool) Value {
        const Handler = @TypeOf(handler);
        const trampoline = struct {
            fn call(rt: ?*c.JSRuntime, opaque_ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
                const h: Handler = @ptrCast(@alignCast(opaque_ptr));
                h.onFree(.{ .ptr = rt }, data);
            }
        };
        return c.JS_NewUint8Array(self.ptr, buf.ptr, buf.len, @ptrCast(&trampoline.call), @ptrCast(handler), is_shared);
    }

    pub inline fn newUint8ArrayCopy(self: Context, buf: []const u8) Value {
        return c.JS_NewUint8ArrayCopy(self.ptr, buf.ptr, buf.len);
    }

    pub inline fn getTypedArrayType(self: Context, obj: Value) !TypedArrayType {
        _ = self;
        const type_int = c.JS_GetTypedArrayType(obj);
        if (type_int < 0) return error.TypeError;
        return @enumFromInt(type_int);
    }

    pub inline fn getTypedArrayBuffer(self: Context, obj: Value) !ArrayBuffer {
        var byte_offset: usize = undefined;
        var byte_length: usize = undefined;
        var bytes_per_element: usize = undefined;

        const buffer_val = c.JS_GetTypedArrayBuffer(self.ptr, obj, &byte_offset, &byte_length, &bytes_per_element);
        if (c.JS_IsException(buffer_val)) return error.Exception;

        return .{
            .buffer = buffer_val,
            .byte_offset = byte_offset,
            .byte_length = byte_length,
            .bytes_per_element = bytes_per_element,
        };
    }

    // Promise related methods
    pub const PromiseState = enum(c_int) {
        Pending = c.JS_PROMISE_PENDING,
        Fulfilled = c.JS_PROMISE_FULFILLED,
        Rejected = c.JS_PROMISE_REJECTED,
    };

    pub inline fn promiseState(self: Context, promise: Value) PromiseState {
        return @enumFromInt(c.JS_PromiseState(self.ptr, promise));
    }

    pub inline fn promiseResult(self: Context, promise: Value) Value {
        return c.JS_PromiseResult(self.ptr, promise);
    }

    pub inline fn newPromiseCapability(self: Context, resolving_funcs: [*]Value) Value {
        return c.JS_NewPromiseCapability(self.ptr, @ptrCast(resolving_funcs));
    }

    pub inline fn newSettledPromise(self: Context, is_reject: bool, value: Value) Value {
        return c.JS_NewSettledPromise(self.ptr, is_reject, value);
    }

    // JSON methods
    /// QuickJS finds the end of the text at `buf[buf.len]`, so the text must end in a NUL byte.
    pub inline fn parseJSON(self: Context, buf: [:0]const u8, filename: [*:0]const u8) Value {
        return c.JS_ParseJSON(self.ptr, buf.ptr, buf.len, filename);
    }

    pub inline fn jsonStringify(self: Context, obj: Value, replacer: Value, space: Value) Value {
        return c.JS_JSONStringify(self.ptr, obj, replacer, space);
    }

    // Atom handling
    pub inline fn newAtom(self: Context, str: []const u8) Atom {
        return c.JS_NewAtomLen(self.ptr, str.ptr, str.len);
    }

    pub inline fn newAtomZ(self: Context, str: [*:0]const u8) Atom {
        return c.JS_NewAtom(self.ptr, str);
    }

    pub inline fn newAtomUint32(self: Context, n: u32) Atom {
        return c.JS_NewAtomUInt32(self.ptr, n);
    }

    pub inline fn dupAtom(self: Context, atom: Atom) Atom {
        return c.JS_DupAtom(self.ptr, atom);
    }

    pub inline fn freeAtom(self: Context, atom: Atom) void {
        c.JS_FreeAtom(self.ptr, atom);
    }

    pub inline fn atomToValue(self: Context, atom: Atom) Value {
        return c.JS_AtomToValue(self.ptr, atom);
    }

    pub inline fn atomToString(self: Context, atom: Atom) Value {
        return c.JS_AtomToString(self.ptr, atom);
    }

    pub inline fn atomToCString(self: Context, atom: Atom) ![*:0]const u8 {
        return c.JS_AtomToCString(self.ptr, atom) orelse return error.Exception;
    }

    pub inline fn atomToCStringLen(self: Context, atom: Atom) ![:0]const u8 {
        var len: usize = undefined;
        const ptr = c.JS_AtomToCStringLen(self.ptr, &len, atom);
        if (ptr == null) return error.Exception;
        return @as([*:0]const u8, @ptrCast(ptr))[0..len :0];
    }

    pub inline fn valueToAtom(self: Context, val: Value) Atom {
        return c.JS_ValueToAtom(self.ptr, val);
    }

    // Property descriptors and enumeration
    pub const PropertyEnumFlags = packed struct {
        strings: bool = true,
        symbols: bool = false,
        private: bool = false,
        enum_only: bool = false,
        set_enum: bool = false,
    };

    pub inline fn getOwnPropertyNames(self: Context, obj: Value, flags: PropertyEnumFlags) ![]PropertyEnum {
        var c_flags: c_int = 0;
        if (flags.strings) c_flags |= c.JS_GPN_STRING_MASK;
        if (flags.symbols) c_flags |= c.JS_GPN_SYMBOL_MASK;
        if (flags.private) c_flags |= c.JS_GPN_PRIVATE_MASK;
        if (flags.enum_only) c_flags |= c.JS_GPN_ENUM_ONLY;
        if (flags.set_enum) c_flags |= c.JS_GPN_SET_ENUM;

        var ptab: [*c]PropertyEnum = undefined;
        var len: u32 = 0;

        const ret = c.JS_GetOwnPropertyNames(self.ptr, @ptrCast(&ptab), &len, obj, c_flags);
        if (ret < 0) return error.Exception;

        return ptab[0..len];
    }

    pub inline fn freePropertyEnum(self: Context, tab: []PropertyEnum) void {
        c.JS_FreePropertyEnum(self.ptr, @ptrCast(tab.ptr), @intCast(tab.len));
    }

    // Property descriptor structure

    pub const PropertyFlags = packed struct {
        configurable: bool,
        writable: bool,
        enumerable: bool,
        normal: bool,
        getset: bool,

        pub fn fromInt(flags: c_int) PropertyFlags {
            return .{
                .configurable = ((flags | c.JS_PROP_CONFIGURABLE) != 0),
                .writable = ((flags | c.JS_PROP_WRITABLE) != 0),
                .enumerable = ((flags | c.JS_PROP_ENUMERABLE) != 0),
                .normal = ((flags | c.JS_PROP_NORMAL) != 0),
                .getset = ((flags | c.JS_PROP_GETSET) != 0),
            };
        }

        pub fn toInt(self: PropertyFlags) c_int {
            var flags: c_int = 0;
            if (self.configurable) flags |= c.JS_PROP_CONFIGURABLE;
            if (self.writable) flags |= c.JS_PROP_WRITABLE;
            if (self.enumerable) flags |= c.JS_PROP_ENUMERABLE;
            if (self.normal) flags |= c.JS_PROP_NORMAL;
            if (self.getset) flags |= c.JS_PROP_GETSET;
            return flags;
        }
    };

    pub const PropertyDescriptor = struct {
        flags: PropertyFlags,
        value: Value,
        getter: Value,
        setter: Value,
    };

    pub inline fn getOwnProperty(self: Context, obj: Value, prop: Atom) !PropertyDescriptor {
        var desc: c.JSPropertyDescriptor = undefined;
        const ret = c.JS_GetOwnProperty(self.ptr, &desc, obj, prop);
        if (ret < 0) return error.Exception;
        if (ret == 0) return error.PropertyNotFound;

        return PropertyDescriptor{
            .flags = PropertyFlags.fromInt(desc.flags),
            .value = desc.value,
            .getter = desc.getter,
            .setter = desc.setter,
        };
    }

    // Object extensibility and related operations
    pub inline fn isExtensible(self: Context, obj: Value) !bool {
        const ret = c.JS_IsExtensible(self.ptr, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn preventExtensions(self: Context, obj: Value) !bool {
        const ret = c.JS_PreventExtensions(self.ptr, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn getLength(self: Context, obj: Value) !i64 {
        var result: i64 = undefined;
        const ret = c.JS_GetLength(self.ptr, obj, &result);
        if (ret < 0) return error.Exception;
        return result;
    }

    pub inline fn setLength(self: Context, obj: Value, len: i64) !void {
        const ret = c.JS_SetLength(self.ptr, obj, len);
        if (ret < 0) return error.Exception;
    }

    pub inline fn sealObject(self: Context, obj: Value) !void {
        const ret = c.JS_SealObject(self.ptr, obj);
        if (ret < 0) return error.Exception;
    }

    pub inline fn freezeObject(self: Context, obj: Value) !void {
        const ret = c.JS_FreezeObject(self.ptr, obj);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setIsHTMLDDA(self: Context, obj: Value) void {
        c.JS_SetIsHTMLDDA(self.ptr, obj);
    }

    pub const DefinePropertyFlags = packed struct {
        configurable: bool = false,
        writable: bool = false,
        enumerable: bool = false,
        has_configurable: bool = false,
        has_writable: bool = false,
        has_enumerable: bool = false,
        has_get: bool = false,
        has_set: bool = false,
        has_value: bool = false,
        throw: bool = false,
        no_exotic: bool = false,

        pub fn toInt(self: DefinePropertyFlags) c_int {
            var flags: c_int = 0;
            if (self.configurable) flags |= c.JS_PROP_CONFIGURABLE;
            if (self.writable) flags |= c.JS_PROP_WRITABLE;
            if (self.enumerable) flags |= c.JS_PROP_ENUMERABLE;
            if (self.has_configurable) flags |= c.JS_PROP_HAS_CONFIGURABLE;
            if (self.has_writable) flags |= c.JS_PROP_HAS_WRITABLE;
            if (self.has_enumerable) flags |= c.JS_PROP_HAS_ENUMERABLE;
            if (self.has_get) flags |= c.JS_PROP_HAS_GET;
            if (self.has_set) flags |= c.JS_PROP_HAS_SET;
            if (self.has_value) flags |= c.JS_PROP_HAS_VALUE;
            if (self.throw) flags |= c.JS_PROP_THROW;
            return flags;
        }
    };

    pub inline fn defineProperty(self: Context, obj: Value, prop: Atom, val: Value, getter: Value, setter: Value, flags: DefinePropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = c.JS_DefineProperty(self.ptr, obj, prop, val, getter, setter, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValue(self: Context, obj: Value, prop: Atom, val: Value, flags: DefinePropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = c.JS_DefinePropertyValue(self.ptr, obj, prop, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValueStr(self: Context, obj: Value, prop: []const u8, val: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = c.JS_DefinePropertyValueStr(self.ptr, obj, prop.ptr, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValueUint32(self: Context, obj: Value, idx: u32, val: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = c.JS_DefinePropertyValueUint32(self.ptr, obj, idx, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyGetSet(self: Context, obj: Value, prop: Atom, getter: Value, setter: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = c.JS_DefinePropertyGetSet(self.ptr, obj, prop, getter, setter, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn setOpaque(_: Context, obj: Value, ptr: ?*anyopaque) c_int {
        return c.JS_SetOpaque(obj, ptr);
    }

    pub inline fn getOpaque(_: Context, obj: Value, class_id: ClassID) ?*anyopaque {
        return c.JS_GetOpaque(obj, class_id);
    }

    pub inline fn getOpaque2(self: Context, obj: Value, class_id: ClassID) ?*anyopaque {
        return c.JS_GetOpaque2(self.ptr, obj, class_id);
    }

    pub inline fn getAnyOpaque(_: Context, obj: Value, class_id: *ClassID) ?*anyopaque {
        return c.JS_GetAnyOpaque(obj, class_id);
    }

    // Class and prototype handling
    pub inline fn setClassProto(self: Context, class_id: ClassID, proto: Value) void {
        c.JS_SetClassProto(self.ptr, class_id, proto);
    }

    pub inline fn getClassProto(self: Context, class_id: ClassID) Value {
        return c.JS_GetClassProto(self.ptr, class_id);
    }

    pub inline fn getFunctionProto(self: Context) Value {
        return c.JS_GetFunctionProto(self.ptr);
    }

    // Intrinsic object loading
    pub inline fn addIntrinsicBaseObjects(self: Context) void {
        c.JS_AddIntrinsicBaseObjects(self.ptr);
    }

    pub inline fn addIntrinsicDate(self: Context) void {
        c.JS_AddIntrinsicDate(self.ptr);
    }

    pub inline fn addIntrinsicEval(self: Context) void {
        c.JS_AddIntrinsicEval(self.ptr);
    }

    pub inline fn addIntrinsicRegExpCompiler(self: Context) void {
        c.JS_AddIntrinsicRegExpCompiler(self.ptr);
    }

    pub inline fn addIntrinsicRegExp(self: Context) void {
        c.JS_AddIntrinsicRegExp(self.ptr);
    }

    pub inline fn addIntrinsicJSON(self: Context) void {
        c.JS_AddIntrinsicJSON(self.ptr);
    }

    pub inline fn addIntrinsicProxy(self: Context) void {
        c.JS_AddIntrinsicProxy(self.ptr);
    }

    pub inline fn addIntrinsicMapSet(self: Context) void {
        c.JS_AddIntrinsicMapSet(self.ptr);
    }

    pub inline fn addIntrinsicTypedArrays(self: Context) void {
        c.JS_AddIntrinsicTypedArrays(self.ptr);
    }

    pub inline fn addIntrinsicPromise(self: Context) void {
        c.JS_AddIntrinsicPromise(self.ptr);
    }

    pub inline fn addIntrinsicBigInt(self: Context) void {
        c.JS_AddIntrinsicBigInt(self.ptr);
    }

    pub inline fn addIntrinsicWeakRef(self: Context) void {
        c.JS_AddIntrinsicWeakRef(self.ptr);
    }

    pub inline fn addPerformance(self: Context) void {
        c.JS_AddPerformance(self.ptr);
    }

    pub inline fn addIntrinsicAToB(self: Context) void {
        c.JS_AddIntrinsicAToB(self.ptr);
    }

    pub inline fn addIntrinsicDOMException(self: Context) void {
        c.JS_AddIntrinsicDOMException(self.ptr);
    }

    // Function integration

    /// Create a JS function backed by a Zig callback.
    /// The callback must have signature `fn(Context, Value, []const Value) Value`
    /// where the params are (context, this_val, args).
    pub fn newFunction(self: Context, name: [*:0]const u8, length: c_int, comptime callback: fn (Context, Value, []const Value) Value) Value {
        const Thunk = struct {
            fn call(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
                const ctx_wrapper = Context{ .ptr = ctx };
                const args: []const Value = @as([*]const Value, @ptrCast(argv))[0..@as(usize, @intCast(argc))];
                return callback(ctx_wrapper, this_val, args);
            }
        };
        return c.JS_NewCFunction(self.ptr, @ptrCast(&Thunk.call), name, length);
    }

    /// Like `newFunction` but the callback also receives a `magic` int.
    /// The callback must have signature `fn(Context, Value, []const Value, c_int) Value`.
    pub fn newFunctionMagic(self: Context, name: [*:0]const u8, length: c_int, magic: c_int, comptime callback: fn (Context, Value, []const Value, c_int) Value) Value {
        const Thunk = struct {
            fn call(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue, m: c_int) callconv(.c) c.JSValue {
                const ctx_wrapper = Context{ .ptr = ctx };
                const args: []const Value = @as([*]const Value, @ptrCast(argv))[0..@as(usize, @intCast(argc))];
                return callback(ctx_wrapper, this_val, args, m);
            }
        };
        return c.JS_NewCFunctionMagic(self.ptr, @ptrCast(&Thunk.call), name, length, c.JS_CFUNC_generic_magic, magic);
    }

    pub inline fn setConstructor(self: Context, func_obj: Value, proto: Value) void {
        c.JS_SetConstructor(self.ptr, func_obj, proto);
    }

    pub inline fn setConstructorBit(self: Context, func_obj: Value, val: bool) bool {
        return c.JS_SetConstructorBit(self.ptr, func_obj, val) != 0;
    }

    // Module type
    pub const Module = struct {
        ptr: *c.JSModuleDef,
    };

    // Module support
    pub inline fn getModuleNamespace(self: Context, m: Module) Value {
        return c.JS_GetModuleNamespace(self.ptr, m.ptr);
    }

    pub inline fn getModuleName(self: Context, m: Module) Atom {
        return c.JS_GetModuleName(self.ptr, m.ptr);
    }

    pub inline fn getImportMeta(self: Context, m: Module) Value {
        return c.JS_GetImportMeta(self.ptr, m.ptr);
    }

    pub inline fn resolveModule(self: Context, obj: Value) !void {
        const ret = c.JS_ResolveModule(self.ptr, obj);
        if (ret < 0) return error.ModuleResolutionFailed;
    }

    pub inline fn evalFunction(self: Context, fun_obj: Value) Value {
        return c.JS_EvalFunction(self.ptr, fun_obj);
    }

    /// Compile source to a bytecode blob. The caller owns the returned bytes.
    pub fn compileToBytecode(self: Context, allocator: std.mem.Allocator, input: [:0]const u8, filename: [*:0]const u8, eval_type: EvalType) ![]u8 {
        const obj = try self.eval(input, filename, .{ .type = eval_type, .compile_only = true });
        defer self.freeValue(obj);

        const bytes = try self.writeObject(obj, .{ .bytecode = true });
        defer self.free(bytes.ptr);

        return allocator.dupe(u8, bytes);
    }

    /// Read a trusted, version-locked bytecode blob produced by `compileToBytecode`.
    pub inline fn readBytecode(self: Context, bytes: []const u8) error{Exception}!Value {
        const obj = c.JS_ReadObject(self.ptr, bytes.ptr, bytes.len, c.JS_READ_OBJ_BYTECODE);
        if (self.isException(obj)) return error.Exception;
        return obj;
    }

    /// Instantiate and evaluate bytecode. This consumes `obj`.
    pub fn evalBytecode(self: Context, obj: Value, eval_type: EvalType) error{ Exception, ModuleResolutionFailed }!Value {
        if (eval_type == .module) {
            self.resolveModule(obj) catch |err| {
                self.freeValue(obj);
                return err;
            };
        }

        const result = self.evalFunction(obj);
        if (self.isException(result)) return error.Exception;
        return result;
    }

    pub inline fn getScriptOrModuleName(self: Context, n_stack_levels: i32) Atom {
        return c.JS_GetScriptOrModuleName(self.ptr, n_stack_levels);
    }

    pub inline fn loadModule(self: Context, basename: ?[]const u8, filename: []const u8) Value {
        const basename_ptr = if (basename) |b| b.ptr else null;
        return c.JS_LoadModule(self.ptr, basename_ptr, filename.ptr);
    }

    // Module creation

    /// Create a native module. The init function is called when the module is instantiated.
    /// The callback must have signature `fn(Context, Module) c_int` and should add exports
    /// and return 0 on success.
    pub fn newModule(self: Context, name: []const u8, comptime init_fn: fn (Context, Module) c_int) ?Module {
        const Thunk = struct {
            fn call(ctx: ?*c.JSContext, m: ?*c.JSModuleDef) callconv(.c) c_int {
                return init_fn(Context{ .ptr = ctx }, Module{ .ptr = m.? });
            }
        };
        const ptr = c.JS_NewCModule(self.ptr, name.ptr, @ptrCast(&Thunk.call));
        return if (ptr != null) Module{ .ptr = ptr.? } else null;
    }

    pub inline fn addModuleExport(self: Context, m: Module, name: []const u8) !void {
        const ret = c.JS_AddModuleExport(self.ptr, m.ptr, name.ptr);
        if (ret < 0) return error.ModuleExportFailed;
    }

    pub inline fn setModuleExport(self: Context, m: Module, name: []const u8, val: Value) !void {
        const ret = c.JS_SetModuleExport(self.ptr, m.ptr, name.ptr, val);
        if (ret < 0) return error.ModuleExportFailed;
    }

    pub fn moduleFromValue(self: Context, val: Value) ?Module {
        const is_mod = self.isModule(val);
        const ptr = c.JS_VALUE_GET_PTR(val);
        self.freeValue(val);
        if (!is_mod or ptr == null) return null;
        return Module{ .ptr = @ptrCast(@alignCast(ptr)) };
    }

    pub inline fn getModulePrivateValue(self: Context, m: Module) Value {
        return c.JS_GetModulePrivateValue(self.ptr, m.ptr);
    }

    pub inline fn setModulePrivateValue(self: Context, m: Module, val: Value) !void {
        const ret = c.JS_SetModulePrivateValue(self.ptr, m.ptr, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn detectModule(input: []const u8) bool {
        return c.JS_DetectModule(input.ptr, input.len);
    }

    // Job queue management

    /// Enqueue a job to be run on the microtask queue.
    /// The callback must have signature `fn(Context, []const Value) Value`.
    pub fn enqueueJob(self: Context, comptime callback: fn (Context, []const Value) Value, args: []const Value) !void {
        const Thunk = struct {
            fn call(ctx: ?*c.JSContext, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
                const ctx_wrapper = Context{ .ptr = ctx };
                const job_args: []const Value = @as([*]const Value, @ptrCast(argv))[0..@as(usize, @intCast(argc))];
                return callback(ctx_wrapper, job_args);
            }
        };
        const ret = c.JS_EnqueueJob(self.ptr, @ptrCast(&Thunk.call), @intCast(args.len), @constCast(args.ptr));
        if (ret < 0) return error.EnqueueJobFailed;
    }

    // Object serialization
    pub const WriteObjectFlags = packed struct {
        bytecode: bool = false,
        sab: bool = false,
        reference: bool = false,
        strip_source: bool = false,
        strip_debug: bool = false,
    };

    pub inline fn writeObject(self: Context, obj: Value, flags: WriteObjectFlags) ![]u8 {
        var c_flags: c_int = 0;
        if (flags.bytecode) c_flags |= c.JS_WRITE_OBJ_BYTECODE;
        if (flags.sab) c_flags |= c.JS_WRITE_OBJ_SAB;
        if (flags.reference) c_flags |= c.JS_WRITE_OBJ_REFERENCE;
        if (flags.strip_source) c_flags |= c.JS_WRITE_OBJ_STRIP_SOURCE;
        if (flags.strip_debug) c_flags |= c.JS_WRITE_OBJ_STRIP_DEBUG;

        var size: usize = undefined;
        const ptr = c.JS_WriteObject(self.ptr, &size, obj, c_flags);
        if (ptr == null) return error.SerializationFailed;
        return ptr[0..size];
    }

    pub const ReadObjectFlags = packed struct {
        bytecode: bool = false,
        sab: bool = false,
        reference: bool = false,
    };

    pub inline fn readObject(self: Context, buf: []const u8, flags: ReadObjectFlags) Value {
        var c_flags: c_int = 0;
        if (flags.bytecode) c_flags |= c.JS_READ_OBJ_BYTECODE;
        if (flags.sab) c_flags |= c.JS_READ_OBJ_SAB;
        if (flags.reference) c_flags |= c.JS_READ_OBJ_REFERENCE;

        return c.JS_ReadObject(self.ptr, buf.ptr, buf.len, c_flags);
    }

    // Memory allocation functions
    pub inline fn malloc(self: Context, size: usize) ?*anyopaque {
        return c.js_malloc(self.ptr, size);
    }

    pub inline fn calloc(self: Context, count: usize, size: usize) ?*anyopaque {
        return c.js_calloc(self.ptr, count, size);
    }

    pub inline fn free(self: Context, ptr: ?*anyopaque) void {
        c.js_free(self.ptr, ptr);
    }

    pub inline fn realloc(self: Context, ptr: ?*anyopaque, size: usize) ?*anyopaque {
        return c.js_realloc(self.ptr, ptr, size);
    }

    pub inline fn mallocz(self: Context, size: usize) ?*anyopaque {
        return c.js_mallocz(self.ptr, size);
    }

    pub inline fn strdup(self: Context, str: []const u8) ?[*:0]u8 {
        return c.js_strdup(self.ptr, str.ptr);
    }

    pub inline fn strndup(self: Context, str: []const u8, n: usize) ?[*:0]u8 {
        return c.js_strndup(self.ptr, str.ptr, n);
    }

    pub inline fn mallocUsableSize(self: Context, ptr: ?*const anyopaque) usize {
        return c.js_malloc_usable_size(self.ptr, ptr);
    }
};

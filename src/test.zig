const std = @import("std");

const quickjs = @import("quickjs");

test "Initialize a context" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    try std.testing.expectEqual(r.ptr, c.getRuntime());
}

test "Create objects and manipulate properties" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a new object
    const obj = c.newObject();
    defer c.freeValue(obj);

    { // Set and get a string property
        const value = c.newString("test value");
        try c.setPropertyStr(obj, "stringProp", value);

        const retrieved_value = c.getPropertyStr(obj, "stringProp");
        defer c.freeValue(retrieved_value);
        try std.testing.expect(c.isSameValue(value, retrieved_value));

        const value_as_str = try c.toCStringLen(retrieved_value);
        defer c.freeCString(value_as_str);
        try std.testing.expectEqualSentinel(u8, 0, "test value", value_as_str);
    }

    { // Set and get a number property
        const value = c.newInt32(42);
        try c.setPropertyStr(obj, "numProp", value);

        const retrieved_value = c.getPropertyStr(obj, "numProp");
        defer c.freeValue(retrieved_value);
        try std.testing.expect(c.isNumber(retrieved_value));

        const value_as_int = try c.toInt32(retrieved_value);
        try std.testing.expectEqual(@as(i32, 42), value_as_int);
    }

    { // Set and get a boolean property
        const value = quickjs.TRUE;
        try c.setPropertyStr(obj, "boolProp", value);

        const retrieved_value = c.getPropertyStr(obj, "boolProp");
        defer c.freeValue(retrieved_value);
        try std.testing.expect(c.isBool(retrieved_value));

        const value_as_bool = try c.toBool(retrieved_value);
        try std.testing.expectEqual(@as(bool, true), value_as_bool);
    }
}

test "Array creation and manipulation" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an array
    const arr = c.newArray();
    defer c.freeValue(arr);

    try std.testing.expect(c.isArray(arr));

    // Add elements to the array
    for (0..5) |i| {
        const val = c.newInt32(@intCast(i * 10));
        try c.setPropertyUint32(arr, @intCast(i), val);
    }

    // Read back array elements
    for (0..5) |i| {
        const val = c.getPropertyUint32(arr, @intCast(i));
        defer c.freeValue(val);

        const numVal = try c.toInt32(val);
        try std.testing.expectEqual(@as(i32, @intCast(i * 10)), numVal);
    }
}

test "Object property existence and deletion" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an object
    const obj = c.newObject();
    defer c.freeValue(obj);

    // Set a property
    const val = c.newString("test");
    try c.setPropertyStr(obj, "testProp", val);

    // Check property existence using atom API
    const propAtom = c.newAtom("testProp");
    defer c.freeAtom(propAtom);

    const exists = try c.hasProperty(obj, propAtom);
    try std.testing.expect(exists);

    // Delete the property
    _ = try c.deleteProperty(obj, propAtom, 0);

    // Verify it no longer exists
    const afterDelete = try c.hasProperty(obj, propAtom);
    try std.testing.expect(!afterDelete);
}

test "Value type checking" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const strVal = c.newString("test string");
    defer c.freeValue(strVal);
    try std.testing.expect(c.isString(strVal));
    try std.testing.expect(!c.isNumber(strVal));

    const numVal = c.newInt32(42);
    defer c.freeValue(numVal);
    try std.testing.expect(c.isNumber(numVal));
    try std.testing.expect(!c.isString(numVal));

    const objVal = c.newObject();
    defer c.freeValue(objVal);
    try std.testing.expect(c.isObject(objVal));
    try std.testing.expect(!c.isArray(objVal));

    const arrVal = c.newArray();
    defer c.freeValue(arrVal);
    try std.testing.expect(c.isArray(arrVal));
    try std.testing.expect(c.isObject(arrVal)); // Arrays are also objects
}

test "JavaScript evaluation" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Basic expression evaluation
    const result1 = try c.eval("40 + 2", "test.js", .{});
    defer c.freeValue(result1);
    try std.testing.expect(c.isNumber(result1));
    try std.testing.expectEqual(@as(i32, 42), try c.toInt32(result1));

    // Object creation in JS
    const result2 = try c.eval("({a: 1, b: 'test'})", "test.js", .{});
    defer c.freeValue(result2);
    try std.testing.expect(c.isObject(result2));

    // Check object property
    const propValue = c.getPropertyStr(result2, "b");
    defer c.freeValue(propValue);
    try std.testing.expect(c.isString(propValue));

    // Array creation in JS
    const result3 = try c.eval("[1, 2, 3, 4, 5]", "test.js", .{});
    defer c.freeValue(result3);
    try std.testing.expect(c.isArray(result3));

    // Access array element
    const element = c.getPropertyUint32(result3, 2);
    defer c.freeValue(element);
    try std.testing.expect(c.isNumber(element));
    try std.testing.expectEqual(@as(i32, 3), try c.toInt32(element));
}

test "JavaScript function creation and calling" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Define a function in JavaScript
    const jsFn = try c.eval("function add(a, b) { return a + b; }; add", "test.js", .{});
    defer c.freeValue(jsFn);

    try std.testing.expect(c.isFunction(jsFn));

    // Call the function
    var args: [2]quickjs.Value = undefined;
    args[0] = c.newInt32(40);
    args[1] = c.newInt32(2);

    const this_val = quickjs.NULL; // No this value needed
    const result = c.call(jsFn, this_val, &args);
    defer c.freeValue(result);

    try std.testing.expect(c.isNumber(result));
    try std.testing.expectEqual(@as(i32, 42), try c.toInt32(result));

    // Check undefined for missing arguments
    const global = c.getGlobalObject();
    defer c.freeValue(global);

    _ = try c.eval("function testArgs(a, b) { return [a, b]; }", "test.js", .{});
    const testFn = c.getPropertyStr(global, "testArgs");
    defer c.freeValue(testFn);

    var single_arg: [1]quickjs.Value = undefined;
    single_arg[0] = c.newInt32(123);

    const result2 = c.call(testFn, this_val, &single_arg);
    defer c.freeValue(result2);

    try std.testing.expect(c.isArray(result2));

    const first = c.getPropertyUint32(result2, 0);
    defer c.freeValue(first);
    try std.testing.expectEqual(@as(i32, 123), try c.toInt32(first));

    const second = c.getPropertyUint32(result2, 1);
    defer c.freeValue(second);
    try std.testing.expect(c.isUndefined(second));
}

test "Value conversion roundtrip tests" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Test integer conversion roundtrip
    const int32_val = c.newInt32(42);
    defer c.freeValue(int32_val);
    const int32_result = try c.toInt32(int32_val);
    try std.testing.expectEqual(@as(i32, 42), int32_result);

    // Test uint32 conversion roundtrip
    const uint32_val = c.newUint32(4294967295); // max uint32
    defer c.freeValue(uint32_val);
    const uint32_result = try c.toUint32(uint32_val);
    try std.testing.expectEqual(@as(u32, 4294967295), uint32_result);

    // Test int64 conversion roundtrip
    const max_safe_int = (1 << 53) - 1;
    const int64_val = c.newInt64(max_safe_int); // max int64
    defer c.freeValue(int64_val);
    const int64_result = try c.toInt64(int64_val);
    try std.testing.expectEqual(@as(i64, max_safe_int), int64_result);

    // Test float64 conversion roundtrip
    const float64_val = c.newFloat64(3.14159265359);
    defer c.freeValue(float64_val);
    const float64_result = try c.toFloat64(float64_val);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159265359), float64_result, 0.0000000001);

    // Test string conversion roundtrip using toCString
    const test_str = "Hello, QuickJS!";
    const str_val = c.newString(test_str);
    defer c.freeValue(str_val);

    const c_str = try c.toCString(str_val);
    defer c.freeCString(c_str);

    const slice = std.mem.span(c_str);
    try std.testing.expectEqualStrings(test_str, slice);

    // Test boolean conversion roundtrip
    const bool_val = c.newBool(true);
    defer c.freeValue(bool_val);
    const bool_result = try c.toBool(bool_val);
    try std.testing.expectEqual(true, bool_result);
}

test "Atom API" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create atom from string
    const atom = c.newAtom("testProperty");
    defer c.freeAtom(atom);

    // Convert atom to value
    const atom_value = c.atomToValue(atom);
    defer c.freeValue(atom_value);
    try std.testing.expect(c.isString(atom_value));

    // Convert atom to string
    const atom_string = c.atomToString(atom);
    defer c.freeValue(atom_string);
    try std.testing.expect(c.isString(atom_string));

    // Test atom C string conversion
    const atom_cstr = try c.atomToCString(atom);
    defer c.freeCString(atom_cstr);
    const atom_slice = std.mem.span(atom_cstr);
    try std.testing.expectEqualStrings("testProperty", atom_slice);

    // Create atom from uint32
    const num_atom = c.newAtomUint32(42);
    defer c.freeAtom(num_atom);

    // Test atom duplication
    const dup_atom = c.dupAtom(atom);
    defer c.freeAtom(dup_atom);

    // Test valueToAtom
    const str_val = c.newString("testProperty");
    defer c.freeValue(str_val);
    const val_atom = c.valueToAtom(str_val);
    defer c.freeAtom(val_atom);
}

test "Error handling" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Generate a syntax error
    try std.testing.expectError(error.Exception, c.eval("function(){", "test.js", .{}));
    try std.testing.expect(c.hasException());

    // Get the exception
    const exception = c.getException();
    defer c.freeValue(exception);
    try std.testing.expect(c.isError(exception));

    // Create custom errors
    const type_error = c.throwTypeError("Test type error");
    defer c.freeValue(type_error);

    const range_error = c.throwRangeError("Test range error");
    defer c.freeValue(range_error);

    const ref_error = c.throwReferenceError("Test reference error");
    defer c.freeValue(ref_error);

    // Test try/catch in JS
    const try_catch_result = try c.eval(
        \\(function() {
        \\  try {
        \\    throw new Error('Test error');
        \\  } catch (e) {
        \\    return e.message;
        \\  }
        \\})()
    , "test.js", .{});
    defer c.freeValue(try_catch_result);

    try std.testing.expect(c.isString(try_catch_result));
    const c_str = try c.toCString(try_catch_result);
    defer c.freeCString(c_str);
    const str_slice = std.mem.span(c_str);
    try std.testing.expectEqualStrings("Test error", str_slice);
}

test "ArrayBuffer and TypedArray support" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a buffer of bytes
    var test_data = [_]u8{ 1, 2, 3, 4, 5 };

    // Create an ArrayBuffer
    const array_buffer = c.newArrayBufferCopy(&test_data);
    defer c.freeValue(array_buffer);

    try std.testing.expect(c.isArrayBuffer(array_buffer));

    // Get buffer content
    const buffer_content = try c.getArrayBuffer(array_buffer);
    try std.testing.expectEqual(@as(usize, 5), buffer_content.len);
    try std.testing.expectEqual(@as(u8, 1), buffer_content[0]);
    try std.testing.expectEqual(@as(u8, 5), buffer_content[4]);

    // Create a Uint8Array
    const uint8_array = c.newUint8ArrayCopy(&test_data);
    defer c.freeValue(uint8_array);

    // Get Uint8Array content
    const array_content = try c.getUint8Array(uint8_array);
    try std.testing.expectEqual(@as(usize, 5), array_content.len);
    try std.testing.expectEqual(@as(u8, 1), array_content[0]);
    try std.testing.expectEqual(@as(u8, 5), array_content[4]);

    // Test creating from JS
    const js_array = try c.eval("new Uint8Array([10, 20, 30, 40, 50])", "test.js", .{});
    defer c.freeValue(js_array);

    const js_array_content = try c.getUint8Array(js_array);
    try std.testing.expectEqual(@as(usize, 5), js_array_content.len);
    try std.testing.expectEqual(@as(u8, 10), js_array_content[0]);
    try std.testing.expectEqual(@as(u8, 50), js_array_content[4]);
}

test "JSON functions" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Test JSON.parse via parseJSON
    const json_str = "{\"name\":\"test\",\"value\":42,\"nested\":{\"arr\":[1,2,3]}}";
    const parsed = c.parseJSON(json_str, "test.json");
    defer c.freeValue(parsed);

    try std.testing.expect(c.isObject(parsed));

    const name_prop = c.getPropertyStr(parsed, "name");
    defer c.freeValue(name_prop);
    try std.testing.expect(c.isString(name_prop));

    // Test JSON.stringify via jsonStringify
    const obj = try c.eval("({a: 1, b: \"test\", c: [1,2,3]})", "test.js", .{});
    defer c.freeValue(obj);

    const null_val = quickjs.NULL;
    const undefined_val = quickjs.UNDEFINED;

    const stringified = c.jsonStringify(obj, null_val, undefined_val);
    defer c.freeValue(stringified);

    try std.testing.expect(c.isString(stringified));

    const c_str = try c.toCString(stringified);
    defer c.freeCString(c_str);

    const str_slice = std.mem.span(c_str);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":\"test\",\"c\":[1,2,3]}", str_slice);
}

test "Object prototype operations" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create objects
    const obj = c.newObject();
    defer c.freeValue(obj);

    const proto = c.newObject();
    defer c.freeValue(proto);

    // Set property on prototype
    const test_val = c.newString("from prototype");
    try c.setPropertyStr(proto, "testProp", test_val);

    // Set prototype
    try c.setPrototype(obj, proto);

    // Get prototype
    const retrieved_proto = c.getPrototype(obj);
    defer c.freeValue(retrieved_proto);

    // Verify prototype property is accessible from object
    const inherited_prop = c.getPropertyStr(obj, "testProp");
    defer c.freeValue(inherited_prop);

    try std.testing.expect(c.isString(inherited_prop));

    // Test Object.defineProperty style API
    const new_prop = c.newString("direct property");
    const atom = c.newAtom("newProp");
    defer c.freeAtom(atom);

    _ = try c.definePropertyValue(obj, atom, new_prop, .{
        // .configurable = true,
        // .writable = true,
        // .enumerable = true,
        // .has_configurable = true,
        // .has_writable = true,
        // .has_enumerable = true,
        // .has_value = true,
    });

    const defined_prop = c.getPropertyStr(obj, "newProp");
    defer c.freeValue(defined_prop);

    try std.testing.expect(c.isString(defined_prop));
}

test "getOwnPropertyNames and property enumeration" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an object with various properties
    const obj = try c.eval(
        \\({
        \\  numProp: 42,
        \\  strProp: "test",
        \\  objProp: { nested: true },
        \\})
    , "test.js", .{});
    defer c.freeValue(obj);

    // Get own property names (only strings, not symbols)
    const props = try c.getOwnPropertyNames(obj, .{
        .strings = true,
        .symbols = false,
    });
    defer c.freePropertyEnum(props);

    // There should be 3 string properties
    try std.testing.expectEqual(@as(usize, 3), props.len);

    // Check individual properties by converting atoms to strings
    var found_num_prop = false;
    var found_str_prop = false;
    var found_obj_prop = false;

    for (props) |prop| {
        const prop_str = c.atomToString(prop.atom);
        defer c.freeValue(prop_str);

        const c_str = try c.toCString(prop_str);
        defer c.freeCString(c_str);

        const str = std.mem.span(c_str);

        if (std.mem.eql(u8, str, "numProp")) {
            found_num_prop = true;
        } else if (std.mem.eql(u8, str, "strProp")) {
            found_str_prop = true;
        } else if (std.mem.eql(u8, str, "objProp")) {
            found_obj_prop = true;
        }
    }

    try std.testing.expect(found_num_prop);
    try std.testing.expect(found_str_prop);
    try std.testing.expect(found_obj_prop);

    // Test property descriptor by getting one property's descriptor
    const name_atom = c.newAtom("strProp");
    defer c.freeAtom(name_atom);

    const desc = try c.getOwnProperty(obj, name_atom);
    defer c.freeValue(desc.value);
    defer c.freeValue(desc.getter);
    defer c.freeValue(desc.setter);

    // The property should have a string value
    try std.testing.expect(c.isString(desc.value));

    // The property should be enumerable by default
    try std.testing.expect(desc.flags.enumerable);
}

test "Object operations: getLength, setLength, sealObject, freezeObject" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Test getLength on an array
    const arr = try c.eval("[1, 2, 3, 4, 5]", "test.js", .{});
    defer c.freeValue(arr);
    try std.testing.expectEqual(@as(i64, 5), try c.getLength(arr));

    // Test setLength
    try c.setLength(arr, 3);
    try std.testing.expectEqual(@as(i64, 3), try c.getLength(arr));

    // Test sealObject - sealed objects can't have properties deleted or added
    const obj = c.newObject();
    defer c.freeValue(obj);
    const val = c.newInt32(42);
    try c.setPropertyStr(obj, "x", val);
    try c.sealObject(obj);
    // After sealing, the object should still be extensible check work
    const extensible_before = try c.isExtensible(obj);
    try std.testing.expect(!extensible_before);

    // Test freezeObject
    const obj2 = c.newObject();
    defer c.freeValue(obj2);
    const val2 = c.newString("hello");
    try c.setPropertyStr(obj2, "y", val2);
    try c.freezeObject(obj2);
    // Frozen objects are not extensible
    try std.testing.expect(!(try c.isExtensible(obj2)));
}

test "New type predicates" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Set/WeakSet
    const set_val = try c.eval("new Set([1, 2, 3])", "test.js", .{});
    defer c.freeValue(set_val);
    try std.testing.expect(c.isSet(set_val));
    try std.testing.expect(!c.isMap(set_val));

    const weakset_val = try c.eval("new WeakSet()", "test.js", .{});
    defer c.freeValue(weakset_val);
    try std.testing.expect(c.isWeakSet(weakset_val));

    // Map/WeakMap
    const map_val = try c.eval("new Map()", "test.js", .{});
    defer c.freeValue(map_val);
    try std.testing.expect(c.isMap(map_val));
    try std.testing.expect(!c.isSet(map_val));

    const weakmap_val = try c.eval("new WeakMap()", "test.js", .{});
    defer c.freeValue(weakmap_val);
    try std.testing.expect(c.isWeakMap(weakmap_val));

    // WeakRef
    const weakref_val = try c.eval("new WeakRef({})", "test.js", .{});
    defer c.freeValue(weakref_val);
    try std.testing.expect(c.isWeakRef(weakref_val));

    // DataView
    const dv_val = try c.eval("new DataView(new ArrayBuffer(8))", "test.js", .{});
    defer c.freeValue(dv_val);
    try std.testing.expect(c.isDataView(dv_val));

    // AsyncFunction
    const async_fn = try c.eval("(async function() {})", "test.js", .{});
    defer c.freeValue(async_fn);
    try std.testing.expect(c.isAsyncFunction(async_fn));

    // isNaN
    const nan_val = try c.eval("NaN", "test.js", .{});
    defer c.freeValue(nan_val);
    try std.testing.expect(c.isNaN(nan_val));
    const num_val = c.newInt32(42);
    defer c.freeValue(num_val);
    try std.testing.expect(!c.isNaN(num_val));
}

test "Error construction without throwing" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Construct errors without throwing them
    const type_err = c.newTypeError("test message");
    defer c.freeValue(type_err);
    try std.testing.expect(c.isError(type_err));

    const range_err = c.newRangeError("range message");
    defer c.freeValue(range_err);
    try std.testing.expect(c.isError(range_err));

    const ref_err = c.newReferenceError("ref message");
    defer c.freeValue(ref_err);
    try std.testing.expect(c.isError(ref_err));

    const syntax_err = c.newSyntaxError("syntax message");
    defer c.freeValue(syntax_err);
    try std.testing.expect(c.isError(syntax_err));

    const internal_err = c.newInternalError("internal message");
    defer c.freeValue(internal_err);
    try std.testing.expect(c.isError(internal_err));

    const plain_err = c.newPlainError("plain message");
    defer c.freeValue(plain_err);
    try std.testing.expect(c.isError(plain_err));

    // Verify the error message via JS
    const err = c.newError();
    defer c.freeValue(err);
    try std.testing.expect(c.isError(err));
}

test "Promise APIs" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a resolved promise from JS
    const resolved = try c.eval("Promise.resolve(42)", "test.js", .{});
    defer c.freeValue(resolved);
    try std.testing.expect(c.isPromise(resolved));
    try std.testing.expectEqual(quickjs.Context.PromiseState.Fulfilled, c.promiseState(resolved));

    const result = c.promiseResult(resolved);
    defer c.freeValue(result);
    try std.testing.expectEqual(@as(i32, 42), try c.toInt32(result));

    // Create a rejected promise from JS
    const rejected = try c.eval("Promise.reject('error')", "test.js", .{});
    defer c.freeValue(rejected);
    try std.testing.expect(c.isPromise(rejected));
    try std.testing.expectEqual(quickjs.Context.PromiseState.Rejected, c.promiseState(rejected));

    // newSettledPromise - create a fulfilled promise
    const settled_val = c.newInt32(123);
    defer c.freeValue(settled_val);
    const settled = c.newSettledPromise(false, settled_val);
    defer c.freeValue(settled);
    try std.testing.expect(c.isPromise(settled));
    try std.testing.expectEqual(quickjs.Context.PromiseState.Fulfilled, c.promiseState(settled));

    // newPromiseCapability - requires a 2-element array for resolving functions
    var resolving_funcs: [2]quickjs.Value = undefined;
    const capability = c.newPromiseCapability(&resolving_funcs);
    defer c.freeValue(capability);
    defer c.freeValue(resolving_funcs[0]);
    defer c.freeValue(resolving_funcs[1]);
    try std.testing.expect(c.isPromise(capability));
}

test "Proxy support" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a proxy via JS
    const proxy = try c.eval(
        \\new Proxy({a: 1}, {
        \\  get(target, prop) { return target[prop]; }
        \\})
    , "test.js", .{});
    defer c.freeValue(proxy);
    try std.testing.expect(c.isProxy(proxy));

    // Get proxy target
    const target = c.getProxyTarget(proxy);
    defer c.freeValue(target);
    try std.testing.expect(c.isObject(target));

    // Get proxy handler
    const handler = c.getProxyHandler(proxy);
    defer c.freeValue(handler);
    try std.testing.expect(c.isObject(handler));

    // Create a proxy via the Zig API
    const target_obj = c.newObject();
    defer c.freeValue(target_obj);
    const handler_obj = c.newObject();
    defer c.freeValue(handler_obj);
    const proxy2 = c.newProxy(target_obj, handler_obj);
    defer c.freeValue(proxy2);
    try std.testing.expect(c.isProxy(proxy2));
}

test "New value creation: newNumber, newUint64, newStringZ" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // newNumber
    const num = c.newNumber(3.14);
    defer c.freeValue(num);
    try std.testing.expect(c.isNumber(num));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), try c.toFloat64(num), 0.001);

    // newUint64
    const big_val = c.newUint64(5000000000); // > u32 max
    defer c.freeValue(big_val);
    const result = try c.toInt64(big_val);
    try std.testing.expectEqual(@as(i64, 5000000000), result);

    // newStringZ (null-terminated string)
    const str = c.newStringZ("hello world");
    defer c.freeValue(str);
    try std.testing.expect(c.isString(str));
    const c_str = try c.toCString(str);
    defer c.freeCString(c_str);
    try std.testing.expectEqualStrings("hello world", std.mem.span(c_str));
}

test "newArrayFrom" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an array from values
    var values: [3]quickjs.Value = undefined;
    values[0] = c.newInt32(10);
    values[1] = c.newInt32(20);
    values[2] = c.newInt32(30);

    const arr = c.newArrayFrom(&values);
    defer c.freeValue(arr);

    try std.testing.expect(c.isArray(arr));
    try std.testing.expectEqual(@as(i64, 3), try c.getLength(arr));

    // Verify elements
    const e0 = c.getPropertyUint32(arr, 0);
    defer c.freeValue(e0);
    try std.testing.expectEqual(@as(i32, 10), try c.toInt32(e0));

    const e2 = c.getPropertyUint32(arr, 2);
    defer c.freeValue(e2);
    try std.testing.expectEqual(@as(i32, 30), try c.toInt32(e2));
}

test "Context lifecycle: getRuntime, dupContext, opaque" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // getRuntime should return the same runtime pointer
    const rt = c.getRuntime();
    try std.testing.expect(rt != null);
    try std.testing.expectEqual(r.ptr, rt);

    // Context opaque
    var opaque_val: u32 = 12345;
    c.setContextOpaque(@ptrCast(&opaque_val));
    const retrieved = c.getContextOpaque();
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 12345), @as(*u32, @ptrCast(@alignCast(retrieved.?))).*);
}

test "Runtime opaque and getVersion" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    // Runtime opaque
    var opaque_val: u64 = 999;
    r.setRuntimeOpaque(@ptrCast(&opaque_val));
    const retrieved = r.getRuntimeOpaque();
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 999), @as(*u64, @ptrCast(@alignCast(retrieved.?))).*);

    // getVersion should return a non-empty string
    const version = quickjs.getVersion();
    try std.testing.expect(version[0] != 0);
}

test "evalThis" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // evalThis evaluates code with a specific `this` binding
    const this_obj = c.newObject();
    defer c.freeValue(this_obj);
    const prop = c.newString("custom this");
    try c.setPropertyStr(this_obj, "name", prop);

    const result = try c.evalThis(this_obj, "this.name", "test.js", .{});
    defer c.freeValue(result);
    try std.testing.expect(c.isString(result));
    const c_str = try c.toCString(result);
    defer c.freeCString(c_str);
    try std.testing.expectEqualStrings("custom this", std.mem.span(c_str));
}

test "invoke method on object" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an object with a method
    const obj = try c.eval("({greet: function(name) { return 'hello ' + name; }})", "test.js", .{});
    defer c.freeValue(obj);

    // Invoke the method via atom
    const method_atom = c.newAtom("greet");
    defer c.freeAtom(method_atom);

    var args: [1]quickjs.Value = undefined;
    args[0] = c.newString("world");
    defer c.freeValue(args[0]);

    const result = c.invoke(obj, method_atom, &args);
    defer c.freeValue(result);
    try std.testing.expect(c.isString(result));
    const c_str = try c.toCString(result);
    defer c.freeCString(c_str);
    try std.testing.expectEqualStrings("hello world", std.mem.span(c_str));
}

test "newObjectProto" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a prototype object with a property
    const proto = c.newObject();
    defer c.freeValue(proto);
    const method = c.newString("inherited");
    try c.setPropertyStr(proto, "inheritedProp", method);

    // Create a new object with that prototype
    const obj = c.newObjectProto(proto);
    defer c.freeValue(obj);

    // The inherited property should be accessible
    const val = c.getPropertyStr(obj, "inheritedProp");
    defer c.freeValue(val);
    try std.testing.expect(c.isString(val));
    const c_str = try c.toCString(val);
    defer c.freeCString(c_str);
    try std.testing.expectEqualStrings("inherited", std.mem.span(c_str));
}

test "toIndex and toInt64Ext" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // toIndex
    const idx_val = c.newInt32(100);
    defer c.freeValue(idx_val);
    try std.testing.expectEqual(@as(u64, 100), try c.toIndex(idx_val));

    // toInt64Ext
    const int_val = c.newInt64(-42);
    defer c.freeValue(int_val);
    try std.testing.expectEqual(@as(i64, -42), try c.toInt64Ext(int_val));
}

test "Detect module" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // import statements are detected as modules (they fail with "could not load module")
    try std.testing.expect(quickjs.Context.detectModule("import x from 'y';"));
    // return at top level is valid in scripts but not modules
    try std.testing.expect(!quickjs.Context.detectModule("return 42;"));
    // syntax errors are not modules
    try std.testing.expect(!quickjs.Context.detectModule("function(){"));
}

test "Runtime atom and CString RT variants" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create an atom on context, then dup/free on runtime
    const atom = c.newAtom("test");
    defer c.freeAtom(atom);

    const dup = r.dupAtom(atom);
    r.freeAtom(dup);

    // Create a CString and free via runtime
    const str_val = c.newString("hello");
    defer c.freeValue(str_val);
    const c_str = try c.toCString(str_val);
    r.freeCString(c_str);
}

test "Immutable ArrayBuffer" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Create a normal ArrayBuffer
    var data = [_]u8{ 1, 2, 3, 4 };
    const buf = c.newArrayBufferCopy(&data);
    defer c.freeValue(buf);

    // Should not be immutable initially
    try std.testing.expect(!c.isImmutableArrayBuffer(buf));

    // Make it immutable
    _ = c.setImmutableArrayBuffer(buf, true);
    try std.testing.expect(c.isImmutableArrayBuffer(buf));
}

test "Serialization roundtrip" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Serialize an object
    const obj = try c.eval("({x: 42, y: 'hello'})", "test.js", .{});
    defer c.freeValue(obj);

    const serialized = try c.writeObject(obj, .{ .bytecode = true });
    defer c.free(serialized.ptr);

    // Deserialize
    const deserialized = c.readObject(serialized, .{ .bytecode = true });
    defer c.freeValue(deserialized);
    try std.testing.expect(c.isObject(deserialized));

    // Verify properties survived the roundtrip
    const x_val = c.getPropertyStr(deserialized, "x");
    defer c.freeValue(x_val);
    try std.testing.expectEqual(@as(i32, 42), try c.toInt32(x_val));

    const y_val = c.getPropertyStr(deserialized, "y");
    defer c.freeValue(y_val);
    try std.testing.expect(c.isString(y_val));
}

test "getClassID" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // Plain objects should have a class ID (the value is implementation-defined)
    const obj = c.newObject();
    defer c.freeValue(obj);
    const class_id = c.getClassID(obj);
    _ = class_id; // just verify it doesn't crash
}

test "newFunction" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const jsAdd = struct {
        fn call(ctx: quickjs.Context, this_val: quickjs.Value, args: []const quickjs.Value) quickjs.Value {
            _ = this_val;
            if (args.len < 2) return quickjs.NULL;
            const a = ctx.toInt32(args[0]) catch return quickjs.NULL;
            const b = ctx.toInt32(args[1]) catch return quickjs.NULL;
            return ctx.newInt32(a + b);
        }
    };

    const func = c.newFunction("add", 2, jsAdd.call);

    const global = c.getGlobalObject();
    defer c.freeValue(global);
    // setPropertyStr takes ownership of func
    try c.setPropertyStr(global, "add", func);

    const result = try c.eval("add(3, 4)", "test.js", .{});
    defer c.freeValue(result);
    try std.testing.expectEqual(@as(i32, 7), try c.toInt32(result));
}

test "newFunctionMagic" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const jsMul = struct {
        fn call(ctx: quickjs.Context, this_val: quickjs.Value, args: []const quickjs.Value, magic: c_int) quickjs.Value {
            _ = this_val;
            if (args.len < 2) return quickjs.NULL;
            const a = ctx.toInt32(args[0]) catch return quickjs.NULL;
            const b = ctx.toInt32(args[1]) catch return quickjs.NULL;
            return ctx.newInt32(a * b + magic);
        }
    };

    const func = c.newFunctionMagic("mul", 2, 100, jsMul.call);

    const global = c.getGlobalObject();
    defer c.freeValue(global);
    // setPropertyStr takes ownership of func
    try c.setPropertyStr(global, "mul", func);

    const result = try c.eval("mul(3, 4)", "test.js", .{});
    defer c.freeValue(result);
    try std.testing.expectEqual(@as(i32, 112), try c.toInt32(result));
}

test "setInterruptHandler" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const Handler = struct {
        triggered: bool = false,

        pub fn onInterrupt(self: *@This()) bool {
            self.triggered = true;
            return true;
        }
    };

    var handler = Handler{};
    r.setInterruptHandler(&handler);

    const c = quickjs.Context.init(r);
    defer c.deinit();

    // An infinite loop should trigger the interrupt handler
    _ = c.eval("while(1){}", "test.js", .{}) catch {};
    try std.testing.expect(handler.triggered);
}

test "newArrayBuffer with handler" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const BufferHandler = struct {
        allocator: std.mem.Allocator,
        len: usize,
        freed: bool = false,

        pub fn onFree(self: *@This(), rt: quickjs.RuntimeHandle, data: ?*anyopaque) void {
            _ = rt;
            if (data) |d| {
                const buf: [*]u8 = @ptrCast(d);
                self.allocator.free(buf[0..self.len]);
            }
            self.freed = true;
        }
    };

    var handler = BufferHandler{ .allocator = allocator, .len = 4 };
    const buf = try allocator.alloc(u8, 4);
    buf[0] = 1;
    buf[1] = 2;
    buf[2] = 3;
    buf[3] = 4;

    const ab = c.newArrayBuffer(buf, &handler, false);
    defer c.freeValue(ab);

    // The buffer should be accessible from JS
    const len = c.getPropertyStr(ab, "byteLength");
    defer c.freeValue(len);
    try std.testing.expectEqual(@as(f64, 4), try c.toFloat64(len));

    // Force GC to trigger the free handler
    c.detachArrayBuffer(ab);
    r.runGC();
    try std.testing.expect(handler.freed);
}

test "newClass" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    var finalized = false;
    _ = &finalized; // capture for comptime thunk

    const MyClassDef = struct {
        var finalized_flag: *bool = undefined;

        pub fn finalizer(rt: quickjs.RuntimeHandle, val: quickjs.Value) void {
            _ = rt;
            _ = val;
            finalized_flag.* = true;
        }
    };
    MyClassDef.finalized_flag = &finalized;

    const class_id = r.newClassID();
    try r.newClass(class_id, .{
        .name = "MyClass",
        .finalizer = MyClassDef.finalizer,
    });

    const obj = c.newObjectClass(class_id);
    try std.testing.expect(!finalized);
    c.freeValue(obj);
    r.runGC();
    try std.testing.expect(finalized);
}

test "newModule" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const module_init = struct {
        fn init_fn(ctx: quickjs.Context, m: quickjs.Context.Module) c_int {
            ctx.addModuleExport(m, "answer") catch return -1;
            ctx.setModuleExport(m, "answer", ctx.newInt32(42)) catch return -1;
            return 0;
        }
    };

    const m = c.newModule("test_module", module_init.init_fn);
    try std.testing.expect(m != null);
    if (m) |mod| {
        c.addModuleExport(mod, "answer") catch {};
    }
}

const ArmedFailingAllocator = struct {
    backing: std.mem.Allocator,
    armed: bool = false,

    fn allocator(self: *ArmedFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "allocator returns null on OOM instead of a panic" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var failing = ArmedFailingAllocator{ .backing = gpa.allocator() };

    const r = try quickjs.Runtime.init(failing.allocator());
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    failing.armed = true;
    const result = c.eval("new Array(100000).fill(0)", "oom.js", .{});
    failing.armed = false;

    try std.testing.expectError(error.Exception, result);
}

test "module loader resolves an import via moduleFromValue" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const r = try quickjs.Runtime.init(allocator);
    defer r.deinit();

    const c = quickjs.Context.init(r);
    defer c.deinit();

    const Loader = struct {
        pub fn onLoadModule(_: *@This(), ctx: quickjs.Context, name: []const u8, attributes: quickjs.Value) ?quickjs.Context.Module {
            _ = attributes;
            if (!std.mem.eql(u8, name, "mathlib")) return null;
            const val = ctx.eval(
                "export const add = (a, b) => a + b;",
                "mathlib",
                .{ .type = .module, .compile_only = true },
            ) catch return null;
            return ctx.moduleFromValue(val);
        }
    };

    var loader = Loader{};
    r.setModuleLoader2(&loader);

    const entry = c.eval(
        "import { add } from \"mathlib\"; globalThis.result = add(2, 3);",
        "entry",
        .{ .type = .module },
    ) catch |err| {
        std.debug.print("entry eval failed: {}\n", .{err});
        return err;
    };
    c.freeValue(entry);

    const rv = try c.eval("globalThis.result", "read", .{});
    defer c.freeValue(rv);
    try std.testing.expectEqual(@as(i32, 5), try c.toInt32(rv));
}

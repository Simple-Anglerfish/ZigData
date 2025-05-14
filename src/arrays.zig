const std = @import("std");
const Allocator = std.mem.Allocator;
const io = std.io;
// A generic 2D array backed by a single contiguous allocation.
//
// Stores elements of type `T` in a grid of `width` x `height`.
// Internally, it uses two allocations:
// 1. A flat buffer (`data`) holding all `width * height` elements contiguously.
// 2. A buffer of slices (`items`) where each slice points to a row within the `data` buffer.
// This provides both efficient flat access (`flatData`/`flatDataMut`) and
// convenient 2D access (`items[y][x]`).
pub fn Array2D(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        width: usize,
        height: usize,
        items: [][]T, // The 2D slice view (slice of row slices)
        data: []T, // The underlying contiguous data buffer

        // Define specific errors for this type
        pub const Error = error{
            OutOfMemory,
            SizeOverflow, // When width * height exceeds usize limit
            OutOfBounds, // copy window to large
            IOError,
            InvalidFileFormat,
            EndOfStream,
        };

        const FILE_MAGIC = "A2D";
        const FILE_VERSION: u8 = 1;

        // Internal helper to allocate memory.
        // Returns the row slice array and the flat data buffer.
        fn _allocInternal(allocator: Allocator, width: usize, height: usize) !struct { items: [][]T, data: []T } {

            // 1. Allocate the flat data buffer
            const data_len = std.math.mul(usize, width, height) catch return Error.SizeOverflow;
            const data_buf = allocator.alloc(T, data_len) catch return Error.OutOfMemory;
            errdefer allocator.free(data_buf);

            // 2. Allocate the slice for row pointers
            const row_slices = allocator.alloc([]T, height) catch return Error.OutOfMemory;
            errdefer allocator.free(row_slices);

            // 3. Point each row slice into the data buffer
            var current_idx: usize = 0;
            for (0..height) |y| {
                row_slices[y] = data_buf[current_idx .. current_idx + width];
                current_idx += width;
            }

            // 4. Return the internal structure
            return .{ .items = row_slices, .data = data_buf };
        }

        // Internal helper to deallocate memory. Made into a method for convenience.
        fn _deallocInternal(self: *Self) void {
            // 1. Free the data buffer first (contains the actual elements)
            self.allocator.free(self.data);

            // 2. Free the slice of row slices
            self.allocator.free(self.items);
        }

        // Initializes a new Array2D with the given dimensions with undefined as the default value
        // Allocates memory using the provided allocator.
        // Returns an error if allocation fails.
        pub fn init(
            allocator: Allocator,
            width: usize,
            height: usize,
        ) !Self {
            const result = try Self._allocInternal(allocator, width, height);
            return Self{
                .allocator = allocator,
                .width = width,
                .height = height,
                .items = result.items,
                .data = result.data,
            };
        }

        // Deinitializes the Array2D, freeing its memory.
        // The Array2D becomes unusable after this call.
        pub fn deinit(self: *Self) void {
            self._deallocInternal();
            // Prevent use-after-free bugs in debug/safe modes by making the struct's state invalid.
            self.* = undefined;
        }

        // -------- Data Access --------

        // If the array is constant the return values will be const
        // Returns a mutable pointer to the element at (x, y).
        // Asserts that the coordinates are in bounds in debug/safe modes.
        // will crash if cordinates are out of range
        // use get() for bounds checking
        pub fn at(self: anytype, x: usize, y: usize) @TypeOf(&self.items[y][x]) {
            std.debug.assert(x < self.width);
            std.debug.assert(y < self.height);

            return &self.items[y][x];
        }

        // Returns an optional mutable pointer to the element at (x, y).
        // Returns `null` if the coordinates are out of bounds.
        pub fn get(self: anytype, x: usize, y: usize) ?@TypeOf(&self.items[y][x]) {
            if (x >= self.width or y >= self.height) {
                return null;
            }
            // Safety: Bounds check performed above.
            return &self.items[y][x];
        }

        // Returns the underlying flat data slice (const).
        // Useful for operations that process the data linearly.
        pub fn flatData(self: anytype) @TypeOf(self.data) {
            return self.data;
        }

        // -------- Index Helpers --------

        // get the x and y cordinates from the flat index of a item
        // returns null if width of height = 0
        pub fn dataAddressFromFlat(self: *const Self, i: usize) ?struct { x: usize, y: usize } {
            if (self.width == 0 or self.height == 0) {
                return null;
            }
            const data_len = self.height * self.width;
            if (i >= data_len) return null;

            const x: usize = @rem(i, self.width);
            const y: usize = @divFloor(i, self.width);
            return .{ .x = x, .y = y };
        }

        // get the flat index from and x and y
        pub fn flatFromDataAddress(self: *const Self, x: usize, y: usize) ?usize {
            if (self.height < y or self.width < x) {
                return null;
            }
            return (y * self.width) + x;
        }

        //-------- Array level functions --------

        // Fills the entire array with the given value.
        pub fn fill(self: *Self, value: T) void {
            for (self.data) |*item| {
                item.* = value;
            }
        }

        // Check for equality between Arrays
        pub fn eql(self: *const Self, other: *const Self) bool {
            // 1. First, check if dimensions match. This is a quick exit.
            if (self.width != other.width or self.height != other.height) {
                return false;
            }
            // 2. If dimensions match, the lengths of their flat data buffers must also match.
            return std.mem.eql(T, self.flatData(), other.flatData());
        }

        // Create a copy of the array
        pub fn clone(self: *const Self, allocator: Allocator) !Self {
            var newArray = try Array2D(T).init(allocator, self.width, self.height);
            errdefer newArray.deinit();

            @memcpy(newArray.data, self.data);
            return newArray;
        }

        pub fn extractRegion(self: *const Self, allocator: Allocator, startX: usize, startY: usize, new_width: usize, new_height: usize) !Self {

            // 1. ensure region is fully within the array
            if (startX + new_width > self.width or startY + new_height > self.height) {
                return error.OutOfBounds;
            }
            // 2. Create the new array
            var newArray = try Self.init(allocator, new_width, new_height);
            errdefer newArray.deinit();
            // 3. Move the selected data over
            for (0..new_height) |rel_Y| {
                const src_y = startY + rel_Y;
                const dest_row = newArray.items[rel_Y];
                const src_rowPart = self.items[src_y][startX .. startX + new_width];
                @memcpy(dest_row, src_rowPart);
            }
            return newArray;
        }

        // Copies a portion of src array into dest array at the specified position
        pub fn copyInto(self: *Self, src: *const Self, dest_x: usize, dest_y: usize) !void {
            // Ensure the source fits within destination at the specified position
            if (dest_x + src.width > self.width or dest_y + src.height > self.height) {
                return Error.OutOfBounds;
            }

            // Copy row by row
            for (0..src.height) |y| {
                const dest_row = dest_y + y;
                @memcpy(self.items[dest_row][dest_x..][0..src.width], src.items[y]);
            }
        }

        //---------- Mapping Functions ------------
        // TODO test to see if const pointers break this
        
        // passes cordinates to function use transform if x and y not needed
        pub fn map(self: anytype, func: fn (*T, usize, usize) void) void {
            var y: usize = 0;
            while (y < self.height) : (y += 1) {
                var x: usize = 0;
                while (x < self.width) : (x += 1) {
                    func(&self.items[y][x], x, y);
                }
            }
        }
        // takes a context a pointer
        // passes cordinates to function use _ = x and _ = y if not needed
        pub fn mapWithContext(self: anytype, context: ?*anyopaque, func: fn (?*anyopaque, *T, usize, usize) void) void {
            var y: usize = 0;
            while (y < self.height) : (y += 1) {
                var x: usize = 0;
                while (x < self.width) : (x += 1) {
                    func(context, &self.items[y][x], x, y);
                }
            }
        }

        // Applies a transformation to each element in-place
        pub fn transform(self: *Self, comptime func: fn (T) T) void {
            for (self.data) |*item| {
                item.* = func(item.*);
            }
        }

        // Same as transform but returns new array
        pub fn TransformToNew(self: *const Self, allocator: Allocator, comptime func: fn (T) T) !Self {
            var result = try Self.init(allocator, self.width, self.height);
            errdefer result.deinit();

            for (0..self.data.len) |i| {
                result.data[i] = func(self.data[i]);
            }

            return result;
        }

        // Find first occurrence of a value
        pub fn findFirst(self: *const Self, value: T) ?struct { x: usize, y: usize } {
            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    if (std.meta.eql(self.items[y][x], value)) {
                        return .{ .x = x, .y = y };
                    }
                }
            }
            return null;
        }

        //---------- Array Manipulation ------------
        // will crop to top left if new array is smaller
        pub fn resize(self: *Self, new_width: usize, new_height: usize) !void {
            const result = try Self._allocInternal(self.allocator, new_width, new_height);
            errdefer {
                self.allocator.free(result.data);
                self.allocator.free(result.items);
            }

            const minWidth = @min(self.width, new_width);
            const minHeight = @min(self.height, new_height);

            for (0..minHeight) |y| {
                @memcpy(result.items[y][0..minWidth], self.items[y][0..minWidth]);
            }

            self._deallocInternal();

            self = result;
        }
        // flips rows and columns
        pub fn transpose(self: *Self) !Self {
            var result = try Self.init(self.allocator, self.height, self.width);
            errdefer result.deinit();

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    result.items[x][y] = self.items[y][x];
                }
            }

            return result;
        }
        // Rotates the array 90 degrees clockwise
        pub fn rotateClockwise(self: *Self) !Self {
            var result = try Self.init(self.allocator, self.height, self.width);
            errdefer result.deinit();

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    result.items[x][self.height - 1 - y] = self.items[y][x];
                }
            }

            return result;
        }
        // Flips the array horizontally (mirror along vertical axis)
        pub fn flipHorizontal(self: *Self) !Self {
            var result = try Self.init(self.allocator, self.width, self.height);
            errdefer result.deinit();

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    result.items[y][self.width - 1 - x] = self.items[y][x];
                }
            }

            return result;
        }
        // Flips the array vertically (mirror along horizontal axis)
        pub fn flipVertical(self: *Self) !Self {
            var result = try Self.init(self.allocator, self.width, self.height);
            errdefer result.deinit();

            for (0..self.height) |y| {
                @memcpy(result.items[self.height - 1 - y], self.items[y]);
            }

            return result;
        }

        //--------- Iterators ---------

        fn _iterGen(comptime is_const: bool) type {
            const ptr_type = if (is_const) *const T else *T;
            const SelfPtr = if (is_const) *const Self else *Self;
            return struct {
                const Iter_impl = @This();
                array: SelfPtr,
                idx: usize,
                pub fn next(it: *Iter_impl) ?ptr_type {
                    if (it.index >= it.array.data.len) return null;
                    const prt = &it.array.data[it.idx];
                    it.idx += 1;
                    return prt;
                }
            };
        }

        fn _getIterType(comptime PtrSelf: type) type {
            const is_const = @typeInfo(PtrSelf).pointer.is_const;
            return if (is_const) ConstIterator else Iterator;
        }

        pub const Iterator = _iterGen(false);
        pub const ConstIterator = _iterGen(true);

        pub fn iterator(self: anytype) _getIterType(@TypeOf(self)) {
            return .{ .array = self, .index = 0 };
        }

        // ----------- Serilization / Deserialization ------------------------
        // :TODO add tests
            
        // Format: File magic 4 bytes, File_Version 1 byte | usize (u8 little endian) | Width (usize little endian) | Height (usize little endian) | data (T) 
        pub fn save(self: *const Self, writer: anytype) !void {
            // 1. Write File magic number
            try writer.writeAll(FILE_MAGIC);

            // 2. Write Version
            try writer.writeByte(FILE_VERSION);
            
            // 3. Write system spec
            const spec: u8 = @sizeOf(usize);
            try writer.writeInt(u8, spec, std.builtin.Endian.little);

            // 4. Write Width and Height
            try writer.writeInt(usize, self.width, std.builtin.Endian.little);
            try writer.writeInt(usize, self.height, std.builtin.Endian.little);

            // 5. Write Data
            if (self.data.len > 0) {
                const data_bytes = std.mem.sliceAsBytes(self.data);
                try writer.writeAll(data_bytes);
            }
        }

        pub fn load(allocator: Allocator, reader: anytype) !Self {
            // 1. Read and verify file magic
            var magic_buf: [FILE_MAGIC.len]u8 = undefined;
            try reader.readNoEof(&magic_buf);
            if (!std.mem.eql(u8, &magic_buf, FILE_MAGIC)) {
                return Error.InvalidFileFormat;
            }

            // 2. Read and verify version
            const version = try reader.readByte();
            if (version != FILE_VERSION) {
                return Error.InvalidFileFormat;
            }

            // 3. Check system spec compatibility
            const file_size_bytes = try reader.readByte();
            if (file_size_bytes != @sizeOf(usize)) {
                return Error.InvalidFileFormat;
            }

            // 4. Read dimensions
            const width = try reader.readInt(usize, std.builtin.Endian.little);
            const height = try reader.readInt(usize, std.builtin.Endian.little);

            // 5. Create and populate the array
            var array = try Self.init(allocator, width, height);
            errdefer array.deinit();

            // 6. Read data
            if (array.data.len > 0) {
                const data_bytes = std.mem.sliceAsBytes(array.data);
                try reader.readNoEof(data_bytes);
            }

            return array;
        }
    };
}

//--- Tests ---

test "Array2D basic usage" {
    const allocator = std.testing.allocator;
    var array = try Array2D(i32).init(allocator, 3, 2); // 3 wide, 2 high
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.width);
    try std.testing.expectEqual(@as(usize, 2), array.height);
    try std.testing.expectEqual(@as(usize, 6), array.flatData().len);

    // Fill with values
    var count: i32 = 0;
    for (0..array.height) |y| {
        for (0..array.width) |x| {
            array.at(x, y).* = count;
            count += 1;
        }
    }

    // Check values using different accessors
    try std.testing.expectEqual(@as(i32, 0), array.at(0, 0).*);
    try std.testing.expectEqual(@as(i32, 4), array.get(1, 1).?.*);

    // Check out-of-bounds
    try std.testing.expectEqual(null, array.get(3, 0));

    // Check flat data
    const expected_flat = [_]i32{ 0, 1, 2, 3, 4, 5 };
    try std.testing.expectEqualSlices(i32, &expected_flat, array.flatData());

    // Use fill method
    array.fill(99);
    try std.testing.expectEqual(@as(i32, 99), array.at(1, 1).*);
    const expected_filled = [_]i32{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqualSlices(i32, &expected_filled, array.flatData());
}
test "Array2D zero width" {
    const allocator = std.testing.allocator;
    var array = try Array2D(u8).init(allocator, 0, 5);
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.width);
    try std.testing.expectEqual(@as(usize, 5), array.height);
    try std.testing.expectEqual(@as(usize, 0), array.flatData().len);
    try std.testing.expectEqual(@as(usize, 5), array.items.len);
    try std.testing.expectEqual(@as(usize, 0), array.items[0].len); // Row slices are zero-length

    try std.testing.expectEqual(null, array.get(0, 0)); // x=0 is out of bounds if width=0
}
test "Array2D zero height" {
    const allocator = std.testing.allocator;
    var array = try Array2D(f32).init(allocator, 5, 0);
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 5), array.width);
    try std.testing.expectEqual(@as(usize, 0), array.height);
    try std.testing.expectEqual(@as(usize, 0), array.flatData().len);
    try std.testing.expectEqual(@as(usize, 0), array.items.len); // No row slices

    try std.testing.expectEqual(null, array.get(0, 0)); // y=0 is out of bounds if height=0
}
test "Array2D zero width and height" {
    const allocator = std.testing.allocator;
    var array = try Array2D(bool).init(allocator, 0, 0);
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.width);
    try std.testing.expectEqual(@as(usize, 0), array.height);
    try std.testing.expectEqual(@as(usize, 0), array.flatData().len);
    try std.testing.expectEqual(@as(usize, 0), array.items.len);

    try std.testing.expectEqual(null, array.get(0, 0));
}
test "Array2D eql" {
    const allocator = std.testing.allocator;
    const I32Array = Array2D(i32);

    var arr1 = try I32Array.init(allocator, 3, 2);
    defer arr1.deinit();
    arr1.fill(10);
    arr1.at(1, 1).* = 20; // { 10, 10, 10, 10, 20, 10 }

    var arr2 = try I32Array.init(allocator, 3, 2);
    defer arr2.deinit();
    arr2.fill(10);
    arr2.at(1, 1).* = 20; // { 10, 10, 10, 10, 20, 10 }

    var arr3 = try I32Array.init(allocator, 3, 2);
    defer arr3.deinit();
    arr3.fill(10);
    arr3.at(0, 0).* = 5; // { 5, 10, 10, 10, 10, 10 }

    var arr4_diff_width = try I32Array.init(allocator, 2, 2);
    defer arr4_diff_width.deinit();
    arr4_diff_width.fill(10);

    var arr5_diff_height = try I32Array.init(allocator, 3, 1);
    defer arr5_diff_height.deinit();
    arr5_diff_height.fill(10);

    var arr_empty1 = try I32Array.init(allocator, 0, 5);
    defer arr_empty1.deinit();
    var arr_empty2 = try I32Array.init(allocator, 0, 5);
    defer arr_empty2.deinit();
    var arr_empty3 = try I32Array.init(allocator, 5, 0);
    defer arr_empty3.deinit();

    // Test equality
    try std.testing.expect(arr1.eql(&arr1)); // Equal to self
    try std.testing.expect(arr1.eql(&arr2)); // Equal content
    try std.testing.expect(arr2.eql(&arr1)); // Equal content (commutative)

    // Test inequality (different content)
    try std.testing.expect(!arr1.eql(&arr3));
    try std.testing.expect(!arr3.eql(&arr1));

    // Test inequality (different dimensions)
    try std.testing.expect(!arr1.eql(&arr4_diff_width));
    try std.testing.expect(!arr1.eql(&arr5_diff_height));

    // Test empty arrays
    try std.testing.expect(arr_empty1.eql(&arr_empty2)); // Same empty shape
    try std.testing.expect(!arr_empty1.eql(&arr_empty3)); // Different empty shape
}

test "Array2D Manipulation" {
    const allocator = std.testing.allocator;
    const I32Array = Array2D(i32);

    var arr1 = try I32Array.init(allocator, 3, 2);
    defer arr1.deinit();
    arr1.fill(10);
    arr1.at(1, 1).* = 20; // { 10, 10, 10, 10, 20, 10 }

    var arr2 = try arr1.rotateClockwise();
    defer arr2.deinit();

    try std.testing.expect(arr2.width == 2);
    try std.testing.expect(arr2.height == 3);

    var arr3 = try arr1.flipVertical();
    defer arr3.deinit();
    try std.testing.expect(arr3.width == 3);
    try std.testing.expect(arr3.height == 2);
    try std.testing.expect(arr3.items[0][1] == @as(i32, 20));
}

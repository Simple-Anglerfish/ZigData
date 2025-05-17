# Array Fish

A generic, resizable 2D array library for Zig, backed by a single contiguous memory allocation. It provides both convenient 2D `[y][x]` access and efficient flat buffer access, along with a set of manipulation functions, iterators, and binary serialization.

## Features

*   **Generic:** Works with any element type `T` (`Array2D(T)`).
*   **Contiguous Memory:** Stores all elements in a single flat buffer for cache-friendliness and easy interoperability.
*   **Dual Access:**
    *   2D access: `array.items[y][x]` (or safer `array.at(x,y)` / `array.get(x,y)`).
    *   Flat access: `array.flatData()`.
*   **Rich Manipulation API:**
        - `fill`, `clone`, `eql`
        - `extractRegion`, `copyInto`
        - `resize`, `transpose`, `rotateClockwise`, `flipHorizontal`, `flipVertical`
        - Element-wise operations: `map`, `mapWithContext`, `transform`, `transformToNew`, `combine`, `findFirst`
*   **Flexible Iterators:**
    *   Basic iterators (`iterator`) returning element pointers.
    *   Position-tracking iterators (`posIterator`) returning element pointers and `(x, y)` coordinates.
    *   Configurable iteration modes (`Flat`, `Row`, `Column`) via `iteratorEx`.
    *   Iterators with both `*const Array2D` and `*Array2D`.

## Status

This project is in early development and subject to change.




## Basic Usage

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const array2d = @import("array2d"); // Name used in exe.addModule()

pub fn main() !void {
    const allocator = std.heap.page_allocator; // Or any other allocator

    // Define the type of Array2D we want
    const IntArray2D = array2d.Array2D(i32);

    // Initialize a 3x2 array of i32
    var arr = try IntArray2D.init(allocator, 3, 2);
    defer arr.deinit(); // Important to free memory!

    std.debug.print("Initialized {d}x{d} array.\n", .{arr.width, arr.height});

    // Fill with values
    var count: i32 = 0;
    for (0..arr.height) |y| {
        for (0..arr.width) |x| {
            arr.at(x, y).* = count;
            count += 1;
        }
    }

    // Access and print an element (bounds-checked)
    if (arr.get(1, 1)) |val_ptr| {
        std.debug.print("Element at (1,1): {d}\n", .{val_ptr.*});
    } else {
        std.debug.print("Element at (1,1) is out of bounds (should not happen here).\n", .{});
    }

    // Using the non-bounds-checked `at` (use with care or after manual checks)
    // arr.at(0, 0).* = 100;

    // Print using debugPrint
    arr.debugPrint("{d}"); // Format string for elements

    // Access flat data
    const flat = arr.flatData();
    std.debug.print("Flat data: {any}\n", .{flat});
} ```

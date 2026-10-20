const std = @import("std");
const revo = @import("revo");
const root = @import("root.zig");
const specs = @import("specs.zig");
const table_std = @import("table.zig");
// const alloc_pool = @import("alloc_pool.zig");
const Args = root.host.ArgTypes;

const memory = revo.memory;
const Value = memory.Value;
const VM = revo.VM;
const HostResult = root.host.HostResult;
const Table = revo.table.Table;
const testing = revo.lang.test_helpers;
const table_methods = table_std.Impl;
const root_methods = root.Impl;

// type Dataframe = table<string, table<any>>
fn len_internal(vm: *VM, frame_table: Table) !usize {
    var frame_table_iter = frame_table.hash.orderedIterator();
    var col_array_table: *Table = undefined;
    var count: usize = 0;

    while (frame_table_iter.next()) |kv| {
        if (count != 0) {
            col_array_table = try vm.tables.get(kv.value.asTable().?);
            if (col_array_table.array.items.len != count) {
                return error.NonMatchingColumnLengths;
            }
        } else {
            col_array_table = try vm.tables.get(kv.value.asTable().?);
            count = col_array_table.array.items.len;
        }
    }

    return count;
}

pub const Impl = struct {

    // dataframe.len(Dataframe) -> num
    pub fn len(vm: *VM, frame_table_id: Args.table) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var frame_table_iter = frame_table.hash.orderedIterator();
        var col_array_table: *Table = undefined;
        var count: ?usize = null;

        while (frame_table_iter.next()) |kv| {
            if (count) |count_val| {
                col_array_table = try vm.tables.get(kv.value.asTable().?);
                if (col_array_table.array.items.len != count_val) {
                    return error.NonMatchingColumnLengths;
                }
            } else {
                col_array_table = try vm.tables.get(kv.value.asTable().?);
                count = col_array_table.array.items.len;
            }
        }

        return .data(Value.new.num(@as(f64, @floatFromInt(count.?))));
    }

    // dataframe.select(Dataframe, table<string>) -> Dataframe
    pub fn select(vm: *VM, frame_table_id: Args.table, names_table_id: Args.table) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        const names_table = try vm.tables.get(@backingInt(names_table_id));
        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);

        // In order of strings given to the select() function
        for (names_table.array.items) |colname| {
            // if the array string is in the hashmap
            const maybe_coltable = frame_table.getRaw(colname, vm);
            if (maybe_coltable) |coltable| {
                // clone it, place it in the result table under the same string name
                const copied_table_id = switch (try table_methods.copy(vm, @fromBackingInt(@intCast(coltable.asTable().?)))) {
                    .ok => |v| v.asTable().?,
                    .err => |e| return .{ .err = e },
                };
                try result_table.put(result_table_id, vm, colname, Value.new.table(copied_table_id));
            }
        }

        return .data(Value.new.table(result_table_id));
    }

    // dataframe.map(Dataframe, function) -> Dataframe
    pub fn map(vm: *VM, frame_table_id: Args.table, new_col_name: Args.string, f: Args.function) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        const frame_table_len: usize = try len_internal(vm, frame_table.*);
        const new_col_table_id = try vm.tables.create();
        const new_col_table = try vm.tables.get(new_col_table_id);

        // For each row in the frame table
        for (0..frame_table_len) |i| {
            // Extract the values into a tuple table where the atom keys are the column names
            const row_table_id = try vm.tables.create();
            const row_table = try vm.tables.get(row_table_id);
            var frame_table_iter = frame_table.hash.orderedIterator();

            while (frame_table_iter.next()) |kv| {
                const col_table_id = kv.value.asTable().?;
                const col_table = try vm.tables.get(col_table_id);
                try row_table.put(row_table_id, vm, kv.key, col_table.getRaw(Value.new.num(i), vm).?);
            }

            // Apply the function to the row
            const map_res = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{Value.new.table(row_table_id)}, null);
            // Add the result to the new column table
            try new_col_table.push(vm.runtime.alloc, map_res);
        }

        // Copy the original table
        const result_table_id = switch (try table_methods.deep_copy(vm, frame_table_id)) {
            .ok => |v| v.asTable().?,
            .err => |e| return .{ .err = e },
        };
        const result_table = try vm.tables.get(result_table_id);
        // Add the new column table to it with the new key
        try result_table.put(result_table_id, vm, Value.new.str(@backingInt(new_col_name)), Value.new.table(new_col_table_id));
        // Return the resulting table
        return HostResult.data(Value.new.table(result_table_id));
    }

    // dataframe.sort(Dataframe, function) -> Dataframe
    pub fn sort(vm: *VM, frame_table_id: Args.table, f: Args.function) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        const frame_table_len: usize = try len_internal(vm, frame_table.*);
        var frame_table_iter = frame_table.hash.orderedIterator();

        // Apply the function to each row in the DF as a new list of (idx, res)
        const RowResult = struct {idx: u64, f_result: Value};
        var row_results_list: std.ArrayList(RowResult) = .empty;
        defer row_results_list.deinit(vm.runtime.alloc);

        // For each row in the frame table
        for (0..frame_table_len) |i| {
            // Extract the values into a tuple table where the atom keys are the column names
            const row_table_id = try vm.tables.create();
            const row_table = try vm.tables.get(row_table_id);

            frame_table_iter = frame_table.hash.orderedIterator();
            while (frame_table_iter.next()) |kv| {
                const col_table_id = kv.value.asTable().?;
                const col_table = try vm.tables.get(col_table_id);
                try row_table.put(row_table_id, vm, kv.key, col_table.getRaw(Value.new.num(i), vm).?);
            }

            // Apply the function to the row
            const map_res = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{Value.new.table(row_table_id)}, null);
            // Add the f result to the new column table
            try row_results_list.append(vm.runtime.alloc, .{.idx = i, .f_result = map_res});
        }

        // Sort the list by f result
        const Context = struct {
            vm_: *VM,
            pub fn lessThanFn(ctx: @This(), lhs: RowResult, rhs: RowResult) bool {
                return ctx.vm_.compare(lhs.f_result, rhs.f_result) == .lt;
            }
        };
        std.mem.sort(RowResult, row_results_list.items, Context{ .vm_ = vm }, Context.lessThanFn);

        // Create a new result Dataframe with empty copied columns
        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);
        frame_table_iter = frame_table.hash.orderedIterator();
        while (frame_table_iter.next()) |kv| {
            try result_table.put(result_table_id, vm, kv.key, Value.new.table(try vm.tables.create()));
        }

        // For each result
        for (row_results_list.items) |row_result| {
            // For each column
            frame_table_iter = frame_table.hash.orderedIterator();
            while (frame_table_iter.next()) |kv| {
                // Get the element at the result's index
                const col_table_id = kv.value.asTable().?;
                const col_table = try vm.tables.get(col_table_id);
                const col_ele = col_table.getRaw(Value.new.num(row_result.idx), vm).?;

                // Append it to the result dataframe's column
                const result_col_table_id = result_table.getRaw(kv.key, vm).?.asTable().?;
                const result_col_table = try vm.tables.get(result_col_table_id);
                try result_col_table.array.append(vm.runtime.alloc, col_ele);
            }
        }

        // Return the result dataframe
        return HostResult.data(Value.new.table(result_table_id));
    }

    // dataframe.stack(table<Dataframe>) -> Dataframe
        // Ensure each Dataframe in the input table has matching column names and types
        // Create a result dataframe with the same columns
        // For each Dataframe in the input table
            // Append that Dataframe's columns to the current result columns
        // Return the result dataframe

    // dataframe.filter(Dataframe, function) -> Dataframe
        // Create a result dataframe with the same columns as the input Dataframe
        // For each row in the input Dataframe for which the function returns true
            // Append that row's values to the result Dataframe
        // Return the result dataframe

    // dataframe.rename(Dataframe, string, string) -> Dataframe
        // Create a result dataframe with every column copied except the renamed one
        // Copy the source column with the new name
        // Return the result dataframe

    // dataframe.inner_join(table<Dataframe>, string) -> Dataframe
        // Ensure the input dataframes all have a join column named the input string of matching type
        // Pull out the first Dataframe's join column as a list
        // Create a result Dataframe and add the join column as an array table
        // For each input Dataframe in the input table
            // For each column in the current Dataframe not in the result Dataframe
                // For each value in the join column
                    // For each index in the new column to be added
                        // If the value in the join column matches the value at the input Dataframe's join column index
                            // Append the value in the new column at that index
                            // continue
        // Return the result dataframe

    // dataframe.unique(Dataframe, table<string>) -> Dataframe
        // Initiate a AutoHashMap of <f64, bool> to track seen row values
        // Initiate a result Dataframe
        // For each row in the input Dataframe
            // Set an accumulator to the root.hash() of the first column in the string table
            // For each other column in the string table
                // Mod the accumulator with the root.hash() of that value
            // If the resulting hash is in the seen hashmap, continue
            // Otherwise, push the row values on the result table, and add the hash to the seen hashmap
        // Return the result dataframe


};

pub const impls: []const specs.Impl = root.host.impls(Impl).val;

// dataframe.group_by(Frame) -> Dataframe
// dataframe.transpose(Frame) -> Dataframe

test "frame functions and methods" {
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.select({\"foos\", \"bazzes\"}) == {\"foos\" = {1, 2, 3}, \"bazzes\" = {7, 8, 9}}");
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.len() == 3");
    try testing.topTrue("dataframe.map({\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}}, \"bazzes\", fn (row) row[\"foos\"] * row[\"bars\"]) == {\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {4, 10, 18}}");
    try testing.topTrue("dataframe.sort({\"foos\" = {3, 1, 2}, \"bars\" = {4, 5, 6}}, fn (row) row[\"foos\"]) == {\"foos\" = {1, 2, 3}, \"bars\" = {5, 6, 4}}");
}

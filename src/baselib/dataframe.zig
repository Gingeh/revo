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

    // frame.sort(Dataframe, function) -> Dataframe
        // Apply the function to each row in the DF as a new list of (idx, res)
        // Sort the list by result
        // Create a new result Dataframe with empty copied columns
        // For each result
            // Find the index in the results list
            // Get the elements at that index
            // Append them to the result dataframe
        // Return the result dataframe

    // frame.stack(table<Dataframe>) -> Dataframe
        // Ensure each Dataframe in the input table has matching column names and types
        // Create a result dataframe with the same columns
        // For each Dataframe in the input table
            // Append that Dataframe's columns to the current result columns
        // Return the result dataframe

    // frame.filter(Dataframe, function) -> Dataframe
        // Create a result dataframe with the same columns as the input Dataframe
        // For each row in the input Dataframe for which the function returns true
            // Append that row's values to the result Dataframe
        // Return the result dataframe

    // frame.rename(Dataframe, string, string) -> Dataframe
        // Create a result dataframe with every column copied except the renamed one
        // Copy the source column with the new name
        // Return the result dataframe

    // frame.inner_join(table<Dataframe>, string) -> Dataframe
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


};

pub const impls: []const specs.Impl = root.host.impls(Impl).val;

// frame.rename(Frame) -> Dataframe
// frame.unique(Frame) -> Dataframe
// frame.summarize(Frame) -> Dataframe
// frame.group_by(Frame) -> Dataframe
// frame.gather(Frame) -> Dataframe

test "frame functions and methods" {
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.select({\"foos\", \"bazzes\"}) == {\"foos\" = {1, 2, 3}, \"bazzes\" = {7, 8, 9}}");
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.len() == 3");
    try testing.topTrue("dataframe.map({\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}}, \"bazzes\", fn (row) row[\"foos\"] * row[\"bars\"]) == {\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {4, 10, 18}}");
}

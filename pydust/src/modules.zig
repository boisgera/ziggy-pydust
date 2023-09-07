const std = @import("std");
const ffi = @import("ffi.zig");
const py = @import("pydust.zig");
const pytypes = @import("pytypes.zig");
const funcs = @import("functions.zig");
const PyMemAllocator = @import("mem.zig").PyMemAllocator;

pub fn define(comptime mod: py.ModuleDef) type {
    return struct {
        const definition = mod.definition;

        const doc: ?[:0]const u8 = if (@hasDecl(definition, "__doc__")) @field(definition, "__doc__") else null;

        const slots = Slots(mod);
        const methods = Methods(mod.definition);

        /// The PyInit_<modname> function to be exported in the output object file.
        pub fn init() callconv(.C) ?*ffi.PyObject {
            var pyModuleDef = py.allocator.create(ffi.PyModuleDef) catch @panic("OOM");
            pyModuleDef.* = ffi.PyModuleDef{
                .m_base = ffi.PyModuleDef_Base{
                    .ob_base = ffi.PyObject{
                        .ob_refcnt = 1,
                        .ob_type = null,
                    },
                    .m_init = null,
                    .m_index = 0,
                    .m_copy = null,
                },
                .m_name = mod.name.ptr,
                .m_doc = if (doc) |d| d.ptr else null,
                .m_size = @sizeOf(definition),
                .m_methods = @constCast(&methods.pydefs),
                .m_slots = @constCast(slots.slots.ptr),
                .m_traverse = null,
                .m_clear = null,
                .m_free = null,
            };
            return ffi.PyModuleDef_Init(pyModuleDef);
        }
    };
}

fn Methods(comptime definition: type) type {
    return struct {
        const Self = @This();
        const empty = ffi.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };

        const defs: []const type = blk: {
            var defs_: []const type = &.{};
            for (@typeInfo(definition).Struct.decls) |decl| {
                const value = @field(definition, decl.name);
                const typeInfo = @typeInfo(@TypeOf(value));

                // For now, we skip non-function declarations.
                if (typeInfo != .Fn or funcs.isReserved(decl.name)) {
                    continue;
                }

                // The valid types for a "self" parameter are either the module state struct (definition), or a py.PyModule.
                const sig = funcs.parseSignature(decl.name, typeInfo.Fn, &.{ py.PyModule, *definition, *const definition });
                const def = funcs.wrap(value, sig, 0);
                defs_ = defs_ ++ .{def};
            }
            break :blk defs_[0..defs_.len];
        };

        pub const pydefs: [defs.len:empty]ffi.PyMethodDef = blk: {
            var pydefs_: [defs.len:empty]ffi.PyMethodDef = undefined;
            for (0..defs.len) |i| {
                pydefs_[i] = defs[i].aspy();
            }
            break :blk pydefs_;
        };
    };
}

fn Slots(comptime mod: py.ModuleDef) type {
    const empty = ffi.PyModuleDef_Slot{ .slot = 0, .value = null };
    const definition = mod.definition;
    const classDefs = py.findClasses(mod);

    return struct {
        const Self = @This();

        pub const slots: [:empty]const ffi.PyModuleDef_Slot = blk: {
            var slots_: [:empty]const ffi.PyModuleDef_Slot = &.{};
            slots_ = slots_ ++ .{ffi.PyModuleDef_Slot{
                .slot = ffi.Py_mod_exec,
                .value = @ptrCast(@constCast(&Self.mod_exec)),
            }};

            // Then we check to see if the user has created a manual exec method.
            // This isn't really a Python dunder method, but it'll do for our API.
            if (@hasDecl(definition, "__exec__")) {
                // TODO(ngates): trampoline this.
                const initFn = @field(definition, "__exec__");

                slots_ = slots_ ++ .{ffi.PyModuleDef_Slot{
                    .slot = ffi.Py_mod_exec,
                    .value = @ptrCast(@constCast(&initFn)),
                }};
            }

            slots_ = slots_ ++ .{empty};

            break :blk slots_;
        };

        fn mod_exec(pymodule: *ffi.PyObject) callconv(.C) c_int {
            mod_exec_internal(.{ .obj = .{ .py = pymodule } }) catch return -1;
            return 0;
        }

        inline fn mod_exec_internal(module: py.PyModule) !void {
            // Initialize the state struct to default values
            const state = try module.getState(definition);
            if (@hasDecl(definition, "__new__")) {
                const newFunc = @field(definition, "__new__");
                state.* = try newFunc();
            } else {
                state.* = definition{};
            }

            // Add class definitions to the module
            inline for (classDefs) |classDef| {
                const classType = pytypes.define(classDef);
                const pytype: py.PyType = try classType.init(module);
                try module.addObjectRef(classType.name, pytype.obj);
            }
        }
    };
}

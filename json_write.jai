// Shared reflected JSON writer. Callers own the builder and discard partial output on failure.
// Values do not include their outer comma/comment/newline; containers and key/value helpers
// append commas before enum option comments so every emitted document remains readable JSONC.
#scope_module

#import "Basic";
Reflection :: #import "MyReflection";

#scope_export

json_write_value :: (builder: *String_Builder, $T: Type, value: *T, depth: int = 0) -> bool {
    structures :: #run Reflection.collect_structs(type_info(T));
    return json_write_reflected(builder, type_info(T), cast(*u8)value, depth, structures, container_codecs(T));
}

json_write_string :: (builder: *String_Builder, text: string) -> bool {
    if !json_valid_utf8(text) {
        return false;
    }
    HEX :: "0123456789ABCDEF";
    append(builder, "\"");
    for byte: text {
        if byte == #char "\"" {
            append(builder, "\\\"");
        }
        else if byte == #char "\\" {
            append(builder, "\\\\");
        }
        else if byte == #char "\n" {
            append(builder, "\\n");
        }
        else if byte == #char "\r" {
            append(builder, "\\r");
        }
        else if byte == #char "\t" {
            append(builder, "\\t");
        }
        else if byte == #char "\x08" {
            append(builder, "\\b");
        }
        else if byte == #char "\x0C" {
            append(builder, "\\f");
        }
        else if byte < #char " " {
            append(builder, "\\u00");
            append(builder, HEX[byte >> 4]);
            append(builder, HEX[byte & 0x0F]);
        }
        else {
            append(builder, byte);
        }
    }
    append(builder, "\"");
    return true;
}

json_write_enum_options :: (builder: *String_Builder, info: *Type_Info) -> bool {
    if !info {
        return false;
    }

    if info.type != .ENUM {
        return true;
    }

    enumeration := cast(*Type_Info_Enum)info;
    append(builder, " // Options: ");
    for name, index: enumeration.names {
        if !json_valid_utf8(name) {
            return false;
        }
        if index > 0 {
            append(builder, ", ");
        }
        append(builder, name);
    }

    return true;
}

json_write_key_value :: (builder: *String_Builder,
                         key: string,
                         $T: Type,
                         value: *T,
                         depth: int = 0,
                         trailing_comma: bool = false) -> bool
{
    if depth < 0 || depth > JSON_WRITE_MAX_DEPTH {
        return false;
    }

    json_write_indent(builder, depth);
    if !json_write_string(builder, key) {
        return false;
    }

    append(builder, ": ");
    if !json_write_value(builder, T, value, depth) {
        return false;
    }

    if trailing_comma {
        append(builder, ",");
    }

    if !json_write_enum_options(builder, type_info(T)) {
        return false;
    }

    append(builder, "\n");
    return true;
}

#scope_module

json_write_reflected :: (builder: *String_Builder,
                         info: *Type_Info,
                         source: *u8,
                         depth: int,
                         structures: []Reflection.Struct_Metadata, codecs: []ContainerCodec) -> bool
{
    if depth < 0 || depth > JSON_WRITE_MAX_DEPTH || !info || !source {
        return false;
    }

    if info == type_info(JsonWriteMath.Color) {
        HEX :: "0123456789ABCDEF";
        color := cast(*JsonWriteMath.Color)source;
        append(builder, "\"#");
        channels := ifx color.a == 255 then 3 else 4;
        for i: 0..channels - 1 {
            append(builder, HEX[source[i] >> 4]);
            append(builder, HEX[source[i] & 15]);
        }
        append(builder, "\"");
        return true;
    }

    if info == type_info(JsonWriteMath.Vec4) {
        append(builder, "[");
        for i: 0..3 {
            if i > 0 {
                append(builder, ", ");
            }
            if !json_write_reflected(builder, type_info(float), source + i * size_of(float), depth + 1, structures, codecs) {
                return false;
            }
        }
        append(builder, "]");
        return true;
    }

    for codec: codecs {
        if cast(*Type_Info)codec.value_type == info {
            return codec.write(builder, source, depth, structures, codecs);
        }
    }
    if info.type == .STRING {
        return json_write_string(builder, (cast(*string)source).*);
    }

    if info.type == .STRUCT {
        structure := cast(*Type_Info_Struct)info;
        if structure.textual_flags & .UNION {
            return false;
        }
        for member: structure.members {
            if member.flags & .OVERLAY {
                return false;
            }
        }
        fields := Reflection.struct_fields(structures, info);
        remaining := fields.count;
        append(builder, "{");
        if remaining == 0 {
            append(builder, "}");
            return true;
        }
        append(builder, "\n");
        for field: fields {
            json_write_indent(builder, depth + 1);
            if !json_write_string(builder, field.name) {
                return false;
            }
            append(builder, ": ");
            member_info := cast(*Type_Info)field.member_type;
            if !json_write_reflected(builder, member_info, source + field.offset, depth + 1, structures, codecs) {
                return false;
            }
            remaining -= 1;
            if remaining > 0 {
                append(builder, ",");
            }
            if !json_write_enum_options(builder, member_info) {
                return false;
            }
            append(builder, "\n");
        }
        json_write_indent(builder, depth);
        append(builder, "}");
        return true;
    }

    if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        if array.array_type != .FIXED {
            return false;
        }
        append(builder, "[");
        if array.array_count == 0 {
            append(builder, "]");
            return true;
        }
        append(builder, "\n");
        for index: 0..array.array_count - 1 {
            json_write_indent(builder, depth + 1);
            if !json_write_reflected(builder, array.element_type, source + index * array.element_type.runtime_size, depth + 1, structures, codecs) {
                return false;
            }
            if index + 1 < array.array_count {
                append(builder, ",");
            }
            if !json_write_enum_options(builder, array.element_type) {
                return false;
            }
            append(builder, "\n");
        }
        json_write_indent(builder, depth);
        append(builder, "]");
        return true;
    }

    if info.type == .ENUM {
        if info.runtime_size < 1 || info.runtime_size > size_of(s64) {
            return false;
        }
        enumeration := cast(*Type_Info_Enum)info;
        for value, index: enumeration.values {
            bytes := cast(*u8)*value;
            matches := true;
            for offset: 0..info.runtime_size - 1 {
                if source[offset] != bytes[offset] {
                    matches = false;
                    break;
                }
            }
            if matches {
                return json_write_string(builder, enumeration.names[index]);
            }
        }
        return false;
    }

    if info.type == .BOOL {
        append(builder, ifx (cast(*bool)source).* then "true" else "false");
        return true;
    }

    if info.type == .INTEGER {
        return json_write_integer(builder, cast(*Type_Info_Integer)info, source);
    }

    if info.type == .FLOAT {
        if info.runtime_size == size_of(float32) {
            value := (cast(*float32)source).*;
            if !JsonWriteMath.is_finite(value) {
                return false;
            }
            print_to_builder(builder, "%", FormatFloat.{value = value, trailing_width = 9, mode = .SHORTEST});
            return true;
        }
        if info.runtime_size == size_of(float64) {
            value := (cast(*float64)source).*;
            if !JsonWriteMath.is_finite(value) {
                return false;
            }
            print_to_builder(builder, "%", FormatFloat.{value = value, trailing_width = 17, mode = .SHORTEST});
            return true;
        }
    }
    return false;
}

JsonWriteMath :: #import "MyMath";
JSON_WRITE_MAX_DEPTH :: 64;

json_write_indent :: (builder: *String_Builder, depth: int) {
    for index: 0..depth - 1 {
        append(builder, "  ");
    }
}

json_write_integer :: (builder: *String_Builder, info: *Type_Info_Integer, source: *u8) -> bool {
    if info.signed {
        value: s64;
        if info.runtime_size == 1 {
            value = (cast(*s8)source).*;
        }
        else if info.runtime_size == 2 {
            value = (cast(*s16)source).*;
        }
        else if info.runtime_size == 4 {
            value = (cast(*s32)source).*;
        }
        else if info.runtime_size == 8 {
            value = (cast(*s64)source).*;
        }
        else {
            return false;
        }
        print_to_builder(builder, "%", FormatInt.{value = value});
    }
    else {
        value: u64;
        if info.runtime_size == 1 {
            value = (cast(*u8)source).*;
        }
        else if info.runtime_size == 2 {
            value = (cast(*u16)source).*;
        }
        else if info.runtime_size == 4 {
            value = (cast(*u32)source).*;
        }
        else if info.runtime_size == 8 {
            value = (cast(*u64)source).*;
        }
        else {
            return false;
        }
        print_to_builder(builder, "%", FormatInt.{value = value});
    }
    return true;
}

// Standard container adapters. Schema discovery and traversal are reflection-driven.
#scope_module

ContainerCompiler :: #import "Compiler";
ContainerTables :: #import "Hash_Table";
using,only(for_expansion) ContainerTables;


ContainerCodec :: struct {
    value_type: Type;
    read: (p: *JsonParser, dest: *u8, depth: int, structures: []Reflection.Struct_Metadata);
    write: (builder: *String_Builder, source: *u8, depth: int, structures: []Reflection.Struct_Metadata, codecs: []ContainerCodec) -> bool;
    memory: (value: *u8, clone: bool, structures: []Reflection.Struct_Metadata, codecs: []ContainerCodec);
}

is_config_table :: (info: *Type_Info) -> bool #compile_time {
    if info.type != .STRUCT {
        return false;
    }
    return (cast(*Type_Info_Struct)info).polymorph_source_struct == type_info(ContainerTables.Table(string, int)).polymorph_source_struct;
}

collect_container_types :: (root: *Type_Info) -> []Type #compile_time {
    pending: [..]*Type_Info;
    seen: [..]*Type_Info;
    result: [..]Type;
    array_add(*pending, root);
    cursor: int;
    while cursor < pending.count {
        info := pending[cursor];
        cursor += 1;
        found: bool;
        for seen {
            if it == info {
                found = true;
            }
        }
        if found {
            continue;
        }
        array_add(*seen, info);
        if info.type == .ARRAY {
            array := cast(*Type_Info_Array)info;
            array_add(*pending, array.element_type);
            if array.array_type != .FIXED {
                array_add(*result, ContainerCompiler.get_type(info));
            }
        }
        else if is_config_table(info) {
            array_add(*result, ContainerCompiler.get_type(info));
            for member: (cast(*Type_Info_Struct)info).members {
                if member.name == "entries" {
                    entry := cast(*Type_Info_Struct)(cast(*Type_Info_Array)member.type).element_type;
                    for field: entry.members {
                        if field.name == "value" {
                            array_add(*pending, field.type);
                        }
                    }
                }
            }
        }
        else if info.type == .STRUCT {
            metadata := Reflection.collect_struct(cast(*Type_Info_Struct)info);
            for field: metadata.serialized_fields {
                array_add(*pending, cast(*Type_Info)field.member_type);
            }
        }
    }
    array_free(pending);
    array_free(seen);
    return result;
}

container_codecs :: ($T: Type) -> []ContainerCodec {
    types :: #run collect_container_types(type_info(T));
    #insert -> string {
        builder: String_Builder;
        defer free_buffers(*builder);
        append(*builder, "result :: ContainerCodec.[");
        for types {
            if it_index > 0 {
                append(*builder, ",");
            }
            print_to_builder(*builder, ".{types[%], ContainerOps(types[%]).read, ContainerOps(types[%]).write, ContainerOps(types[%]).memory}",
                             it_index, it_index, it_index, it_index);
        }
        append(*builder, "];\nreturn result;\n");
        return builder_to_string(*builder);
    }
}

// Strings borrow the source/decoded-string pool; only container storage is cloned or released here.
container_memory :: (info: *Type_Info,
                     value: *u8,
                     clone: bool,
                     structures: []Reflection.Struct_Metadata,
                     codecs: []ContainerCodec)
{
    for codec: codecs {
        if cast(*Type_Info)codec.value_type == info {
            codec.memory(value, clone, structures, codecs);
            return;
        }
    }
    if info.type == .STRUCT {
        for field: Reflection.struct_fields(structures, info) {
            container_memory(cast(*Type_Info)field.member_type, value + field.offset, clone, structures, codecs);
        }
    }
    else if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        if array.array_type == .FIXED {
            for i: 0..array.array_count - 1 {
                container_memory(array.element_type, value + i * array.element_type.runtime_size, clone, structures, codecs);
            }
        }
    }
}

ContainerOps :: struct (T: Type) {
    IS_TABLE :: #run is_config_table(type_info(T));
    #if IS_TABLE {
        #assert T.Key_Type == string;
        E :: T.Value_Type;
    }
    else {
        E :: #run ContainerCompiler.get_type(type_info(T).element_type);
    }

    memory :: (raw: *u8, clone: bool, structures: []Reflection.Struct_Metadata, codecs: []ContainerCodec) {
        value := cast(*T)raw;
        #if IS_TABLE {
            if clone {
                old := value.*;
                memset(value, 0, size_of(T));
                for item, key: old {
                    copy := item;
                    container_memory(type_info(E), cast(*u8)*copy, true, structures, codecs);
                    ContainerTables.table_add(value, key, copy);
                }
            }
            else {
                for *item: value.* {
                    container_memory(type_info(E), cast(*u8)item, false, structures, codecs);
                }
                ContainerTables.deinit(value);
            }
        }
        else {
            if clone {
                old := value.*;
                items: [..]E;
                for item: old {
                    copy := item;
                    container_memory(type_info(E), cast(*u8)*copy, true, structures, codecs);
                    array_add(*items, copy);
                }
                value.* = items;
            }
            else {
                for *item: value.* {
                    container_memory(type_info(E), cast(*u8)item, false, structures, codecs);
                }
                #if #run type_info(T).array_type == .RESIZABLE {
                    array_free(value.*);
                }
                else {
                    free(value.data);
                }
                memset(value, 0, size_of(T));
            }
        }
    }

    read :: (p: *JsonParser, raw: *u8, depth: int, structures: []Reflection.Struct_Metadata) {
        value := cast(*T)raw;
        #if IS_TABLE {
            if !json_take(p, #char "{") {
                return;
            }
            seen: [..]string;
            defer array_free(seen);
            if json_consume(p, #char "}") {
                return;
            }
            while !p.error {
                key := json_quoted(p);
                for previous: seen {
                    if previous == key {
                        p.error = true;
                        return;
                    }
                }
                array_add(*seen, key);
                if !json_take(p, #char ":") {
                    return;
                }
                item := ContainerTables.table_find_pointer(value, key);
                if !item {
                    initial: E;
                    container_memory(type_info(E), cast(*u8)*initial, true, structures, p.codecs);
                    item = ContainerTables.table_add(value, key, initial);
                }
                json_read_value(p, type_info(E), cast(*u8)item, depth + 1, structures);
                if json_consume(p, #char "}") {
                    return;
                }
                if !json_take(p, #char ",") {
                    return;
                }
            }
        }
        else {
            if !json_take(p, #char "[") {
                return;
            }
            memory(raw, false, structures, p.codecs);
            items: [..]E;
            defer value.* = items;
            if json_consume(p, #char "]") {
                return;
            }
            while !p.error {
                item: E;
                container_memory(type_info(E), cast(*u8)*item, true, structures, p.codecs);
                json_read_value(p, type_info(E), cast(*u8)*item, depth + 1, structures);
                array_add(*items, item);
                if json_consume(p, #char "]") {
                    return;
                }
                if !json_take(p, #char ",") {
                    return;
                }
            }
        }
    }

    write :: (builder: *String_Builder,
              raw: *u8,
              depth: int,
              structures: []Reflection.Struct_Metadata,
              codecs: []ContainerCodec) -> bool
    {
        value := cast(*T)raw;
        #if IS_TABLE {
            append(builder, "{");
        }
        else {
            append(builder, "[");
        }
        if value.count > 0 {
            append(builder, "\n");
        }
        remaining := value.count;
        for *item, key: value.* {
            json_write_indent(builder, depth + 1);
            #if IS_TABLE {
                if !json_write_string(builder, key) {
                    return false;
                }
                append(builder, ": ");
            }
            if !json_write_reflected(builder, type_info(E), cast(*u8)item, depth + 1, structures, codecs) {
                return false;
            }
            remaining -= 1;
            if remaining > 0 {
                append(builder, ",");
            }
            if !json_write_enum_options(builder, type_info(E)) {
                return false;
            }
            append(builder, "\n");
        }
        if value.count > 0 {
            json_write_indent(builder, depth);
        }
        #if IS_TABLE {
            append(builder, "}");
        }
        else {
            append(builder, "]");
        }
        return remaining == 0;
    }
}

#scope_export
// Clone container storage before mutating a value copied from type defaults or another owner.
json_clone_containers :: ($T: Type, value: *T) {
    structures :: #run Reflection.collect_structs(type_info(T));
    container_memory(type_info(T), cast(*u8)value, true, structures, container_codecs(T));
}

// Release container storage only; strings still belong to the decoder's source/string pool.
json_release :: ($T: Type, value: *T) {
    structures :: #run Reflection.collect_structs(type_info(T));
    container_memory(type_info(T), cast(*u8)value, false, structures, container_codecs(T));
}

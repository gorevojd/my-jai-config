// Shared reflected JSON writer. Callers own the builder and discard partial output on failure.
// Values do not include their outer comma/comment/newline; containers and key/value helpers
// append commas before enum option comments so every emitted document remains readable JSONC.
#scope_file

#import "Basic";
Reflection :: #import "MyReflection";

#scope_export

json_write_value :: (builder: *String_Builder, $T: Type, value: *T, depth: int = 0) -> bool {
    structures :: #run Reflection.collect_structs(type_info(T));
    return json_write_reflected(builder, type_info(T), cast(*u8)value, depth, structures);
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
        } else if byte == #char "\\" {
            append(builder, "\\\\");
        } else if byte == #char "\n" {
            append(builder, "\\n");
        } else if byte == #char "\r" {
            append(builder, "\\r");
        } else if byte == #char "\t" {
            append(builder, "\\t");
        } else if byte == #char "\x08" {
            append(builder, "\\b");
        } else if byte == #char "\x0C" {
            append(builder, "\\f");
        } else if byte < #char " " {
            append(builder, "\\u00");
            append(builder, HEX[byte >> 4]);
            append(builder, HEX[byte & 0x0F]);
        } else {
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

#scope_file

json_write_reflected :: (builder: *String_Builder,
                         info: *Type_Info,
                         source: *u8,
                         depth: int,
                         structures: []Reflection.Struct_Metadata) -> bool
{
    if depth < 0 || depth > JSON_WRITE_MAX_DEPTH || !info || !source {
        return false;
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
            if !json_write_reflected(builder, member_info, source + field.offset, depth + 1, structures) {
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
            if !json_write_reflected(builder, array.element_type, source + index * array.element_type.runtime_size, depth + 1, structures) {
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
        } else if info.runtime_size == 2 {
            value = (cast(*s16)source).*;
        } else if info.runtime_size == 4 {
            value = (cast(*s32)source).*;
        } else if info.runtime_size == 8 {
            value = (cast(*s64)source).*;
        } else {
            return false;
        }
        print_to_builder(builder, "%", FormatInt.{value = value});
    } else {
        value: u64;
        if info.runtime_size == 1 {
            value = (cast(*u8)source).*;
        } else if info.runtime_size == 2 {
            value = (cast(*u16)source).*;
        } else if info.runtime_size == 4 {
            value = (cast(*u32)source).*;
        } else if info.runtime_size == 8 {
            value = (cast(*u64)source).*;
        } else {
            return false;
        }
        print_to_builder(builder, "%", FormatInt.{value = value});
    }
    return true;
}

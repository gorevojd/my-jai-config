// JSON with comments, shared by the config manager and application-specific decoders.
// Source slices borrow text. Only decoded escaped strings allocate, and every allocation is
// appended to strings so the caller can release the entire candidate on success or failure.
#scope_file

#import "Basic";
Reflection :: #import "MyReflection";

#scope_export

JsonEntry :: struct {
    key: string;
    value: string;
}

json_split_configs :: (text: string, entries: *[..]JsonEntry, strings: *[..]string) -> bool {
    p := JsonParser.{text = text, strings = strings};
    if !json_take(*p, #char "{") {
        return false;
    }
    if json_consume(*p, #char "}") {
        return json_finished(*p);
    }
    while !p.error {
        key := json_quoted(*p);
        if p.error || !json_take(*p, #char ":") {
            return false;
        }
        for entry: entries.* {
            if entry.key == key {
                return false;
            }
        }
        json_space(*p);
        start := p.cursor;
        json_skip_value(*p, 0);
        if p.error {
            return false;
        }
        array_add(entries, JsonEntry.{key, json_slice(text, start, p.cursor)});
        if json_consume(*p, #char "}") {
            return json_finished(*p);
        }
        if !json_take(*p, #char ",") {
            return false;
        }
    }
    return false;
}

// Initialize dest to T's defaults before decoding; release owned containers before reusing dest. Unknown fields, duplicate fields,
// unsupported types and numeric overflow fail without silently coercing values.
json_decode :: (text: string, $T: Type, dest: *T, strings: *[..]string) -> bool {
    structures :: #run Reflection.collect_structs(type_info(T));
    codecs := container_codecs(T);
    container_memory(type_info(T), cast(*u8)dest, true, structures, codecs);
    p := JsonParser.{text = text, strings = strings, codecs = codecs};
    json_read_value(*p, type_info(T), cast(*u8)dest, 0, structures);
    return json_finished(*p);
}

#scope_module


// Blank/comment-only files and empty objects can be initialized without accepting malformed JSON.
json_is_empty_config :: (text: string) -> bool {
    p := JsonParser.{text = text};
    json_space(*p);
    if json_finished(*p) {
        return true;
    }
    return json_take(*p, #char "{") && json_consume(*p, #char "}") && json_finished(*p);
}

json_valid_utf8 :: (text: string) -> bool {
    p := JsonParser.{text = text};
    while p.cursor < text.count {
        byte := text[p.cursor];
        p.cursor += 1;
        if byte >= 0x80 && !json_utf8_tail(*p, byte) {
            return false;
        }
    }
    return true;
}

#scope_module

JsonMath :: #import "MyMath";
JSON_MAX_DEPTH :: 64;

JsonParser :: struct {
    text: string;
    cursor: int;
    error: bool;
    strings: *[..]string;
    codecs: []ContainerCodec;
}

json_slice :: (text: string, first: int, last: int) -> string {
    return .{last - first, text.data + first};
}

json_space :: (p: *JsonParser) {
    while !p.error && p.cursor < p.text.count {
        ch := p.text[p.cursor];
        if ch == #char " " || ch == #char "\t" || ch == #char "\n" || ch == #char "\r" {
            p.cursor += 1;
            continue;
        }
        if ch != #char "/" || p.cursor + 1 >= p.text.count {
            return;
        }
        next := p.text[p.cursor + 1];
        if next == #char "/" {
            p.cursor += 2;
            while (p.cursor < p.text.count && p.text[p.cursor] != #char "\n" &&
                   p.text[p.cursor] != #char "\r") {
                p.cursor += 1;
            }
        }
        else if next == #char "*" {
            p.cursor += 2;
            closed: bool;
            while p.cursor + 1 < p.text.count {
                if p.text[p.cursor] == #char "*" && p.text[p.cursor + 1] == #char "/" {
                    p.cursor += 2;
                    closed = true;
                    break;
                }
                p.cursor += 1;
            }
            if !closed {
                p.error = true;
            }
        } else {
            return;
        }
    }
}

json_consume :: (p: *JsonParser, ch: u8) -> bool {
    json_space(p);
    if p.error || p.cursor >= p.text.count || p.text[p.cursor] != ch {
        return false;
    }
    p.cursor += 1;
    return true;
}

json_take :: (p: *JsonParser, ch: u8) -> bool {
    if !json_consume(p, ch) {
        p.error = true;
        return false;
    }
    return true;
}

json_finished :: (p: *JsonParser) -> bool {
    json_space(p);
    return !p.error && p.cursor == p.text.count;
}

json_hex_quad :: (p: *JsonParser) -> u32 {
    if p.cursor + 4 > p.text.count {
        p.error = true;
        return 0;
    }
    result: u32;
    for index: 0..3 {
        ch := p.text[p.cursor];
        p.cursor += 1;
        result <<= 4;
        if ch >= #char "0" && ch <= #char "9" {
            result += cast(u32)(ch - #char "0");
        }
        else if ch >= #char "a" && ch <= #char "f" {
            result += 10 + cast(u32)(ch - #char "a");
        }
        else if ch >= #char "A" && ch <= #char "F" {
            result += 10 + cast(u32)(ch - #char "A");
        } else {
            p.error = true;
            return 0;
        }
    }
    return result;
}

json_append_codepoint :: (builder: *String_Builder, value: u32) {
    bytes: [4]u8;
    count: int;
    if value < 0x80 {
        bytes[0] = cast(u8)value;
        count = 1;
    }
    else if value < 0x800 {
        bytes[0] = cast(u8)(0xC0 | (value >> 6));
        bytes[1] = cast(u8)(0x80 | (value & 0x3F));
        count = 2;
    }
    else if value < 0x10000 {
        bytes[0] = cast(u8)(0xE0 | (value >> 12));
        bytes[1] = cast(u8)(0x80 | ((value >> 6) & 0x3F));
        bytes[2] = cast(u8)(0x80 | (value & 0x3F));
        count = 3;
    } else {
        bytes[0] = cast(u8)(0xF0 | (value >> 18));
        bytes[1] = cast(u8)(0x80 | ((value >> 12) & 0x3F));
        bytes[2] = cast(u8)(0x80 | ((value >> 6) & 0x3F));
        bytes[3] = cast(u8)(0x80 | (value & 0x3F));
        count = 4;
    }
    append(builder, string.{count, bytes.data});
}

json_utf8_tail :: (p: *JsonParser, first: u8) -> bool {
    remaining: int;
    codepoint, minimum: u32;
    if first >= 0xC2 && first <= 0xDF {
        remaining = 1;
        codepoint = cast(u32)(first & 0x1F);
        minimum = 0x80;
    }
    else if first >= 0xE0 && first <= 0xEF {
        remaining = 2;
        codepoint = cast(u32)(first & 0x0F);
        minimum = 0x800;
    }
    else if first >= 0xF0 && first <= 0xF4 {
        remaining = 3;
        codepoint = cast(u32)(first & 0x07);
        minimum = 0x10000;
    } else {
        return false;
    }
    if p.cursor + remaining > p.text.count {
        return false;
    }
    for index: 0..remaining - 1 {
        next := p.text[p.cursor];
        p.cursor += 1;
        if next < 0x80 || next > 0xBF {
            return false;
        }
        codepoint = (codepoint << 6) | cast(u32)(next & 0x3F);
    }
    return codepoint >= minimum && codepoint <= 0x10FFFF && !(codepoint >= 0xD800 && codepoint <= 0xDFFF);
}

json_quoted :: (p: *JsonParser, decode: bool = true) -> string {
    if !json_take(p, #char "\"") {
        return "";
    }
    start := p.cursor;
    segment := start;
    escaped: bool;
    builder: String_Builder;
    defer free_buffers(*builder);
    while p.cursor < p.text.count {
        ch := p.text[p.cursor];
        p.cursor += 1;
        if ch == #char "\"" {
            if !escaped || !decode {
                return json_slice(p.text, start, p.cursor - 1);
            }
            append(*builder, json_slice(p.text, segment, p.cursor - 1));
            result := builder_to_string(*builder);
            array_add(p.strings, result);
            return result;
        }
        if ch < #char " " {
            p.error = true;
            return "";
        }
        if ch >= 0x80 && !json_utf8_tail(p, ch) {
            p.error = true;
            return "";
        }
        if ch != #char "\\" {
            continue;
        }
        escaped = true;
        if decode {
            append(*builder, json_slice(p.text, segment, p.cursor - 1));
        }
        if p.cursor >= p.text.count {
            break;
        }
        escape := p.text[p.cursor];
        p.cursor += 1;
        codepoint: u32;
        if escape == #char "\"" || escape == #char "\\" || escape == #char "/" {
            codepoint = escape;
        }
        else if escape == #char "b" {
            codepoint = #char "\x08";
        }
        else if escape == #char "f" {
            codepoint = #char "\x0C";
        }
        else if escape == #char "n" {
            codepoint = #char "\n";
        }
        else if escape == #char "r" {
            codepoint = #char "\r";
        }
        else if escape == #char "t" {
            codepoint = #char "\t";
        }
        else if escape == #char "u" {
            codepoint = json_hex_quad(p);
            if codepoint >= 0xD800 && codepoint <= 0xDBFF {
                if (p.cursor + 2 > p.text.count || p.text[p.cursor] != #char "\\" ||
                    p.text[p.cursor + 1] != #char "u") {
                    p.error = true;
                    return "";
                }
                p.cursor += 2;
                low := json_hex_quad(p);
                if low < 0xDC00 || low > 0xDFFF {
                    p.error = true;
                    return "";
                }
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + low - 0xDC00;
            }
            else if codepoint >= 0xDC00 && codepoint <= 0xDFFF {
                p.error = true;
            }
        } else {
            p.error = true;
        }
        if p.error {
            return "";
        }
        if decode {
            json_append_codepoint(*builder, codepoint);
        }
        segment = p.cursor;
    }
    p.error = true;
    return "";
}

json_digit :: (ch: u8) -> bool {
    return ch >= #char "0" && ch <= #char "9";
}

json_number_token :: (p: *JsonParser) -> string {
    json_space(p);
    start := p.cursor;
    if p.cursor < p.text.count && p.text[p.cursor] == #char "-" {
        p.cursor += 1;
    }
    if p.cursor >= p.text.count {
        p.error = true;
        return "";
    }
    if p.text[p.cursor] == #char "0" {
        p.cursor += 1;
    } else {
        digits := p.cursor;
        while p.cursor < p.text.count && json_digit(p.text[p.cursor]) {
            p.cursor += 1;
        }
        if p.cursor == digits {
            p.error = true;
            return "";
        }
    }
    if p.cursor < p.text.count && p.text[p.cursor] == #char "." {
        p.cursor += 1;
        digits := p.cursor;
        while p.cursor < p.text.count && json_digit(p.text[p.cursor]) {
            p.cursor += 1;
        }
        if p.cursor == digits {
            p.error = true;
            return "";
        }
    }
    if p.cursor < p.text.count && (p.text[p.cursor] == #char "e" || p.text[p.cursor] == #char "E") {
        p.cursor += 1;
        if p.cursor < p.text.count && (p.text[p.cursor] == #char "+" || p.text[p.cursor] == #char "-") {
            p.cursor += 1;
        }
        digits := p.cursor;
        while p.cursor < p.text.count && json_digit(p.text[p.cursor]) {
            p.cursor += 1;
        }
        if p.cursor == digits {
            p.error = true;
            return "";
        }
    }
    return json_slice(p.text, start, p.cursor);
}

json_literal :: (p: *JsonParser, value: string) -> bool {
    json_space(p);
    if p.error || p.cursor + value.count > p.text.count {
        return false;
    }
    if json_slice(p.text, p.cursor, p.cursor + value.count) != value {
        return false;
    }
    p.cursor += value.count;
    return true;
}

json_skip_value :: (p: *JsonParser, depth: int) {
    json_space(p);
    if p.error || depth > JSON_MAX_DEPTH || p.cursor >= p.text.count {
        p.error = true;
        return;
    }
    ch := p.text[p.cursor];
    if ch == #char "{" || ch == #char "[" {
        object := ch == #char "{";
        end := cast(u8)(ifx object then #char "}" else #char "]");
        p.cursor += 1;
        if json_consume(p, end) {
            return;
        }
        while !p.error {
            if object {
                json_quoted(p, false);
                if !json_take(p, #char ":") {
                    return;
                }
            }
            json_skip_value(p, depth + 1);
            if json_consume(p, end) {
                return;
            }
            if !json_take(p, #char ",") {
                return;
            }
        }
    }
    else if ch == #char "\"" {
        json_quoted(p, false);
    }
    else if ch == #char "t" {
        p.error = !json_literal(p, "true");
    }
    else if ch == #char "f" {
        p.error = !json_literal(p, "false");
    }
    else if ch == #char "n" {
        p.error = !json_literal(p, "null");
    } else {
        json_number_token(p);
    }
}

// Decimal/exponent normalization keeps all 64 integer bits, including u64's upper half.
json_integer_magnitude :: (text: string) -> (magnitude: u64, negative: bool, valid: bool) {
    cursor: int;
    negative := text[0] == #char "-";
    if negative {
        cursor += 1;
    }
    first_digit := cursor;
    digits, fractional_digits, trailing_zeros: int;
    fraction: bool;
    nonzero: bool;
    while cursor < text.count && text[cursor] != #char "e" && text[cursor] != #char "E" {
        ch := text[cursor];
        cursor += 1;
        if ch == #char "." {
            fraction = true;
            continue;
        }
        digits += 1;
        if fraction {
            fractional_digits += 1;
        }
        if ch == #char "0" {
            trailing_zeros += 1;
        } else {
            trailing_zeros = 0;
            nonzero = true;
        }
    }
    if !nonzero {
        return 0, negative, true;
    }
    exponent: int;
    if cursor < text.count {
        cursor += 1;
        exponent_negative := text[cursor] == #char "-";
        if exponent_negative || text[cursor] == #char "+" {
            cursor += 1;
        }
        while cursor < text.count {
            if exponent > text.count + 64 {
                return 0, negative, false;
            }
            exponent = exponent * 10 + cast(int)(text[cursor] - #char "0");
            cursor += 1;
        }
        if exponent_negative {
            exponent = -exponent;
        }
    }
    shift := exponent - fractional_digits;
    removed := ifx shift < 0 then -shift else 0;
    if removed > trailing_zeros {
        return 0, negative, false;
    }
    remaining := digits - removed;
    cursor = first_digit;
    magnitude: u64;
    for index: 0..remaining - 1 {
        if text[cursor] == #char "." {
            cursor += 1;
        }
        digit := cast(u64)(text[cursor] - #char "0");
        cursor += 1;
        if magnitude > (JsonMath.U64_MAX - digit) / 10 {
            return 0, negative, false;
        }
        magnitude = magnitude * 10 + digit;
    }
    while shift > 0 {
        if magnitude > JsonMath.U64_MAX / 10 {
            return 0, negative, false;
        }
        magnitude *= 10;
        shift -= 1;
    }
    return magnitude, negative, true;
}

json_read_value :: (p: *JsonParser, info: *Type_Info, dest: *u8, depth: int, structures: []Reflection.Struct_Metadata) {
    if p.error || depth > JSON_MAX_DEPTH {
        p.error = true;
        return;
    }
    if info == type_info(JsonMath.Color) {
        hex := json_quoted(p);
        if (hex.count != 7 && hex.count != 9) || !JsonMath.is_valid_hex_color(json_slice(hex, 0, 7)) {
            p.error = true;
            return;
        }
        color := JsonMath.color_from_hex(json_slice(hex, 0, 7));
        if hex.count == 9 {
            alpha := json_slice(hex, 7, 9);
            for ch: alpha {
                if !((ch >= #char "0" && ch <= #char "9") || (ch >= #char "A" && ch <= #char "F") ||
                     (ch >= #char "a" && ch <= #char "f")) {
                    p.error = true;
                    return;
                }
            }
            color.a = JsonMath.int_from_hex_char_for_colors(alpha[0]) * 16 + JsonMath.int_from_hex_char_for_colors(alpha[1]);
        }
        (cast(*JsonMath.Color)dest).* = color;
        return;
    }
    if info == type_info(JsonMath.Vec4) {
        json_space(p);
        if p.cursor < p.text.count && p.text[p.cursor] == #char "\"" {
            hex := json_quoted(p);
            if !JsonMath.is_valid_hex_color(hex) {
                p.error = true;
                return;
            }
            (cast(*JsonMath.Vec4)dest).* = JsonMath.linear_from_hex(hex);
            return;
        }
        json_read_value(p, type_info([4]float), dest, depth + 1, structures);
        return;
    }
    for codec: p.codecs {
        if cast(*Type_Info)codec.value_type == info {
            codec.read(p, dest, depth, structures);
            return;
        }
    }
    if info.type == .STRING {
        (cast(*string)dest).* = json_quoted(p);
    }
    else if info.type == .STRUCT {
        if !json_take(p, #char "{") {
            return;
        }
        structure := cast(*Type_Info_Struct)info;
        // Overlapping storage cannot retain independent config fields or inactive modes.
        // Applications with a dedicated representation can provide a custom decoder.
        if structure.textual_flags & .UNION {
            p.error = true;
            return;
        }
        for member: structure.members {
            if member.flags & .OVERLAY {
                p.error = true;
                return;
            }
        }
        seen: [..]int;
        defer array_free(seen);
        if json_consume(p, #char "}") {
            return;
        }
        while !p.error {
            key := json_quoted(p);
            if !json_take(p, #char ":") {
                return;
            }
            found := false;
            for field, index: Reflection.struct_fields(structures, info) {
                if !field.is_serialized || field.name != key {
                    continue;
                }
                for previous: seen {
                    if previous == index {
                        p.error = true;
                        return;
                    }
                }
                array_add(*seen, index);
                json_read_value(p, cast(*Type_Info)field.member_type, dest + field.offset, depth + 1, structures);
                found = true;
                break;
            }
            if !found {
                p.error = true;
                return;
            }
            if json_consume(p, #char "}") {
                return;
            }
            if !json_take(p, #char ",") {
                return;
            }
        }
    }
    else if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        if array.array_type != .FIXED || !json_take(p, #char "[") {
            p.error = true;
            return;
        }
        for index: 0..array.array_count - 1 {
            if index > 0 && !json_take(p, #char ",") {
                return;
            }
            json_read_value(p, array.element_type, dest + index * array.element_type.runtime_size, depth + 1, structures);
        }
        json_take(p, #char "]");
    }
    else if info.type == .ENUM {
        value := json_quoted(p);
        enumeration := cast(*Type_Info_Enum)info;
        for name, index: enumeration.names {
            if name == value {
                number := enumeration.values[index];
                memcpy(dest, *number, info.runtime_size);
                return;
            }
        }
        p.error = true;
    }
    else if info.type == .BOOL {
        if json_literal(p, "true") {
            (cast(*bool)dest).* = true;
        }
        else if json_literal(p, "false") {
            (cast(*bool)dest).* = false;
        } else {
            p.error = true;
        }
    }
    else if info.type == .INTEGER {
        token := json_number_token(p);
        if p.error {
            return;
        }
        magnitude, negative, valid := json_integer_magnitude(token);
        integer := cast(*Type_Info_Integer)info;
        bits := info.runtime_size * 8;
        if bits < 1 || bits > 64 {
            p.error = true;
            return;
        }
        limit := JsonMath.U64_MAX;
        if integer.signed {
            limit = (cast(u64)1) << (bits - 1);
            if !negative {
                limit -= 1;
            }
        }
        else if bits < 64 {
            limit = ((cast(u64)1) << bits) - 1;
        }
        if !valid || magnitude > limit || (negative && magnitude != 0 && !integer.signed) {
            p.error = true;
            return;
        }
        representation := magnitude;
        if negative && magnitude != 0 {
            representation = (~magnitude) + 1;
        }
        memcpy(dest, *representation, info.runtime_size);
    }
    else if info.type == .FLOAT {
        token := json_number_token(p);
        if p.error {
            return;
        }
        value, valid, rest := string_to_float64(token);
        if !valid || rest.count != 0 || !JsonMath.is_finite(value) {
            p.error = true;
            return;
        }
        if info.runtime_size == size_of(float64) {
            (cast(*float64)dest).* = value;
        }
        else if info.runtime_size == size_of(float32) && JsonMath.is_finite(cast(float32)value) {
            (cast(*float32)dest).* = cast(float32)value;
        } else {
            p.error = true;
        }
    } else {
        p.error = true;
    }
}

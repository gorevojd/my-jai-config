// Typed JSON config sets with transactional reloads. No platform or game dependencies.
#scope_file

#import "Basic";
Files :: #import "File";
Tables :: #import "Hash_Table";
using,only(for_expansion) Tables;
Events :: #import "MyEvents";
#load "json.jai";
#load "json_write.jai";
#load "file_write.jai";

#scope_export

ConfigEventType :: enum {
    Loaded;
    Reloaded;
    Error;
}

// Opaque modification token: only equality is used, so clocks may move backwards.
ConfigManagerTime :: s64;
Config_Read_Callback :: #type (path: string) -> (text: string, success: bool);
Config_Write_Callback :: #type (path: string, text: string) -> bool;
Config_Time_Callback :: #type (path: string) -> (time: ConfigManagerTime, success: bool);

ConfigManager :: struct {
    configs: [..]*ConfigRegistration;

    // Defaults to the allocator active at first registration. Keep it alive through shutdown.
    allocator: Allocator;

    // The reader transfers ownership of its string, allocated with the active manager allocator.
    read_config_callback: Config_Read_Callback = read_config_file;

    // Borrows text for the call. A failed write must leave the destination unchanged.
    write_config_callback: Config_Write_Callback = write_config_file;

    // Without a time callback, loading is explicit; polling does no work.
    get_last_config_change_time_callback: Config_Time_Callback;

    config_changed: Events.Event(Type, ConfigEventType);
    busy: bool;
}

// Each type is registered once. Parsers receive an inner JSON value initialized to T's defaults.
// Custom parsers may borrow strings from text, but must not retain temporary allocations.
// Set legacy_single_value only at a compatibility boundary for old unkeyed JSON files.
// watch enables polling; writer overrides the value encoder; writable permits saves/default initialization.
register_config :: (manager: *ConfigManager,
                    $T: Type,
                    path: string,
                    parser: #type (text: string, dest: *T) -> bool = null,
                    watch: bool = true,
                    legacy_single_value: bool = false,
                    required_key: string = "",
                    writer: #type (builder: *String_Builder, value: *T, depth: int) -> bool = null,
                    writable: bool = true) -> bool
{
    if manager.busy || path.count == 0 || is_config_registered(manager, T) {
        return false;
    }

    if !manager.allocator.proc {
        manager.allocator = context.allocator;
    }

    push_allocator(manager.allocator);
    registration := New(TypedConfig(T));
    registration.base.config_type = T;
    registration.base.path = sprint("%", path);
    registration.base.required_key = sprint("%", required_key);
    registration.base.watch = watch;
    registration.base.writable = writable;
    registration.base.legacy_single_value = legacy_single_value;
    registration.base.populate = TypedConfig(T).populate;
    registration.base.release = TypedConfig(T).release;
    registration.parser = parser;
    registration.writer = writer;
    array_add(*manager.configs, *registration.base);
    return true;
}

is_config_registered :: (manager: *ConfigManager, $T: Type) -> bool {
    return find_registration(manager, T) != null;
}

// Results and borrowed strings remain valid until this type successfully reloads or shutdown.
// A failed reload preserves values and addresses. Missing keys/types return null.
get_config :: (manager: *ConfigManager, $T: Type, key: string = "default") -> *T {
    values := get_configs(manager, T);
    if !values {
        return null;
    }
    return Tables.table_find_pointer(values, key);
}

// For iteration and value editing. Do not add/remove entries or free this manager-owned table.
get_configs :: (manager: *ConfigManager, $T: Type) -> *Tables.Table(string, T) {
    base := find_registration(manager, T);
    if !base {
        return null;
    }
    registration := cast(*TypedConfig(T))base;
    return *registration.storage.values;
}

// Original inner JSON, including comments, with the same lifetime as get_config's result.
get_config_source :: (manager: *ConfigManager, $T: Type, key: string = "default") -> string {
    base := find_registration(manager, T);
    if !base {
        return "";
    }
    registration := cast(*TypedConfig(T))base;
    source := Tables.table_find_pointer(*registration.storage.sources, key);
    if !source {
        return "";
    }
    return source.*;
}

// Insert or replace one key, preserving all other current entries. An unloaded registration starts
// with an empty map. Saving publishes manager-owned copies only after validation and writing succeed.
save_config :: (manager: *ConfigManager, $T: Type, key: string, value: T) -> bool {
    return save_config_entries(manager, T, key, *value);
}

// Persist the complete current map, including edits made through get_config/get_configs.
save_config :: (manager: *ConfigManager, $T: Type) -> bool {
    return save_config_entries(manager, T, "", null);
}

load_configs :: (manager: *ConfigManager) -> bool {
    if manager.busy {
        return false;
    }
    manager.busy = true;
    defer manager.busy = false;
    allocator := ifx manager.allocator.proc then manager.allocator else context.allocator;
    push_allocator(allocator);
    success := true;
    for registration: manager.configs {
        observe_config(manager, registration);
        if !load_registration(manager, registration) {
            success = false;
        }
    }
    return success;
}

reload_config :: (manager: *ConfigManager, $T: Type) -> bool {
    if manager.busy {
        return false;
    }
    registration := find_registration(manager, T);
    if !registration {
        return false;
    }
    manager.busy = true;
    defer manager.busy = false;
    push_allocator(manager.allocator);
    observe_config(manager, registration);
    return load_registration(manager, registration);
}

// Returns successful loads/reloads. Failed versions and unavailable files emit Error once per
// observed change. Explicit reload_config/load_configs can retry immediately.
check_and_perform_config_reloads :: (manager: *ConfigManager) -> int {
    if manager.busy || !manager.get_last_config_change_time_callback {
        return 0;
    }
    manager.busy = true;
    defer manager.busy = false;
    allocator := ifx manager.allocator.proc then manager.allocator else context.allocator;
    push_allocator(allocator);
    reloaded: int;
    for registration: manager.configs {
        if !registration.watch {
            continue;
        }
        stamp, available := manager.get_last_config_change_time_callback(registration.path);
        changed := (!registration.observed || available != registration.observed_available ||
                    (available && stamp != registration.observed_time));
        if !changed {
            continue;
        }
        registration.observed = true;
        registration.observed_available = available;
        registration.observed_time = stamp;
        if !available {
            report_error(manager, registration, "could not query modification time");
            continue;
        }
        if load_registration(manager, registration, true) {
            reloaded += 1;
        }
    }
    return reloaded;
}

// Single-threaded; do not copy a live manager. Mutation, reload and shutdown from a config
// callback are rejected. Lookup and event subscription changes are allowed during dispatch.
shutdown :: (manager: *ConfigManager) {
    if manager.busy {
        return;
    }
    allocator := ifx manager.allocator.proc then manager.allocator else context.allocator;
    push_allocator(allocator);
    for registration: manager.configs {
        registration.release(registration);
    }
    array_free(manager.configs);
    Events.destroy(*manager.config_changed);
    next_subscription_id := manager.config_changed.next_id;
    manager.* = .{};
    manager.config_changed.next_id = next_subscription_id;
}

#scope_file

ConfigRegistration :: struct {
    config_type: Type;
    path: string;
    required_key: string;
    watch: bool;
    writable: bool;
    legacy_single_value: bool;
    loaded: bool;
    // Borrows the current storage. A save is verified on the next poll without rebroadcasting identical bytes.
    loaded_source: string;
    verify_saved_source: bool;
    observed: bool;
    observed_available: bool;
    observed_time: ConfigManagerTime;
    populate: #type (manager: *ConfigManager, registration: *ConfigRegistration, owned_text: string) -> bool;
    release: #type (registration: *ConfigRegistration);
}

ConfigStorage :: struct (T: Type) {
    values: Tables.Table(string, T);
    sources: Tables.Table(string, string);
    source: string;
    strings: [..]string;
    needs_defaults_saved: bool;
}

TypedConfig :: struct (T: Type) {
    // Must be first: erased registrations are cast back to their concrete typed storage.
    base: ConfigRegistration;
    parser: #type (text: string, dest: *T) -> bool;
    writer: #type (builder: *String_Builder, value: *T, depth: int) -> bool;
    storage: ConfigStorage(T);

    populate :: (manager: *ConfigManager, base: *ConfigRegistration, owned_text: string) -> bool {
        registration := cast(*TypedConfig(T))base;
        candidate: ConfigStorage(T);
        if base.writable && json_is_empty_config(owned_text) {
            free(owned_text);
            value := New(T);
            defer free(value);
            key := ifx base.required_key.count > 0 then base.required_key else "default";
            inline Tables.table_add(*candidate.values, key, value.*);
            candidate.needs_defaults_saved = true;
        } else if !decode_storage(registration, *candidate, owned_text, base.legacy_single_value) {
            report_error(manager, base, "invalid JSON, config value, duplicate key or missing required key");
            return false;
        }
        if base.writable && candidate.needs_defaults_saved {
            defer release_storage(*candidate);
            return save_config_storage(manager, registration, *candidate, "", null);
        }
        release_storage(*registration.storage);
        registration.storage = candidate;
        base.loaded_source = registration.storage.source;
        base.verify_saved_source = false;
        return true;
    }

    release :: (base: *ConfigRegistration) {
        registration := cast(*TypedConfig(T))base;
        release_storage(*registration.storage);
        free(base.path);
        free(base.required_key);
        free(registration);
    }
}

// Consumes owned_text on either result. On success the caller owns candidate until publication.
decode_storage :: (registration: *TypedConfig($T), candidate: *ConfigStorage(T), owned_text: string, allow_legacy: bool) -> bool {
    base := *registration.base;
    candidate.source = owned_text;
    entries: [..]JsonEntry;
    defer array_free(entries);
    // Some configs contain large inline arrays; keep the reusable decode value off the stack.
    value := New(T);
    defer free(value);
    success := json_split_configs(owned_text, *entries, *candidate.strings);
    if success {
        for entry: entries {
            if Tables.table_contains(*candidate.values, entry.key) {
                success = false;
                break;
            }
            Initialize(value);
            if registration.parser {
                success = registration.parser(entry.value, value);
            } else {
                success = json_decode(entry.value, T, value, *candidate.strings);
            }
            if !success {
                break;
            }
            inline Tables.table_add(*candidate.values, entry.key, value.*);
            Tables.table_add(*candidate.sources, entry.key, entry.value);
            if json_is_empty_config(entry.value) {
                candidate.needs_defaults_saved = true;
            }
        }
    }
    if success && base.required_key.count > 0 {
        success = Tables.table_contains(*candidate.values, base.required_key);
    }
    if !success && allow_legacy {
        candidate.source = "";
        release_storage(candidate);
        candidate.* = .{};
        candidate.source = owned_text;
        Initialize(value);
        if registration.parser {
            success = registration.parser(owned_text, value);
        } else {
            success = json_decode(owned_text, T, value, *candidate.strings);
        }
        if success {
            inline Tables.table_add(*candidate.values, "default", value.*);
            Tables.table_add(*candidate.sources, "default", owned_text);
        }
    }
    if success && base.required_key.count > 0 {
        success = Tables.table_contains(*candidate.values, base.required_key);
    }
    if !success {
        release_storage(candidate);
        return false;
    }
    return true;
}

save_config_entries :: (manager: *ConfigManager, $T: Type, replacement_key: string, replacement: *T) -> bool {
    if manager.busy {
        return false;
    }
    base := find_registration(manager, T);
    if !base {
        return false;
    }
    manager.busy = true;
    defer manager.busy = false;
    push_allocator(manager.allocator);
    registration := cast(*TypedConfig(T))base;
    if !save_config_storage(manager, registration, *registration.storage, replacement_key, replacement) {
        return false;
    }
    report_success(manager, base);
    return true;
}

// Load initialization and explicit saves share validation, atomic writing and publication.
save_config_storage :: (manager: *ConfigManager,
                        registration: *TypedConfig($T),
                        storage: *ConfigStorage(T),
                        replacement_key: string,
                        replacement: *T) -> bool
{
    base := *registration.base;
    if !base.writable {
        report_error(manager, base, "registration is read-only");
        return false;
    }
    if !manager.write_config_callback {
        report_error(manager, base, "no config writer supplied");
        return false;
    }
    builder: String_Builder;
    defer free_buffers(*builder);
    append(*builder, "{\n");
    remaining := storage.values.count;
    replacing_existing := replacement != null && Tables.table_contains(*storage.values, replacement_key);
    if replacement && !replacing_existing {
        remaining += 1;
    }
    for *value, key: storage.values {
        selected := value;
        if replacement && key == replacement_key {
            selected = replacement;
        }
        remaining -= 1;
        if !write_config_entry(registration, *builder, key, selected, remaining > 0) {
            report_error(manager, base, "could not serialize config value");
            return false;
        }
    }
    if replacement && !replacing_existing {
        if !write_config_entry(registration, *builder, replacement_key, replacement, false) {
            report_error(manager, base, "could not serialize config value");
            return false;
        }
    }
    append(*builder, "}\n");

    // Build the document once, then validate it once to establish owned keys/strings and domain checks.
    text := builder_to_string(*builder);
    candidate: ConfigStorage(T);
    if !decode_storage(registration, *candidate, text, false) {
        report_error(manager, base, "serialized config failed validation");
        return false;
    }

    if !manager.write_config_callback(base.path, candidate.source) {
        release_storage(*candidate);
        report_error(manager, base, "could not write file");
        return false;
    }

    release_storage(*registration.storage);
    registration.storage = candidate;
    base.loaded_source = candidate.source;

    // Do not associate a post-write timestamp with our bytes: another writer could have already
    // replaced them. The next poll samples before reading and suppresses only an exact byte match.
    base.observed = false;
    base.verify_saved_source = true;

    return true;
}

write_config_entry :: (registration: *TypedConfig($T),
                       builder: *String_Builder,
                       key: string,
                       value: *T,
                       trailing_comma: bool) -> bool
{
    append(builder, "  ");
    if !json_write_string(builder, key) {
        return false;
    }
    append(builder, ": ");
    if registration.writer {
        if !registration.writer(builder, value, 1) {
            return false;
        }
    } else if !json_write_value(builder, T, value, 1) {
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

release_storage :: (storage: *ConfigStorage($T)) {
    Tables.deinit(*storage.values);
    Tables.deinit(*storage.sources);
    for text: storage.strings {
        free(text);
    }
    array_free(storage.strings);
    free(storage.source);
}

find_registration :: (manager: *ConfigManager, config_type: Type) -> *ConfigRegistration {
    for registration: manager.configs {
        if registration.config_type == config_type {
            return registration;
        }
    }
    return null;
}

read_config_file :: (path: string) -> string, bool {
    text, success := Files.read_entire_file(path, false, false);
    return text, success;
}

observe_config :: (manager: *ConfigManager, registration: *ConfigRegistration) {
    if registration.watch && manager.get_last_config_change_time_callback {
        stamp, available := manager.get_last_config_change_time_callback(registration.path);
        registration.observed = true;
        registration.observed_available = available;
        registration.observed_time = stamp;
    }
}

load_registration :: (manager: *ConfigManager, registration: *ConfigRegistration, verify_saved_source: bool = false) -> bool {
    if !manager.read_config_callback {
        report_error(manager, registration, "no config reader supplied");
        return false;
    }

    text, read_ok := manager.read_config_callback(registration.path);
    if !read_ok {
        free(text);
        report_error(manager, registration, "could not read file");
        return false;
    }

    if verify_saved_source && registration.verify_saved_source {
        registration.verify_saved_source = false;
        if text == registration.loaded_source {
            free(text);
            return false;
        }
    }
    
    if !registration.populate(manager, registration, text) {
        return false;
    }

    report_success(manager, registration);
    return true;
}

report_success :: (manager: *ConfigManager, registration: *ConfigRegistration) {
    event_type := ifx registration.loaded then ConfigEventType.Reloaded else ConfigEventType.Loaded;
    registration.loaded = true;
    Events.broadcast(*manager.config_changed, registration.config_type, event_type);
}

report_error :: (manager: *ConfigManager, registration: *ConfigRegistration, message: string) {
    // Recovery must emit success even when the recovered bytes equal our preceding save.
    registration.verify_saved_source = false;
    print("Config % (%): %. Keeping the last valid values.\n", registration.config_type, registration.path, message);
    Events.broadcast(*manager.config_changed, registration.config_type, ConfigEventType.Error);
}

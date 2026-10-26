# MyConfig

`MyConfig` manages typed sets of JSON configs. It depends on `MyEvents`, `MyMath`, `MyReflection`,
and Jai's `Basic`, `File`, and `Hash_Table` modules. It has no SDL or game dependency.

Each file is an object whose keys identify complete values of one registered type:

```json
{
  "default": { "speed": 2.5, "name": "Normal" },
  "fast": { "speed": 5.0, "name": "Fast" }
}
```

Every value starts from its Jai type's defaults before decoding. An omitted field
keeps its default. The entire file must parse and validate before it replaces the
previous map. Duplicate keys, invalid values, and missing required keys leave the
old map and its addresses intact. JSON line/block comments are supported.

## Usage

This program loads `movement.json`, looks up two entries, and shows event delivery.
Provide the JSON above beside the program's working directory.

```jai
#import "Basic";
C :: #import "MyConfig";
E :: #import "MyEvents";

Movement :: struct @ReflectStruct {
    speed: float = 1.0;
    name: string = "Untitled";
}

on_config_changed :: (config_type: Type, event_type: C.ConfigEventType) {
    print("%: %\n", config_type, event_type);
}

main :: () {
    manager: C.ConfigManager;
    defer C.shutdown(*manager);
    subscription := E.subscribe(*manager.config_changed, on_config_changed);
    assert(C.register_config(*manager, Movement, "movement.json", required_key = "default"));
    if C.load_configs(*manager) {
        normal := C.get_config(*manager, Movement);
        fast := C.get_config(*manager, Movement, "fast");
        print("Normal: %\n", normal.speed);
        if fast {
            print("Fast: %\n", fast.speed);
        }
    }
    E.unsubscribe(*manager.config_changed, subscription);
}
```

## API

The public types are `ConfigManager`, `ConfigEventType`, `ConfigManagerTime`, the
three callback signatures, and `JsonEntry` for custom JSON adapters. Registration
records, typed storage, dependency imports and implementation helpers are internal.

- `register_config(*manager, T, path, parser = null, watch = true,
  legacy_single_value = false, required_key = "", writer = null,
  writable = true) -> bool` registers one file for
  type `T`. A second registration of the same type fails. The manager copies the
  path and required key. Registration does not read the file.
  `watch` enables change-token polling (when the manager has a time callback);
  `writer` optionally replaces the reflected value encoder; `writable` permits
  explicit saves and automatic default initialization of empty configs.
- `is_config_registered(*manager, T) -> bool` checks registration, even before loading.
- `load_configs(*manager) -> bool` attempts every registered file. Each type commits
  independently; the result is true only if every load succeeds.
- `reload_config(*manager, T) -> bool` immediately retries one registered type,
  regardless of whether its modification token changed.
- `get_config(*manager, T, key = "default") -> *T` returns the typed value or null.
  An omitted lookup key means `"default"`; it does not synthesize a missing entry.
- `get_configs(*manager, T) -> *Hash_Table.Table(string, T)` exposes the table for
  iteration and editing existing values. Unregistered types return null. The table
  is manager-owned: do not add/remove entries, resize it, or free it.
- `get_config_source(*manager, T, key = "default") -> string` returns the original
  inner JSON for an entry, including its internal comments, or an empty string.
- `save_config(*manager, T, key, value) -> bool` inserts or replaces one entry and
  persists the full map, preserving all other current entries.
- `save_config(*manager, T) -> bool` persists every current entry, including edits
  made through `get_config` or `get_configs`.
- `check_and_perform_config_reloads(*manager) -> int` polls watched registrations
  and returns the number of successful loads/reloads.
- `shutdown(*manager)` frees all registrations, values, source text, decoded strings,
  and subscriptions. Calling it again is safe.

`legacy_single_value = true` additionally accepts an unkeyed value as `"default"`
when keyed decoding fails. This is an explicit migration option, not the normal
format. `required_key = "default"` makes that entry mandatory.

## Field serialization

Put `@ReflectStruct` after `struct` to generate reflection and include its
nonconstant fields by default. `@NonSerializeField` excludes a field entirely,
even if it also has `@SerializeField`. `@SerializeField` is optional and does not
enable reflection for an unmarked struct. Unmarked types have no reflected fields.
Omitting `@SerializeFieldsByDefault` means true, as do the bare marker and `=true`.
Use `@SerializeFieldsByDefault=false` to require explicit `@SerializeField` notes.
These choices are precomputed by reflection independently of JSON.

```jai
Movement :: struct @ReflectStruct {
    speed: float = 1.0; @SerializeField
    cached_distance: float; @NonSerializeField
}

Preferences :: struct @ReflectStruct {
    volume: float = 0.8;
    session_id: int; @NonSerializeField
    movement: Movement;
}
```

The struct note belongs before the opening brace. Field notes belong on the same
line as the field declaration and can accompany editor metadata. Each nested struct
uses its own policy, including array elements; a parent's policy does not propagate.
The shared reader and writer use the same field selection. Excluded fields retain
their Jai defaults when decoded, and supplying an excluded field in JSON fails
validation, like supplying an unknown field. Unsupported runtime-only fields such
as pointers can be left excluded. Custom parsers/writers must apply the policy
themselves. `MyReflection.collect_structs(type_info(T))` bakes the selected field
descriptors and serialization flags at compile time. JSON reads/writes iterate
those descriptors; they do not rescan annotations. The annotations belong to
reflection, and JSON is one consumer.

The other public adapter helpers are `json_split_configs`, `json_decode`,
`json_write_value`, `json_write_string`, `json_write_key_value`,
`json_write_enum_options` and `write_config_file`. Parsing and reflected traversal
details are internal.

## Empty configs

Loading a writable blank, whitespace/comment-only file or empty root object creates
one initialized `T`, under `required_key` when set, otherwise `"default"`. Empty
named objects such as `{"default": {}}` are also saved with their initialized fields,
preserving other named entries. Default initialization uses the normal encoder,
validation and atomic write callback before publishing values. Failure leaves the
previous snapshot intact and emits one `Error`; success emits one `Loaded` or
`Reloaded`, and polling suppresses the manager's own write as usual.

Read-only registrations are never rewritten and keep their normal decoding rules:
an empty keyed object is an empty map without `required_key`, or can decode as a
legacy default with `legacy_single_value`. Missing files and malformed JSON are
errors, not empty configs. Nonempty partial configs retain omitted defaults in
memory without automatically rewriting their source.

## Decoding and ownership

The default decoder supports ordinary structs, fixed arrays, strings, named enums,
booleans, integers up to 64 bits, and finite 32/64-bit floats. It validates JSON
escapes, Unicode surrogate pairs, and UTF-8. It rejects unknown/duplicate fields,
unions, overlay members, dynamic arrays, pointers, and unsupported field types when
decoding them. Defaults for omitted fields are retained. Integer conversion is exact;
fractional values cannot silently truncate into integers. Float overflow is rejected.

A custom `parser: (text: string, dest: *T) -> bool` receives one raw inner JSON value
and a destination initialized to `T`'s defaults. It should parse and validate all
application constraints, returning false on failure. It may store slices borrowed
from `text`, since the manager keeps that source alive. It must not allocate nested
owned resources: there is no per-value destructor. Use inline storage or borrowed
strings, and keep outside resources under application ownership.

The manager owns the storage behind returned pointers and strings. They stay valid
until a **successful reload of that type** or shutdown. A failed reload leaves them
valid. Successful saves also replace owned storage and invalidate old pointers.
Retrieve pointers again after successful events; copying a struct containing
borrowed strings does not extend those strings' lifetime. Editing an existing value
does not change `get_config_source`, which represents its last loaded JSON.

`manager.allocator` may be supplied before registration. Otherwise the first
registration captures the current allocator. Reads, parsing, commits, and shutdown
use that allocator even if the caller's allocator later changes. Keep its backing
storage alive until shutdown. A custom reader must allocate its returned string
with the active allocator; the manager takes ownership, including on read failure.

## Saving

Both save overloads construct the complete JSON document in one pass, then decode
that candidate once to validate every value and establish ownership of keys and
strings. An unloaded registration starts with an empty map; save does not implicitly
read the old file. Load first if existing file entries should be preserved.
`required_key` also applies to saves, so a registration requiring `"default"` must
first save that key. The passed value has type `T`; its key and string fields may
borrow from the current manager snapshot.

```jai
assert(C.save_config(*manager, Movement, "fast", .{8.0, "Sprint"}));
C.get_config(*manager, Movement).speed = 3.0;
assert(C.save_config(*manager, Movement));
```

The default reflected writer supports the same types as the default decoder.
Enums include `// Options: ...` hints, with commas placed before comments. Keys and
strings are escaped, nonfinite floats fail, and float output retains round-trip
precision. Generated saves normalize formatting and regenerate enum hints;
arbitrary original comments are not automatically retained.

A custom `writer: (builder: *String_Builder, value: *T, depth: int) -> bool` writes
one JSON value. It must not append a root comma or line comment, since the manager
supplies those. It may implement custom colors, layouts, and metadata comments.
Returning false discards the attempt; the registered parser validates the completed
document before any disk write.

`manager.write_config_callback: (path: string, text: string) -> bool` borrows the
complete document for the call. Returning false must leave the external destination
unchanged. The default creates an exclusive temporary sibling file and atomically
replaces the destination after writing; failed attempts clean up their temporary
file. It never truncates the destination first. Power-loss durability depends on
the filesystem. Set `writable = false` for read-only sources; saves then fail before
invoking this callback.

Serialization, validation, and write failures emit `Error`, preserving current
values, source text, and pointers. Success publishes owned copies and emits `Loaded`
or `Reloaded`. The manager does not undo edits the caller already made through a
value pointer before saving.

## File access, polling, and events

`manager.read_config_callback` has type `(path: string) -> (string, bool)` and defaults
to `File.read_entire_file`. Replace it to read packed assets or other sources.
Register immutable sources with `watch = false`; explicit reloads remain available.

`manager.get_last_config_change_time_callback` has type
`(path: string) -> (ConfigManagerTime, bool)`, where `ConfigManagerTime` is `s64`.
The application can return an SDL modification timestamp, an asset revision, or
another change token. Only equality matters: a timestamp moving backwards also
triggers a reload. A false result means the source's change token is unavailable.
Without this callback, polling does no work; explicit loading still works.

Call polling at an application-appropriate interval. The manager records the token
before reading, so a subsequent edit during the read is detected by the next poll.
An invalid edit emits one error for that observed token and preserves old data.
An unavailable source emits one error on entering that state; recovery triggers a
retry even if the recovered timestamp equals the previous one. Unchanged failure
states do not repeatedly log or broadcast. Use `reload_config` to retry immediately
when a reader recovers without a token change. Equal tokens cannot detect different
bytes: choose a token with enough precision for the source.

After saving, the next poll verifies the source once. Identical bytes cause no
duplicate event, while an external edit made immediately after writing is loaded.
The timestamp is sampled before that verification read. Recovery after an error
always emits a success event, even when recovered bytes equal the preceding save.

`config_changed` is `MyEvents.Event(Type, ConfigEventType)`. It reports all three
results: `Loaded` on the first successful load, `Reloaded` on later
successful loads, and `Error` on a failed attempt. Errors print the registered type,
path, and failure category. Success callbacks run after the complete new map is
published; callbacks may look up the newly committed values.

Managers and events are single-threaded and must remain at stable addresses; do not
copy a live manager. Saving, reloading, registration, and shutdown attempted from a config
callback are rejected, preventing invalidation during dispatch. Lookup and event
subscription changes are allowed. `MyEvents` provides ordered dispatch, removable
subscription handles, and defined subscription changes during nested broadcasts;
see [its documentation](../MyEvents/readme.md).

The application supplies domain validation, custom formatting, and the policy for
which registrations may be written.

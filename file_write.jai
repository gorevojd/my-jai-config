// Complete a sibling temporary file before replacing the destination. Failed writes and
// replacement attempts remove only the temporary file created exclusively by this call.
// This protects the previous file from truncation; it does not promise power-loss durability
// for the directory entry on every filesystem.
#scope_file

#import "Basic";
Files :: #import "File";

#scope_export

write_config_file :: (path: string, text: string) -> bool {
    if path.count == 0 {
        return false;
    }
    for ch: path {
        if ch == 0 {
            return false;
        }
    }
    return write_config_file_atomic(path, text);
}

#scope_file

FileUtilities :: #import "File_Utilities";

#if OS == .WINDOWS {
    ConfigWindows :: #import "Windows";
    ConfigWindowsUtf8 :: #import "Windows_Utf8";
    CONFIG_TEMP_ATTEMPTS :: 64;
    CONFIG_WRITE_BLOCK_BYTES :: 1048576;
    WINDOWS_ERROR_FILE_EXISTS :: 80;

    write_config_file_atomic :: (path: string, text: string) -> bool {
        counter: s64;
        if !ConfigWindows.QueryPerformanceCounter(*counter) {
            return false;
        }
        process_id := ConfigWindows.GetCurrentProcessId();
        for attempt: 0..CONFIG_TEMP_ATTEMPTS - 1 {
            temporary_path := sprint("%.config_tmp_%_%_%", path, process_id, counter, attempt);
            defer free(temporary_path);
            wide_path, converted := ConfigWindowsUtf8.utf8_to_wide(temporary_path);
            if !converted {
                return false;
            }
            defer free(wide_path);
            handle := ConfigWindows.CreateFileW(wide_path,
                                                ConfigWindows.FILE_GENERIC_WRITE,
                                                0,
                                                creation = ConfigWindows.CREATE_NEW,
                                                flags_and_attributes = ConfigWindows.FILE_ATTRIBUTE_NORMAL);
            if handle == ConfigWindows.INVALID_HANDLE_VALUE {
                error := ConfigWindows.GetLastError();
                if error == WINDOWS_ERROR_FILE_EXISTS || error == ConfigWindows.ERROR_ALREADY_EXISTS {
                    continue;
                }
                return false;
            }
            closed: bool;
            committed: bool;
            defer {
                if !closed {
                    ConfigWindows.CloseHandle(handle);
                }
                if !committed {
                    Files.file_delete(temporary_path);
                }
            }
            written: int;
            while written < text.count {
                remaining := text.count - written;
                requested := cast(u32)(ifx remaining > CONFIG_WRITE_BLOCK_BYTES then CONFIG_WRITE_BLOCK_BYTES else remaining);
                amount: u32;
                success := ConfigWindows.WriteFile(handle, text.data + written, requested, *amount, null);
                if !success || amount == 0 {
                    return false;
                }
                written += amount;
            }
            if !ConfigWindows.FlushFileBuffers(handle) {
                return false;
            }
            closed = ConfigWindows.CloseHandle(handle) != 0;
            if !closed {
                return false;
            }
            committed = FileUtilities.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(temporary_path, path);
            return committed;
        }
        return false;
    }
} else #if OS_IS_UNIX {
    ConfigPosix :: #import "POSIX";

    write_config_file_atomic :: (path: string, text: string) -> bool {
        temporary_path := sprint("%.config_tmp_XXXXXX\0", path);
        defer free(temporary_path);
        descriptor := ConfigPosix.mkstemp(temporary_path.data);
        if descriptor < 0 {
            return false;
        }
        // mkstemp changes only the six X bytes; omit the explicit terminator from Jai's string.
        temporary_path.count -= 1;
        committed: bool;
        defer {
            if descriptor >= 0 {
                ConfigPosix.close(descriptor);
            }
            if !committed {
                Files.file_delete(temporary_path);
            }
        }
        written: int;
        while written < text.count {
            amount := ConfigPosix.write(descriptor, text.data + written, cast(u64)(text.count - written));
            if amount <= 0 {
                return false;
            }
            written += amount;
        }
        if ConfigPosix.fsync(descriptor) != 0 {
            return false;
        }
        closed := ConfigPosix.close(descriptor) == 0;
        descriptor = -1;
        if !closed {
            return false;
        }
        committed = FileUtilities.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(temporary_path, path);
        return committed;
    }
} else {
    // Supply a platform writer callback on targets without an exclusive temporary-file API.
    write_config_file_atomic :: (path: string, text: string) -> bool {
        assert(false, "TODO:");
        return false;
    }
}

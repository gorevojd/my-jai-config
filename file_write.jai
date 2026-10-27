// Complete a sibling temporary file before replacing the destination. Failed writes and
// replacement attempts remove only the temporary file created exclusively by this call.
// This protects the previous file from truncation; it does not promise power-loss durability
// for the directory entry on every filesystem.
#scope_file

#import "Basic";

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

#if OS == .WINDOWS {
    Files :: #import "File";
    FileUtilities :: #import "File_Utilities";
    Win32 :: #import "Windows";
    Win32UTF8 :: #import "Windows_Utf8";
    CONFIG_TEMP_ATTEMPTS :: 64;
    CONFIG_WRITE_BLOCK_BYTES :: 1048576;
    WINDOWS_ERROR_FILE_EXISTS :: 80;

    write_config_file_atomic :: (path: string, text: string) -> bool {
        counter: s64;
        if !Win32.QueryPerformanceCounter(*counter) {
            return false;
        }
        process_id := Win32.GetCurrentProcessId();
        for attempt: 0..CONFIG_TEMP_ATTEMPTS - 1 {
            temporary_path := sprint("%.config_tmp_%_%_%", path, process_id, counter, attempt);
            defer free(temporary_path);
            wide_path, converted := Win32UTF8.utf8_to_wide(temporary_path);
            if !converted {
                return false;
            }
            defer free(wide_path);
            handle := Win32.CreateFileW(wide_path,
                                                Win32.FILE_GENERIC_WRITE,
                                                0,
                                                creation = Win32.CREATE_NEW,
                                                flags_and_attributes = Win32.FILE_ATTRIBUTE_NORMAL);
            if handle == Win32.INVALID_HANDLE_VALUE {
                error := Win32.GetLastError();
                if error == WINDOWS_ERROR_FILE_EXISTS || error == Win32.ERROR_ALREADY_EXISTS {
                    continue;
                }
                return false;
            }
            closed: bool;
            committed: bool;
            defer {
                if !closed {
                    Win32.CloseHandle(handle);
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
                success := Win32.WriteFile(handle, text.data + written, requested, *amount, null);
                if !success || amount == 0 {
                    return false;
                }
                written += amount;
            }
            if !Win32.FlushFileBuffers(handle) {
                return false;
            }
            closed = Win32.CloseHandle(handle) != 0;
            if !closed {
                return false;
            }
            committed = FileUtilities.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(temporary_path, path);
            return committed;
        }
        return false;
    }
}
else #if OS == .LINUX || OS == .MACOS || OS == .ANDROID {
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
                ConfigPosix.unlink(temp_c_string(temporary_path));
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
        committed = ConfigPosix.rename(temp_c_string(temporary_path), temp_c_string(path)) == 0;
        return committed;
    }
}
else {
    // Supply a platform writer callback on targets without an exclusive temporary-file API.
    write_config_file_atomic :: (path: string, text: string) -> bool {
        print("MyConfig: safe file replacement is unsupported on %. Set manager.write_config_callback for '%'.\n", OS, path);
        return false;
    }
}

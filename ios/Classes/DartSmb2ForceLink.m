// Force the linker to keep all smb2w_* symbols from the static library.
// Dart FFI uses DynamicLibrary.process() on iOS, which looks up symbols at
// runtime. Without these references the linker strips them as "unused".

extern void *smb2w_connect;
extern void *smb2w_disconnect;
extern void *smb2w_error;
extern void *smb2w_get_last_error;
extern void *smb2w_listdir;
extern void *smb2w_dirlist_free;
extern void *smb2w_pread;
extern void *smb2w_read_file;
extern void *smb2w_free;
extern void *smb2w_open_file;
extern void *smb2w_open_file_with_size;
extern void *smb2w_pread_handle;
extern void *smb2w_close_file;
extern void *smb2w_list_shares;
extern void *smb2w_sharelist_free;
extern void *smb2w_stat;
extern void *smb2w_filesize;

__attribute__((used)) static void *_dart_smb2_force_link[] = {
    &smb2w_connect,
    &smb2w_disconnect,
    &smb2w_error,
    &smb2w_get_last_error,
    &smb2w_listdir,
    &smb2w_dirlist_free,
    &smb2w_pread,
    &smb2w_read_file,
    &smb2w_free,
    &smb2w_open_file,
    &smb2w_open_file_with_size,
    &smb2w_pread_handle,
    &smb2w_close_file,
    &smb2w_list_shares,
    &smb2w_sharelist_free,
    &smb2w_stat,
    &smb2w_filesize,
};

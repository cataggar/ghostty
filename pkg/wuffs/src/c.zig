pub const c = @cImport({
    @cInclude("stdint.h");
    @cUndef("SIZE_MAX");
    if (@sizeOf(usize) == 8) {
        @cDefine("SIZE_MAX", "18446744073709551615ULL");
    } else {
        @cDefine("SIZE_MAX", "4294967295U");
    }
    @cUndef("UINT64_MAX");
    @cDefine("UINT64_MAX", "18446744073709551615ULL");
    for (defines) |d| @cDefine(d, "1");
    @cInclude("wuffs-v0.4.c");
});

/// All the C macros defined so that the header matches the build.
pub const defines: []const []const u8 = &[_][]const u8{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__JPEG",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

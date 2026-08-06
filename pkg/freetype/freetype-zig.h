// Android NDK 29 stdlib.h uses _Nonnull on non-pointer types
// (unsigned short[3]) which Zig's C translator rejects. Neutralize
// the nullability macros before any system headers are pulled in.
#if defined(__ANDROID__)
#  undef _Nonnull
#  define _Nonnull
#  undef _Nullable
#  define _Nullable
#endif

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <freetype/ftmm.h>
#include <freetype/ftoutln.h>
#include <freetype/ftsnames.h>
#include <freetype/ttnameid.h>
#include <freetype/ftbitmap.h>
#include <freetype/ftbbox.h>

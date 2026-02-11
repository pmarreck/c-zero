/**
 * C0 - Hierarchical Binary Data Stream Format
 *
 * C FFI Header with Arena-Based Memory Management
 *
 * Usage:
 *   C0Arena* arena = c0_arena_new();
 *   C0Value* arr = c0_array(arena);
 *   c0_array_push(arr, c0_string(arena, "hello", 5));
 *
 *   size_t len;
 *   uint8_t* encoded = c0_encode(arena, arr, &len);
 *
 *   c0_arena_free(arena);  // Frees everything at once
 */

#ifndef C0_H
#define C0_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes */
typedef enum {
    C0_OK = 0,
    C0_ERR_NULL_ARG = 1,
    C0_ERR_OUT_OF_MEMORY = 2,
    C0_ERR_INVALID_TYPE = 3,
    C0_ERR_DECODE_FAILED = 4,
    C0_ERR_INDEX_OUT_OF_BOUNDS = 5,
    C0_ERR_CODEC_FAILED = 6,
    C0_ERR_UNKNOWN_CODEC = 7,
} C0Error;

/* Opaque types */
typedef struct C0Arena C0Arena;
typedef struct C0Value C0Value;

/* Codec info struct */
typedef struct {
    const char* name;
    size_t name_len;
    const char* description;
    size_t description_len;
    int supports_faithful;
    int supports_editable;
} C0CodecInfo;

/* Arena lifecycle */
C0Arena* c0_arena_new(void);
void c0_arena_free(C0Arena* arena);

/* Value constructors */
C0Value* c0_string(C0Arena* arena, const char* data, size_t len);
C0Value* c0_array(C0Arena* arena);
C0Value* c0_object(C0Arena* arena);

/* Array operations */
C0Error c0_array_push(C0Value* arr, C0Value* value);
size_t c0_array_len(const C0Value* arr);
C0Value* c0_array_get(const C0Value* arr, size_t index);

/* Object operations */
C0Error c0_object_set(C0Value* obj, const char* key, size_t key_len, C0Value* value);
size_t c0_object_len(const C0Value* obj);
const char* c0_object_key(const C0Value* obj, size_t index, size_t* key_len);
C0Value* c0_object_value(const C0Value* obj, size_t index);

/* Value inspection */
int c0_is_string(const C0Value* val);
int c0_is_array(const C0Value* val);
int c0_is_object(const C0Value* val);
const char* c0_string_data(const C0Value* val, size_t* len);

/* Encode/Decode */
uint8_t* c0_encode(C0Arena* arena, const C0Value* val, size_t* out_len);
C0Value* c0_decode(C0Arena* arena, const uint8_t* data, size_t len);

/* Codec operations */

/** Expand: file bytes -> C0 text
 *  codec_name: NULL for auto-detect (pass codec_name_len=0)
 *  filename: NULL if unknown, used for extension matching (pass filename_len=0)
 *  faithful: 1=faithful (bit-perfect), 0=editable (recalculate derived fields)
 *  pretty: 1=pretty-print with tabs/newlines, 0=compact
 *  Returns C0-encoded text, or NULL on failure */
uint8_t* c0_codec_expand(C0Arena* arena,
    const char* codec_name, size_t codec_name_len,
    const char* filename, size_t filename_len,
    const uint8_t* data, size_t len,
    int faithful,
    int pretty,
    size_t* out_len);

/** Collapse: C0 text -> file bytes
 *  codec_name: NULL = infer from C0 "format" field (pass codec_name_len=0)
 *  faithful: 1=faithful (bit-perfect), 0=editable
 *  Returns native file bytes, or NULL on failure */
uint8_t* c0_codec_collapse(C0Arena* arena,
    const char* codec_name, size_t codec_name_len,
    const uint8_t* c0_data, size_t c0_len,
    int faithful,
    size_t* out_len);

/** Detect codec from file data and optional filename
 *  Returns codec name (static string, do not free) or NULL */
const char* c0_codec_detect(const uint8_t* data, size_t len,
    const char* filename, size_t filename_len);

/** Get number of available codecs */
size_t c0_codec_count(void);

/** Get info for codec at index */
C0CodecInfo c0_codec_info(size_t index);

/* Utility operations */

/** Convert C0 data to JSON (naive — all strings become JSON strings, no type interpretation).
 *  Returns JSON bytes, or NULL on failure */
uint8_t* c0_to_json(C0Arena* arena,
    const uint8_t* c0_data, size_t c0_len,
    size_t* out_len);

/** Query a path in C0 data (jq-style: ".key[0].key2").
 *  For strings: returns raw string bytes + newline.
 *  For arrays/objects: returns compact C0 text + newline.
 *  as_type: NULL for raw output, or type name (e.g. "u32", "f64", "uuid")
 *           to interpret binary string bytes (pass as_type_len=0 for NULL)
 *  Returns NULL if path is invalid or doesn't match */
uint8_t* c0_get(C0Arena* arena,
    const uint8_t* c0_data, size_t c0_len,
    const char* path, size_t path_len,
    const char* as_type, size_t as_type_len,
    size_t* out_len);

/** Set a value at a path in C0 data, returning new C0 text.
 *  path: jq-style path (e.g., ".name", ".users[0].age")
 *  new_value_c0: the new value as C0 text (or human-readable text if as_type set)
 *  as_type: NULL to treat new_value_c0 as C0 text, or type name (e.g. "u32")
 *           to encode human-readable text into binary (pass as_type_len=0 for NULL)
 *  pretty: 1=pretty-print, 0=compact
 *  Returns new C0 text with the value replaced, or NULL on failure */
uint8_t* c0_set(C0Arena* arena,
    const uint8_t* c0_data, size_t c0_len,
    const char* path, size_t path_len,
    const uint8_t* new_value_c0, size_t new_value_len,
    const char* as_type, size_t as_type_len,
    int pretty,
    size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif /* C0_H */

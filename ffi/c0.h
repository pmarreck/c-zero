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
} C0Error;

/* Opaque types */
typedef struct C0Arena C0Arena;
typedef struct C0Value C0Value;

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

#ifdef __cplusplus
}
#endif

#endif /* C0_H */

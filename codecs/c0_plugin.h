/*
 * c0_plugin.h - C ABI between a codec's Zig library and the plugin executable host
 *
 * Every c0-codec-<name> executable links exactly one codec library exporting these
 * functions. codecs/plugin_main.c performs all I/O and speaks protocol c0-codec/1
 * (docs/plan_context/codec_plugins.md); the library is pure computation.
 *
 * All buffers are pointer plus byte length; embedded zero bytes are ordinary data.
 * Output buffers are owned by the library and must be released with c0_plugin_free.
 * On failure the output buffer holds a UTF-8 error message instead of a result.
 */
#ifndef C0_PLUGIN_H
#define C0_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define C0_PLUGIN_PROTOCOL "c0-codec/1"

typedef enum {
    C0_PLUGIN_OK = 0,
    C0_PLUGIN_CODEC_ERROR = 1,
    C0_PLUGIN_OUT_OF_MEMORY = 2,
    C0_PLUGIN_INVALID_ARGUMENT = 3
} C0PluginStatus;

/* A codec-specific --KEY VALUE argument; KEY excludes the leading dashes. */
typedef struct {
    const uint8_t *key;
    size_t key_len;
    const uint8_t *value;
    size_t value_len;
} C0PluginArg;

typedef struct {
    uint8_t *data;
    size_t len;
} C0PluginBuffer;

/* Compact C0 object describing the codec (protocol, name, magic, args...). */
int c0_plugin_info(C0PluginBuffer *out);

/* Native bytes -> C0 text. editable: 0 faithful, 1 editable. pretty: 1 pretty-printed. */
int c0_plugin_expand(const uint8_t *in, size_t in_len, int editable, int pretty,
                     const C0PluginArg *args, size_t args_len, C0PluginBuffer *out);

/* C0 text -> native bytes. */
int c0_plugin_collapse(const uint8_t *in, size_t in_len, int editable,
                       const C0PluginArg *args, size_t args_len, C0PluginBuffer *out);

void c0_plugin_free(C0PluginBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif /* C0_PLUGIN_H */

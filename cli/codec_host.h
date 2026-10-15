/*
 * codec_host.h - c0 CLI side of the codec plugin protocol c0-codec/1
 *
 * Discovers c0-codec-<name> executables, reads their `info` metadata, picks a
 * codec for a file or a C0 document, and runs plugins with streamed stdin/stdout.
 * See docs/plan_context/codec_plugins.md.
 */
#ifndef C0_CODEC_HOST_H
#define C0_CODEC_HOST_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    size_t offset;
    uint8_t* bytes;
    size_t len;
} CodecMagic;

typedef struct {
    char* name;
    char* value_name;
    char* description;
} CodecArgSpec;

typedef struct {
    char* name; /* codec name, from the executable name */
    char* path; /* executable path */
    int info_state; /* 0 not loaded, 1 loaded, -1 unusable */
    char* info_error; /* why the plugin is unusable */
    char* description;
    char* help;
    int faithful;
    int editable;
    char** extensions;
    size_t extensions_len;
    CodecMagic* magic;
    size_t magic_len;
    char** format_names;
    size_t format_names_len;
    CodecArgSpec* args;
    size_t args_len;
} CodecPlugin;

/* Finds plugins once per process. argv0 locates the bundled-codec directory. */
void codec_host_discover(const char* argv0);
size_t codec_host_count(void);
CodecPlugin* codec_host_get(size_t index);
CodecPlugin* codec_host_find(const char* name);

/* Runs `info` and parses it; returns 1 when usable, 0 otherwise (see info_error). */
int codec_host_load_info(CodecPlugin* plugin);

/* Magic bytes first, then file-name extension (case-insensitive); NULL when none match. */
CodecPlugin* codec_host_detect(const uint8_t* data, size_t len, const char* filename);

/* First plugin whose format_names or name equals the C0 `format` field value. */
CodecPlugin* codec_host_find_format(const uint8_t* format, size_t format_len);

/* Index of the declared argument named `key` (no leading dashes), or -1. */
long codec_host_arg_index(const CodecPlugin* plugin, const char* key);

/*
 * Runs the plugin with argv[1..] = args, streaming `input` to its stdin while
 * collecting stdout. The plugin's stderr passes through. Returns 0 when the
 * process ran (see *exit_code), -1 when it could not be started or read.
 */
int codec_host_run(const char* path, const char* const* args, size_t args_len,
                   const uint8_t* input, size_t input_len,
                   uint8_t** output, size_t* output_len, int* exit_code);

#endif /* C0_CODEC_HOST_H */

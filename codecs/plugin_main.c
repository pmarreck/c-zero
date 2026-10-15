/*
 * plugin_main.c - executable host shared by every c0-codec-<name> plugin
 *
 * Speaks protocol c0-codec/1 (docs/plan_context/codec_plugins.md) and does all I/O:
 *   c0-codec-<name> info
 *   c0-codec-<name> expand   [--editable] [--compact] [--KEY VALUE]...   stdin native, stdout C0
 *   c0-codec-<name> collapse [--editable] [--KEY VALUE]...               stdin C0, stdout native
 * The codec itself is the linked library behind c0_plugin.h, which performs no I/O.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "c0_plugin.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#ifndef C0_PLUGIN_NAME
#error "C0_PLUGIN_NAME must name the codec"
#endif
#ifndef C0_VERSION
#define C0_VERSION "0.0.0"
#endif

#if defined(_WIN32)
#define C0_OS "windows"
#elif defined(__APPLE__)
#define C0_OS "macos"
#elif defined(__linux__)
#define C0_OS "linux"
#else
#define C0_OS "unknown-os"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define C0_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define C0_ARCH "x86_64"
#else
#define C0_ARCH "unknown-arch"
#endif

#define MAX_CODEC_ARGS 32

static void set_binary_stdio(void) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
}

/* Reads all of stdin into a malloc'd buffer; returns NULL on allocation or read failure. */
static uint8_t* read_all_stdin(size_t* out_len) {
    size_t cap = 1 << 16, len = 0;
    uint8_t* buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (len == cap) {
            uint8_t* grown = realloc(buf, cap * 2);
            if (!grown) { free(buf); return NULL; }
            buf = grown;
            cap *= 2;
        }
        size_t n = fread(buf + len, 1, cap - len, stdin);
        len += n;
        if (n == 0) break;
    }
    if (ferror(stdin)) { free(buf); return NULL; }
    *out_len = len;
    return buf;
}

static int write_all_stdout(const uint8_t* data, size_t len) {
    if (len > 0 && fwrite(data, 1, len, stdout) != len) return 0;
    return fflush(stdout) == 0;
}

static void print_usage(FILE* f) {
    fprintf(f,
        "Usage: c0-codec-" C0_PLUGIN_NAME " <command> [options]\n"
        "\n"
        "C0 codec plugin (protocol " C0_PLUGIN_PROTOCOL "), normally run by 'c0 expand' and 'c0 collapse'.\n"
        "\n"
        "Commands:\n"
        "  info                       Print codec metadata as a compact C0 object\n"
        "  expand   [options]         stdin: native bytes  -> stdout: C0 text\n"
        "  collapse [options]         stdin: C0 text       -> stdout: native bytes\n"
        "\n"
        "Options:\n"
        "  --editable                 Editable mode (derived fields recomputed)\n"
        "  --compact                  expand only: no pretty printing\n"
        "  --KEY VALUE                Codec-specific argument (see 'c0 codecs " C0_PLUGIN_NAME "')\n"
        "  -h, --help                 Show this help\n"
        "  --about                    One-line description, version and platform\n");
}

/* Prints the library's output (result or error message) and releases it. */
static int finish(int status, C0PluginBuffer out) {
    int rc = 0;
    if (status == C0_PLUGIN_OK) {
        if (!write_all_stdout(out.data, out.len)) {
            fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": failed to write output\n");
            rc = 1;
        }
    } else {
        fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": %.*s\n", (int)out.len, out.data ? (const char*)out.data : "");
        rc = status == C0_PLUGIN_INVALID_ARGUMENT ? 2 : 1;
    }
    c0_plugin_free(out);
    return rc;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage(stderr);
        return 2;
    }
    const char* command = argv[1];
    if (strcmp(command, "-h") == 0 || strcmp(command, "--help") == 0) {
        print_usage(stdout);
        return 0;
    }
    if (strcmp(command, "--about") == 0) {
        printf("c0-codec-" C0_PLUGIN_NAME ": C0 codec plugin (" C0_PLUGIN_PROTOCOL ") v" C0_VERSION " for " C0_OS "/" C0_ARCH "\n");
        return 0;
    }

    int is_info = strcmp(command, "info") == 0;
    int is_expand = strcmp(command, "expand") == 0;
    int is_collapse = strcmp(command, "collapse") == 0;
    if (!is_info && !is_expand && !is_collapse) {
        fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": unknown command '%s'\n", command);
        print_usage(stderr);
        return 2;
    }

    int editable = 0, pretty = 1;
    C0PluginArg args[MAX_CODEC_ARGS];
    size_t args_len = 0;
    for (int i = 2; i < argc; i++) {
        const char* a = argv[i];
        if (is_info) {
            fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": info takes no options\n");
            return 2;
        } else if (strcmp(a, "--editable") == 0) {
            editable = 1;
        } else if (strcmp(a, "--compact") == 0 && is_expand) {
            pretty = 0;
        } else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            print_usage(stdout);
            return 0;
        } else if (strncmp(a, "--", 2) == 0 && a[2] != '\0') {
            if (i + 1 >= argc) {
                fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": %s requires a value\n", a);
                return 2;
            }
            if (args_len == MAX_CODEC_ARGS) {
                fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": too many codec arguments (max %d)\n", MAX_CODEC_ARGS);
                return 2;
            }
            /* Later arguments override earlier ones with the same key. */
            const char* key = a + 2;
            const char* value = argv[++i];
            size_t slot = args_len;
            for (size_t k = 0; k < args_len; k++) {
                if (args[k].key_len == strlen(key) && memcmp(args[k].key, key, args[k].key_len) == 0) slot = k;
            }
            args[slot] = (C0PluginArg){
                (const uint8_t*)key, strlen(key), (const uint8_t*)value, strlen(value)};
            if (slot == args_len) args_len++;
        } else {
            fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": unexpected argument '%s'\n", a);
            return 2;
        }
    }

    set_binary_stdio();
    C0PluginBuffer out = {NULL, 0};
    if (is_info) return finish(c0_plugin_info(&out), out);

    size_t in_len = 0;
    uint8_t* in = read_all_stdin(&in_len);
    if (!in) {
        fprintf(stderr, "c0-codec-" C0_PLUGIN_NAME ": failed to read stdin\n");
        return 1;
    }
    int status = is_expand
        ? c0_plugin_expand(in, in_len, editable, pretty, args, args_len, &out)
        : c0_plugin_collapse(in, in_len, editable, args, args_len, &out);
    free(in);
    return finish(status, out);
}

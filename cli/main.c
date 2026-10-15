// Enable POSIX functions (strdup, strtok_r) on Linux
#define _POSIX_C_SOURCE 200809L

/**
 * C0 CLI - Command-line interface for C0 binary format
 *
 * Commands:
 *   encode   - Read stdin as text, encode as C0 string, write binary to stdout
 *   decode   - Read stdin as C0 binary, pretty-print the structure
 *   expand   - Read file, expand via a codec plugin to C0 on stdout
 *   collapse - Read C0 (file or stdin), write native format via a codec plugin
 *   codecs   - List codec plugins (c0-codec-<name> executables, protocol c0-codec/1)
 *
 * Usage:
 *   c0 encode < input.txt > output.c0
 *   c0 decode < input.c0
 *   echo "hello" | c0 encode | c0 decode
 *   c0 expand image.png > image.c0
 *   c0 collapse image.c0 > roundtrip.png
 *   c0 codecs
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../ffi/c0.h"

#include "codec_host.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define INITIAL_BUFFER_SIZE 4096

/* Forward declarations */
static void print_usage(const char* program_name);
static int cmd_encode(void);
static int cmd_decode(void);
static int cmd_expand(int argc, char* argv[]);
static int cmd_collapse(int argc, char* argv[]);
static int cmd_codecs(int argc, char* argv[]);
static int cmd_to_json(int argc, char* argv[]);
static int cmd_get(int argc, char* argv[]);
static int cmd_set(int argc, char* argv[]);
static void pretty_print(const C0Value* val, int indent);
static char* read_stdin(size_t* out_len);
static char* read_file(const char* path, size_t* out_len);
static void print_indent(int level);
static void print_escaped_string(const char* data, size_t len);

/* argv[0] of this process, used to find codec plugins bundled beside the executable */
static const char* program_path = NULL;


int main(int argc, char* argv[]) {
    program_path = argv[0];

    /* No arguments or help flag */
    if (argc < 2 ||
        strcmp(argv[1], "-h") == 0 ||
        strcmp(argv[1], "--help") == 0) {
        print_usage(argv[0]);
        return (argc < 2) ? 1 : 0;
    }

    /* Dispatch command */
    if (strcmp(argv[1], "encode") == 0) {
        return cmd_encode();
    } else if (strcmp(argv[1], "decode") == 0) {
        return cmd_decode();
    } else if (strcmp(argv[1], "expand") == 0) {
        return cmd_expand(argc, argv);
    } else if (strcmp(argv[1], "collapse") == 0) {
        return cmd_collapse(argc, argv);
    } else if (strcmp(argv[1], "codecs") == 0) {
        return cmd_codecs(argc, argv);
    } else if (strcmp(argv[1], "to-json") == 0) {
        return cmd_to_json(argc, argv);
    } else if (strcmp(argv[1], "get") == 0) {
        return cmd_get(argc, argv);
    } else if (strcmp(argv[1], "set") == 0) {
        return cmd_set(argc, argv);
    } else {
        fprintf(stderr, "Error: Unknown command '%s'\n\n", argv[1]);
        print_usage(argv[0]);
        return 1;
    }
}

static void print_usage(const char* program_name) {
    fprintf(stderr, "C0 - Hierarchical Binary Data Stream Format\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Usage: %s <command> [options]\n", program_name);
    fprintf(stderr, "\n");
    fprintf(stderr, "Commands:\n");
    fprintf(stderr, "  encode              Read text from stdin, encode as C0 string, write to stdout\n");
    fprintf(stderr, "  decode              Read C0 binary from stdin, pretty-print to stdout\n");
    fprintf(stderr, "  expand [opts] <file>  Expand binary file to C0 text on stdout\n");
    fprintf(stderr, "  collapse [opts] [file] Collapse C0 text back to native format on stdout\n");
    fprintf(stderr, "  to-json [file]      Convert C0 text to JSON (naive, all strings as JSON strings)\n");
    fprintf(stderr, "  get <path> [opts] [file]  Query a value by jq-style path (e.g., .key[0].name)\n");
    fprintf(stderr, "  set <path> <val> [opts] [file]  Set a value at path, emit updated C0\n");
    fprintf(stderr, "  codecs [name]       List codecs, or show detailed help for one codec\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Expand/Collapse options:\n");
    fprintf(stderr, "  --codec <name>      Use specific codec (default: auto-detect)\n");
    fprintf(stderr, "  --KEY VALUE         Codec-specific option (see 'codecs <name>')\n");
    fprintf(stderr, "  <file> may be - or @stdin to read standard input\n");
    fprintf(stderr, "  --editable          Editable mode (omit/recalculate derived fields)\n");
    fprintf(stderr, "  --compact           Compact output (no pretty-printing)\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Get/Set options:\n");
    fprintf(stderr, "  --as <type>         Interpret binary as type (u8..u64, i8..i64, f32, f64,\n");
    fprintf(stderr, "                      uuid, datetime-s/ms/ns, utf16le/be, hex, base64, bigint)\n");
    fprintf(stderr, "                      Append 'be' for big-endian (e.g., u32be, f64be)\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Codec plugins:\n");
    fprintf(stderr, "  Codecs are c0-codec-<name> executables found in $C0_CODEC_PATH if set,\n");
    fprintf(stderr, "  otherwise beside this executable, in ~/.c0/codecs, then on PATH.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -h, --help          Show this help message\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  echo \"hello\" | %s encode > hello.c0\n", program_name);
    fprintf(stderr, "  %s decode < hello.c0\n", program_name);
    fprintf(stderr, "  %s expand image.png > image.c0\n", program_name);
    fprintf(stderr, "  %s collapse image.c0 > roundtrip.png\n", program_name);
    fprintf(stderr, "  %s expand --editable image.png | %s collapse --editable > edited.png\n",
            program_name, program_name);
    fprintf(stderr, "  %s to-json image.c0\n", program_name);
    fprintf(stderr, "  %s get .format image.c0\n", program_name);
    fprintf(stderr, "  %s get .width --as u32 image.c0\n", program_name);
    fprintf(stderr, "  %s set .name Alice image.c0 > updated.c0\n", program_name);
    fprintf(stderr, "  %s set .width 1920 --as u32 image.c0 > updated.c0\n", program_name);
    fprintf(stderr, "  %s codecs\n", program_name);
}

/**
 * Read all data from stdin into a dynamically allocated buffer
 * Returns NULL on error, sets *out_len to number of bytes read
 */
static char* read_stdin(size_t* out_len) {
    size_t capacity = INITIAL_BUFFER_SIZE;
    size_t len = 0;
    char* buffer = malloc(capacity);

    if (!buffer) {
        fprintf(stderr, "Error: Out of memory\n");
        return NULL;
    }

    /* Read in binary mode to handle arbitrary data */
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
#endif

    while (!feof(stdin)) {
        size_t space = capacity - len;
        if (space == 0) {
            capacity *= 2;
            char* new_buf = realloc(buffer, capacity);
            if (!new_buf) {
                fprintf(stderr, "Error: Out of memory\n");
                free(buffer);
                return NULL;
            }
            buffer = new_buf;
            space = capacity - len;
        }

        size_t n = fread(buffer + len, 1, space, stdin);
        if (n == 0 && ferror(stdin)) {
            fprintf(stderr, "Error: Failed to read from stdin\n");
            free(buffer);
            return NULL;
        }
        len += n;
    }

    *out_len = len;
    return buffer;
}

/**
 * Read all data from a file into a dynamically allocated buffer
 * Returns NULL on error, sets *out_len to number of bytes read
 */
static char* read_file(const char* path, size_t* out_len) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: Cannot open file '%s'\n", path);
        return NULL;
    }

    /* Get file size */
    if (fseek(f, 0, SEEK_END) != 0) {
        fprintf(stderr, "Error: Cannot seek in file '%s'\n", path);
        fclose(f);
        return NULL;
    }
    long file_size = ftell(f);
    if (file_size < 0) {
        fprintf(stderr, "Error: Cannot determine size of '%s'\n", path);
        fclose(f);
        return NULL;
    }
    rewind(f);

    char* buffer = malloc((size_t)file_size);
    if (!buffer) {
        fprintf(stderr, "Error: Out of memory\n");
        fclose(f);
        return NULL;
    }

    size_t read = fread(buffer, 1, (size_t)file_size, f);
    fclose(f);

    if (read != (size_t)file_size) {
        fprintf(stderr, "Error: Short read on '%s'\n", path);
        free(buffer);
        return NULL;
    }

    *out_len = (size_t)file_size;
    return buffer;
}

/**
 * Encode command: read stdin as text, encode as C0 string, write binary to stdout
 */
static int cmd_encode(void) {
    size_t input_len;
    char* input = read_stdin(&input_len);
    if (!input) {
        return 1;
    }

    /* Strip trailing newline if present (common for echo piping) */
    while (input_len > 0 && (input[input_len - 1] == '\n' || input[input_len - 1] == '\r')) {
        input_len--;
    }

    /* Create arena and encode */
    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(input);
        return 1;
    }

    C0Value* str = c0_string(arena, input, input_len);
    if (!str) {
        fprintf(stderr, "Error: Failed to create string value\n");
        c0_arena_free(arena);
        free(input);
        return 1;
    }

    size_t encoded_len;
    uint8_t* encoded = c0_encode(arena, str, &encoded_len);
    if (!encoded) {
        fprintf(stderr, "Error: Failed to encode value\n");
        c0_arena_free(arena);
        free(input);
        return 1;
    }

    /* Write binary output to stdout */
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    size_t written = fwrite(encoded, 1, encoded_len, stdout);
    if (written != encoded_len) {
        fprintf(stderr, "Error: Failed to write output\n");
        c0_arena_free(arena);
        free(input);
        return 1;
    }

    c0_arena_free(arena);
    free(input);
    return 0;
}

/**
 * Decode command: read stdin as C0 binary, pretty-print the structure
 */
static int cmd_decode(void) {
    size_t input_len;
    char* input = read_stdin(&input_len);
    if (!input) {
        return 1;
    }

    if (input_len == 0) {
        fprintf(stderr, "Error: Empty input\n");
        free(input);
        return 1;
    }

    /* Create arena and decode */
    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(input);
        return 1;
    }

    C0Value* val = c0_decode(arena, (const uint8_t*)input, input_len);
    if (!val) {
        fprintf(stderr, "Error: Failed to decode C0 data (invalid format)\n");
        c0_arena_free(arena);
        free(input);
        return 1;
    }

    /* Pretty print the structure */
    pretty_print(val, 0);
    printf("\n");

    c0_arena_free(arena);
    free(input);
    return 0;
}

/**
 * Expand command: read binary file, expand via codec to C0 text on stdout
 * Usage: c0 expand [--codec name] [--editable] [--compact] <file>
 */
#define MAX_EXTRA_ARGS 32

/* Options shared by expand and collapse; extras are codec-specific --KEY VALUE pairs. */
typedef struct {
    const char* codec_name;
    int editable;
    int compact;
    const char* filepath;
    const char* extra_keys[MAX_EXTRA_ARGS];
    const char* extra_values[MAX_EXTRA_ARGS];
    size_t extra_count;
} CodecCommand;

/* Parses expand/collapse arguments; later duplicates of an option override earlier ones. */
static int parse_codec_command(int argc, char* argv[], int allow_compact, CodecCommand* cmd) {
    memset(cmd, 0, sizeof(*cmd));
    int positional_only = 0;
    for (int i = 2; i < argc; i++) {
        const char* a = argv[i];
        if (positional_only || strcmp(a, "-") == 0 || a[0] != '-') {
            cmd->filepath = a;
        } else if (strcmp(a, "--") == 0) {
            positional_only = 1;
        } else if (strcmp(a, "--codec") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: --codec requires an argument\n");
                return 0;
            }
            cmd->codec_name = argv[++i];
        } else if (strcmp(a, "--editable") == 0) {
            cmd->editable = 1;
        } else if (allow_compact && strcmp(a, "--compact") == 0) {
            cmd->compact = 1;
        } else if (strncmp(a, "--", 2) == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: %s requires a value\n", a);
                return 0;
            }
            size_t slot = cmd->extra_count;
            for (size_t k = 0; k < cmd->extra_count; k++) {
                if (strcmp(cmd->extra_keys[k], a + 2) == 0) slot = k;
            }
            if (slot == MAX_EXTRA_ARGS) {
                fprintf(stderr, "Error: Too many codec options (max %d)\n", MAX_EXTRA_ARGS);
                return 0;
            }
            cmd->extra_keys[slot] = a + 2;
            cmd->extra_values[slot] = argv[++i];
            if (slot == cmd->extra_count) cmd->extra_count++;
        } else {
            fprintf(stderr, "Error: Unknown option '%s'\n", a);
            return 0;
        }
    }
    return 1;
}

static int is_stdin_path(const char* path) {
    return path == NULL || strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

/* Resolves a named codec plugin and loads its metadata, reporting failures. */
static CodecPlugin* require_codec(const char* name) {
    CodecPlugin* p = codec_host_find(name);
    if (!p) {
        fprintf(stderr, "Error: codec '%s' not found (see 'c0 codecs')\n", name);
        return NULL;
    }
    if (!codec_host_load_info(p)) {
        fprintf(stderr, "Error: codec '%s' is unusable: %s\n", name, p->info_error);
        return NULL;
    }
    return p;
}

/* Runs one plugin subcommand and writes its stdout to ours; returns the CLI exit status. */
static int run_codec(CodecPlugin* p, const char* subcommand, const CodecCommand* cmd,
                     const uint8_t* input, size_t input_len) {
    for (size_t i = 0; i < cmd->extra_count; i++) {
        if (codec_host_arg_index(p, cmd->extra_keys[i]) < 0) {
            fprintf(stderr, "Error: codec '%s' has no option --%s (see 'c0 codecs %s')\n",
                    p->name, cmd->extra_keys[i], p->name);
            return 1;
        }
    }
    const char* args[3 + 2 * MAX_EXTRA_ARGS];
    char flags[MAX_EXTRA_ARGS][80];
    size_t n = 0;
    args[n++] = subcommand;
    if (cmd->editable) args[n++] = "--editable";
    if (cmd->compact) args[n++] = "--compact";
    for (size_t i = 0; i < cmd->extra_count; i++) {
        snprintf(flags[i], sizeof(flags[i]), "--%s", cmd->extra_keys[i]);
        args[n++] = flags[i];
        args[n++] = cmd->extra_values[i];
    }

    uint8_t* out = NULL;
    size_t out_len = 0;
    int exit_code = 0;
    if (codec_host_run(p->path, args, n, input, input_len, &out, &out_len, &exit_code) != 0) {
        fprintf(stderr, "Error: could not run codec '%s' (%s)\n", p->name, p->path);
        return 1;
    }
    if (exit_code != 0) {
        free(out);
        fprintf(stderr, "Error: codec '%s' failed (exit %d)\n", p->name, exit_code);
        return 1;
    }
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    int ok = out_len == 0 || fwrite(out, 1, out_len, stdout) == out_len;
    free(out);
    if (!ok || fflush(stdout) != 0) {
        fprintf(stderr, "Error: Failed to write output\n");
        return 1;
    }
    return 0;
}

/**
 * Expand command: native file -> C0 text on stdout, through a codec plugin
 * Usage: c0 expand [--codec name] [--editable] [--compact] [--KEY VALUE]... <file|-|@stdin>
 */
static int cmd_expand(int argc, char* argv[]) {
    CodecCommand cmd;
    if (!parse_codec_command(argc, argv, 1, &cmd)) return 1;
    if (!cmd.filepath) {
        fprintf(stderr, "Error: expand requires a file argument (use - for stdin)\n");
        fprintf(stderr, "Usage: c0 expand [--codec name] [--editable] [--compact] <file>\n");
        return 1;
    }
    size_t data_len;
    char* data = is_stdin_path(cmd.filepath) ? read_stdin(&data_len) : read_file(cmd.filepath, &data_len);
    if (!data) return 1;

    codec_host_discover(program_path);
    CodecPlugin* p;
    if (cmd.codec_name) {
        p = require_codec(cmd.codec_name);
    } else {
        p = codec_host_detect((const uint8_t*)data, data_len, is_stdin_path(cmd.filepath) ? NULL : cmd.filepath);
        if (!p) fprintf(stderr, "Error: No codec found for '%s' (unrecognized format; see 'c0 codecs')\n", cmd.filepath);
    }
    int rc = p ? run_codec(p, "expand", &cmd, (const uint8_t*)data, data_len) : 1;
    free(data);
    return rc;
}

/* Finds the plugin named by a C0 document's top-level `format` field. */
static CodecPlugin* codec_for_document(const char* data, size_t len) {
    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        return NULL;
    }
    CodecPlugin* found = NULL;
    C0Value* doc = c0_decode(arena, (const uint8_t*)data, len);
    if (!doc) {
        fprintf(stderr, "Error: Input is not valid C0\n");
    } else {
        const char* format = NULL;
        size_t format_len = 0;
        if (c0_is_object(doc)) {
            for (size_t i = 0; i < c0_object_len(doc); i++) {
                size_t key_len;
                const char* key = c0_object_key(doc, i, &key_len);
                C0Value* v = c0_object_value(doc, i);
                if (key_len == 6 && memcmp(key, "format", 6) == 0 && c0_is_string(v)) {
                    format = c0_string_data(v, &format_len);
                    break;
                }
            }
        }
        if (!format) {
            fprintf(stderr, "Error: C0 input has no top-level 'format' field; use --codec\n");
        } else {
            found = codec_host_find_format((const uint8_t*)format, format_len);
            if (!found) fprintf(stderr, "Error: No codec handles format '%.*s' (see 'c0 codecs')\n", (int)format_len, format);
        }
    }
    c0_arena_free(arena);
    return found;
}

/**
 * Collapse command: C0 text -> native bytes on stdout, through a codec plugin
 * Usage: c0 collapse [--codec name] [--editable] [--KEY VALUE]... [file|-|@stdin]
 * Without --codec, the document's top-level `format` field selects the codec.
 */
static int cmd_collapse(int argc, char* argv[]) {
    CodecCommand cmd;
    if (!parse_codec_command(argc, argv, 0, &cmd)) return 1;
    size_t c0_len;
    char* c0_data = is_stdin_path(cmd.filepath) ? read_stdin(&c0_len) : read_file(cmd.filepath, &c0_len);
    if (!c0_data) return 1;
    if (c0_len == 0) {
        fprintf(stderr, "Error: Empty input\n");
        free(c0_data);
        return 1;
    }
    codec_host_discover(program_path);
    CodecPlugin* p = cmd.codec_name ? require_codec(cmd.codec_name) : codec_for_document(c0_data, c0_len);
    int rc = p ? run_codec(p, "collapse", &cmd, (const uint8_t*)c0_data, c0_len) : 1;
    free(c0_data);
    return rc;
}

static void print_modes(const CodecPlugin* p) {
    if (p->faithful && p->editable) printf("  [faithful, editable]");
    else if (p->faithful) printf("  [faithful]");
    else if (p->editable) printf("  [editable]");
}

/**
 * Codecs command: list codec plugins or show one plugin's help
 * Usage: c0 codecs [name]
 */
static int cmd_codecs(int argc, char* argv[]) {
    codec_host_discover(program_path);
    if (argc > 2) {
        CodecPlugin* p = codec_host_find(argv[2]);
        if (!p) {
            fprintf(stderr, "Error: Unknown codec '%s'\n", argv[2]);
            return 1;
        }
        if (!codec_host_load_info(p)) {
            fprintf(stderr, "Error: codec '%s' is unusable: %s\n", p->name, p->info_error);
            return 1;
        }
        printf("%s", p->name);
        print_modes(p);
        printf("\n  %s\n  %s\n", p->description, p->path);
        if (p->args_len > 0) {
            printf("\nOptions:\n");
            for (size_t j = 0; j < p->args_len; j++) {
                int used = printf("  --%s %s", p->args[j].name, p->args[j].value_name);
                for (int pad = 22 - used; pad > 0; pad--) putchar(' ');
                printf("  %s\n", p->args[j].description);
            }
        }
        if (p->help[0]) printf("\n%s\n", p->help);
        return 0;
    }

    printf("Codec plugins:\n\n");
    if (codec_host_count() == 0) printf("  (none)\n");
    for (size_t i = 0; i < codec_host_count(); i++) {
        CodecPlugin* p = codec_host_get(i);
        printf("  %s", p->name);
        if (codec_host_load_info(p)) {
            print_modes(p);
            printf("\n    %s\n", p->description);
        } else {
            printf("  (unavailable: %s)\n", p->info_error);
        }
        printf("    %s\n", p->path);
    }
    return 0;
}


/**
 * to-json command: convert C0 text to JSON (naive, all strings as JSON strings)
 * Usage: c0 to-json [file]
 * If no file given, reads from stdin.
 */
static int cmd_to_json(int argc, char* argv[]) {
    char* data;
    size_t data_len;

    if (argc > 2) {
        data = read_file(argv[2], &data_len);
    } else {
        data = read_stdin(&data_len);
    }
    if (!data) return 1;

    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(data);
        return 1;
    }

    size_t json_len;
    uint8_t* json = c0_to_json(arena, (const uint8_t*)data, data_len, &json_len);
    if (!json) {
        fprintf(stderr, "Error: Failed to convert C0 to JSON\n");
        c0_arena_free(arena);
        free(data);
        return 1;
    }

    fwrite(json, 1, json_len, stdout);

    c0_arena_free(arena);
    free(data);
    return 0;
}

/**
 * get command: query a value by jq-style path
 * Usage: c0 get <path> [--as <type>] [file]
 * If no file given, reads from stdin.
 */
static int cmd_get(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Error: get requires a path argument\n");
        fprintf(stderr, "Usage: c0 get <path> [--as <type>] [file]\n");
        return 1;
    }

    const char* path = argv[2];
    const char* as_type = NULL;
    const char* filepath = NULL;

    /* Parse remaining arguments */
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--as") == 0) {
            if (i + 1 < argc) {
                as_type = argv[++i];
            } else {
                fprintf(stderr, "Error: --as requires a type argument\n");
                return 1;
            }
        } else {
            filepath = argv[i];
        }
    }

    char* data;
    size_t data_len;

    if (filepath) {
        data = read_file(filepath, &data_len);
    } else {
        data = read_stdin(&data_len);
    }
    if (!data) return 1;

    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(data);
        return 1;
    }

    size_t result_len;
    uint8_t* result = c0_get(arena,
        (const uint8_t*)data, data_len,
        path, strlen(path),
        as_type, as_type ? strlen(as_type) : 0,
        &result_len);

    if (!result) {
        fprintf(stderr, "Error: Path '%s' not found or invalid\n", path);
        c0_arena_free(arena);
        free(data);
        return 1;
    }

    fwrite(result, 1, result_len, stdout);
    /* Add newline if result doesn't end with one */
    if (result_len > 0 && result[result_len - 1] != '\n') {
        putchar('\n');
    }

    c0_arena_free(arena);
    free(data);
    return 0;
}

/**
 * set command: set a value at a path, emit updated C0
 * Usage: c0 set <path> <value> [--as <type>] [--compact] [file]
 * If no file given, reads from stdin.
 * The value is raw C0 text (e.g., "hello" for a string, "[a,b]" for an array).
 * With --as, the value is human-readable text that gets encoded to binary bytes.
 */
static int cmd_set(int argc, char* argv[]) {
    if (argc < 4) {
        fprintf(stderr, "Error: set requires a path and value\n");
        fprintf(stderr, "Usage: c0 set <path> <value> [--as <type>] [--compact] [file]\n");
        return 1;
    }

    const char* path = argv[2];
    const char* new_value = argv[3];
    const char* as_type = NULL;
    int pretty = 1;
    const char* filepath = NULL;

    /* Parse remaining arguments */
    for (int i = 4; i < argc; i++) {
        if (strcmp(argv[i], "--compact") == 0) {
            pretty = 0;
        } else if (strcmp(argv[i], "--as") == 0) {
            if (i + 1 < argc) {
                as_type = argv[++i];
            } else {
                fprintf(stderr, "Error: --as requires a type argument\n");
                return 1;
            }
        } else {
            filepath = argv[i];
        }
    }

    char* data;
    size_t data_len;

    if (filepath) {
        data = read_file(filepath, &data_len);
    } else {
        data = read_stdin(&data_len);
    }
    if (!data) return 1;

    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(data);
        return 1;
    }

    size_t result_len;
    uint8_t* result = c0_set(arena,
        (const uint8_t*)data, data_len,
        path, strlen(path),
        (const uint8_t*)new_value, strlen(new_value),
        as_type, as_type ? strlen(as_type) : 0,
        pretty,
        &result_len);

    if (!result) {
        fprintf(stderr, "Error: Failed to set value at path '%s'\n", path);
        c0_arena_free(arena);
        free(data);
        return 1;
    }

    fwrite(result, 1, result_len, stdout);

    c0_arena_free(arena);
    free(data);
    return 0;
}

/**
 * Print indentation for pretty printing
 */
static void print_indent(int level) {
    for (int i = 0; i < level; i++) {
        printf("  ");
    }
}

/**
 * Print a string with JSON-style escaping for non-printable characters
 */
static void print_escaped_string(const char* data, size_t len) {
    printf("\"");
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)data[i];
        switch (c) {
            case '\\': printf("\\\\"); break;
            case '"':  printf("\\\""); break;
            case '\n': printf("\\n"); break;
            case '\r': printf("\\r"); break;
            case '\t': printf("\\t"); break;
            default:
                if (c >= 32 && c < 127) {
                    putchar(c);
                } else {
                    printf("\\x%02x", c);
                }
                break;
        }
    }
    printf("\"");
}

/**
 * Pretty print a C0 value in JSON-like format
 */
static void pretty_print(const C0Value* val, int indent) {
    if (!val) {
        printf("null");
        return;
    }

    if (c0_is_string(val)) {
        size_t len;
        const char* data = c0_string_data(val, &len);
        if (data) {
            print_escaped_string(data, len);
        } else {
            printf("\"\"");
        }
    } else if (c0_is_array(val)) {
        size_t len = c0_array_len(val);
        if (len == 0) {
            printf("[]");
        } else {
            printf("[\n");
            for (size_t i = 0; i < len; i++) {
                print_indent(indent + 1);
                C0Value* item = c0_array_get(val, i);
                pretty_print(item, indent + 1);
                if (i < len - 1) {
                    printf(",");
                }
                printf("\n");
            }
            print_indent(indent);
            printf("]");
        }
    } else if (c0_is_object(val)) {
        size_t len = c0_object_len(val);
        if (len == 0) {
            printf("{}");
        } else {
            printf("{\n");
            for (size_t i = 0; i < len; i++) {
                print_indent(indent + 1);

                size_t key_len;
                const char* key = c0_object_key(val, i, &key_len);
                print_escaped_string(key, key_len);
                printf(": ");

                C0Value* item = c0_object_value(val, i);
                pretty_print(item, indent + 1);

                if (i < len - 1) {
                    printf(",");
                }
                printf("\n");
            }
            print_indent(indent);
            printf("}");
        }
    } else {
        printf("<unknown>");
    }
}

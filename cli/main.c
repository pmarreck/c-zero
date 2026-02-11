/**
 * C0 CLI - Command-line interface for C0 binary format
 *
 * Commands:
 *   encode   - Read stdin as text, encode as C0 string, write binary to stdout
 *   decode   - Read stdin as C0 binary, pretty-print the structure
 *   expand   - Read file, expand via codec to C0 on stdout
 *   collapse - Read C0 (file or stdin), write native format to stdout
 *   codecs   - List available codecs
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

/* Subprocess codec protocol (POSIX only) */
#ifdef _WIN32
#define HAS_SUBPROCESS_CODECS 0
#else
#define HAS_SUBPROCESS_CODECS 1
#include <unistd.h>
#include <sys/wait.h>
#include <dirent.h>
#include <sys/stat.h>
#endif

#define INITIAL_BUFFER_SIZE 4096

/* Forward declarations */
static void print_usage(const char* program_name);
static int cmd_encode(void);
static int cmd_decode(void);
static int cmd_expand(int argc, char* argv[]);
static int cmd_collapse(int argc, char* argv[]);
static int cmd_codecs(void);
static int cmd_to_json(int argc, char* argv[]);
static int cmd_get(int argc, char* argv[]);
static int cmd_set(int argc, char* argv[]);
static void pretty_print(const C0Value* val, int indent);
static char* read_stdin(size_t* out_len);
static char* read_file(const char* path, size_t* out_len);
static void print_indent(int level);
static void print_escaped_string(const char* data, size_t len);

/* =========================================================================
 * Subprocess Codec Protocol
 *
 * External codecs are executables named "c0-codec-<name>" found in PATH
 * or ~/.c0/codecs/. They support three subcommands:
 *   c0-codec-<name> info              -> C0 metadata to stdout
 *   c0-codec-<name> expand [--editable]  -> stdin: raw bytes, stdout: C0 text
 *   c0-codec-<name> collapse [--editable] -> stdin: C0 text, stdout: raw bytes
 *
 * Built-in codecs always take priority over subprocess codecs.
 * ========================================================================= */

#if HAS_SUBPROCESS_CODECS

#define SUBPROCESS_CODEC_PREFIX "c0-codec-"
#define SUBPROCESS_CODEC_PREFIX_LEN 9
#define MAX_SUBPROCESS_CODECS 64

typedef struct {
    char name[256];
    char path[4096];
} SubprocessCodec;

static SubprocessCodec subprocess_codecs[MAX_SUBPROCESS_CODECS];
static size_t subprocess_codec_count = 0;
static int subprocess_codecs_discovered = 0;

static int is_executable(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISREG(st.st_mode) && (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH));
}

static void add_subprocess_codec(const char* name, const char* path) {
    if (subprocess_codec_count >= MAX_SUBPROCESS_CODECS) return;

    /* Skip if name matches a built-in codec */
    size_t builtin_count = c0_codec_count();
    for (size_t i = 0; i < builtin_count; i++) {
        C0CodecInfo info = c0_codec_info(i);
        if (strlen(name) == info.name_len &&
            memcmp(name, info.name, info.name_len) == 0) {
            return;
        }
    }

    /* Skip if already discovered */
    for (size_t i = 0; i < subprocess_codec_count; i++) {
        if (strcmp(subprocess_codecs[i].name, name) == 0) return;
    }

    strncpy(subprocess_codecs[subprocess_codec_count].name, name, 255);
    subprocess_codecs[subprocess_codec_count].name[255] = '\0';
    strncpy(subprocess_codecs[subprocess_codec_count].path, path, 4095);
    subprocess_codecs[subprocess_codec_count].path[4095] = '\0';
    subprocess_codec_count++;
}

static void scan_dir_for_codecs(const char* dir_path) {
    DIR* dir = opendir(dir_path);
    if (!dir) return;

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, SUBPROCESS_CODEC_PREFIX,
                    SUBPROCESS_CODEC_PREFIX_LEN) != 0)
            continue;

        const char* codec_name = entry->d_name + SUBPROCESS_CODEC_PREFIX_LEN;
        if (codec_name[0] == '\0') continue;

        char full_path[4096];
        snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);

        if (is_executable(full_path)) {
            add_subprocess_codec(codec_name, full_path);
        }
    }

    closedir(dir);
}

static void discover_subprocess_codecs(void) {
    if (subprocess_codecs_discovered) return;
    subprocess_codecs_discovered = 1;

    /* Search ~/.c0/codecs/ first (user codecs) */
    const char* home = getenv("HOME");
    if (home) {
        char codecs_dir[4096];
        snprintf(codecs_dir, sizeof(codecs_dir), "%s/.c0/codecs", home);
        scan_dir_for_codecs(codecs_dir);
    }

    /* Search PATH */
    const char* path_env = getenv("PATH");
    if (!path_env) return;

    char* path_copy = strdup(path_env);
    if (!path_copy) return;

    char* saveptr = NULL;
    char* dir = strtok_r(path_copy, ":", &saveptr);
    while (dir) {
        scan_dir_for_codecs(dir);
        dir = strtok_r(NULL, ":", &saveptr);
    }

    free(path_copy);
}

static const SubprocessCodec* find_subprocess_codec(const char* name) {
    discover_subprocess_codecs();
    for (size_t i = 0; i < subprocess_codec_count; i++) {
        if (strcmp(subprocess_codecs[i].name, name) == 0)
            return &subprocess_codecs[i];
    }
    return NULL;
}

/**
 * Run a subprocess codec command, piping input to stdin and capturing stdout.
 * Returns malloc'd output buffer (caller must free), or NULL on error.
 */
static char* run_subprocess_codec(const char* exe_path, const char* subcommand,
                                  int editable,
                                  const void* input, size_t input_len,
                                  size_t* output_len) {
    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};

    if (pipe(stdin_pipe) != 0 || pipe(stdout_pipe) != 0) {
        if (stdin_pipe[0] >= 0) { close(stdin_pipe[0]); close(stdin_pipe[1]); }
        return NULL;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return NULL;
    }

    if (pid == 0) {
        /* Child: wire up pipes, exec codec */
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);

        if (editable) {
            execl(exe_path, exe_path, subcommand, "--editable", (char*)NULL);
        } else {
            execl(exe_path, exe_path, subcommand, (char*)NULL);
        }
        _exit(127);
    }

    /* Parent: write input, read output */
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    if (input && input_len > 0) {
        size_t written = 0;
        while (written < input_len) {
            ssize_t n = write(stdin_pipe[1],
                              (const char*)input + written,
                              input_len - written);
            if (n <= 0) break;
            written += (size_t)n;
        }
    }
    close(stdin_pipe[1]);

    /* Read all output */
    size_t capacity = INITIAL_BUFFER_SIZE;
    size_t len = 0;
    char* output = malloc(capacity);
    if (!output) {
        close(stdout_pipe[0]);
        waitpid(pid, NULL, 0);
        return NULL;
    }

    for (;;) {
        if (len >= capacity) {
            capacity *= 2;
            char* new_buf = realloc(output, capacity);
            if (!new_buf) {
                free(output);
                close(stdout_pipe[0]);
                waitpid(pid, NULL, 0);
                return NULL;
            }
            output = new_buf;
        }
        ssize_t n = read(stdout_pipe[0], output + len, capacity - len);
        if (n <= 0) break;
        len += (size_t)n;
    }
    close(stdout_pipe[0]);

    int status;
    waitpid(pid, &status, 0);

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        free(output);
        return NULL;
    }

    *output_len = len;
    return output;
}

#endif /* HAS_SUBPROCESS_CODECS */

int main(int argc, char* argv[]) {
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
        return cmd_codecs();
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
    fprintf(stderr, "  codecs              List available codecs\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Expand/Collapse options:\n");
    fprintf(stderr, "  --codec <name>      Use specific codec (default: auto-detect)\n");
    fprintf(stderr, "  --editable          Editable mode (omit/recalculate derived fields)\n");
    fprintf(stderr, "  --compact           Compact output (no pretty-printing)\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Get/Set options:\n");
    fprintf(stderr, "  --as <type>         Interpret binary as type (u8..u64, i8..i64, f32, f64,\n");
    fprintf(stderr, "                      uuid, datetime-s/ms/ns, utf16le/be, hex, base64, bigint)\n");
    fprintf(stderr, "                      Append 'be' for big-endian (e.g., u32be, f64be)\n");
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
static int cmd_expand(int argc, char* argv[]) {
    const char* codec_name = NULL;
    size_t codec_name_len = 0;
    int faithful = 1;
    int pretty = 1; /* pretty-print by default */
    const char* filepath = NULL;

    /* Parse arguments after "expand" */
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--codec") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: --codec requires an argument\n");
                return 1;
            }
            codec_name = argv[++i];
            codec_name_len = strlen(codec_name);
        } else if (strcmp(argv[i], "--editable") == 0) {
            faithful = 0;
        } else if (strcmp(argv[i], "--compact") == 0) {
            pretty = 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Error: Unknown option '%s'\n", argv[i]);
            return 1;
        } else {
            filepath = argv[i];
        }
    }

    if (!filepath) {
        fprintf(stderr, "Error: expand requires a file argument\n");
        fprintf(stderr, "Usage: c0 expand [--codec name] [--editable] <file>\n");
        return 1;
    }

    /* Read file */
    size_t data_len;
    char* data = read_file(filepath, &data_len);
    if (!data) return 1;

    /* Create arena */
    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(data);
        return 1;
    }

    /* Expand via codec */
    size_t c0_len;
    uint8_t* c0_data = c0_codec_expand(arena,
        codec_name, codec_name_len,
        filepath, strlen(filepath),
        (const uint8_t*)data, data_len,
        faithful,
        pretty,
        &c0_len);

    if (!c0_data) {
#if HAS_SUBPROCESS_CODECS
        /* Try subprocess codec as fallback */
        const SubprocessCodec* sub = NULL;
        if (codec_name) {
            sub = find_subprocess_codec(codec_name);
        }
        if (sub) {
            size_t sub_out_len;
            char* sub_out = run_subprocess_codec(sub->path, "expand",
                                                 !faithful,
                                                 data, data_len,
                                                 &sub_out_len);
            if (sub_out) {
#ifdef _WIN32
                _setmode(_fileno(stdout), _O_BINARY);
#endif
                size_t written = fwrite(sub_out, 1, sub_out_len, stdout);
                free(sub_out);
                c0_arena_free(arena);
                free(data);
                return (written == sub_out_len) ? 0 : 1;
            }
            fprintf(stderr, "Error: Subprocess codec '%s' failed to expand '%s'\n",
                    codec_name, filepath);
            c0_arena_free(arena);
            free(data);
            return 1;
        }
#endif
        /* Give a helpful error */
        const char* detected = c0_codec_detect(
            (const uint8_t*)data, data_len,
            filepath, strlen(filepath));
        if (!detected) {
            fprintf(stderr, "Error: No codec found for '%s' (unrecognized format)\n", filepath);
        } else {
            fprintf(stderr, "Error: Codec '%s' failed to expand '%s'\n", detected, filepath);
        }
        c0_arena_free(arena);
        free(data);
        return 1;
    }

    /* Write C0 to stdout */
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    size_t written = fwrite(c0_data, 1, c0_len, stdout);
    if (written != c0_len) {
        fprintf(stderr, "Error: Failed to write output\n");
        c0_arena_free(arena);
        free(data);
        return 1;
    }

    c0_arena_free(arena);
    free(data);
    return 0;
}

/**
 * Collapse command: read C0 text, collapse to native format on stdout
 * Usage: c0 collapse [--codec name] [--editable] [<file>]
 * If no file given, reads from stdin.
 */
static int cmd_collapse(int argc, char* argv[]) {
    const char* codec_name = NULL;
    size_t codec_name_len = 0;
    int faithful = 1;
    const char* filepath = NULL;

    /* Parse arguments after "collapse" */
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--codec") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: --codec requires an argument\n");
                return 1;
            }
            codec_name = argv[++i];
            codec_name_len = strlen(codec_name);
        } else if (strcmp(argv[i], "--editable") == 0) {
            faithful = 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Error: Unknown option '%s'\n", argv[i]);
            return 1;
        } else {
            filepath = argv[i];
        }
    }

    /* Read C0 data from file or stdin */
    size_t c0_len;
    char* c0_data;
    if (filepath) {
        c0_data = read_file(filepath, &c0_len);
    } else {
        c0_data = read_stdin(&c0_len);
    }
    if (!c0_data) return 1;

    if (c0_len == 0) {
        fprintf(stderr, "Error: Empty input\n");
        free(c0_data);
        return 1;
    }

    /* Create arena */
    C0Arena* arena = c0_arena_new();
    if (!arena) {
        fprintf(stderr, "Error: Failed to create arena\n");
        free(c0_data);
        return 1;
    }

    /* Collapse via codec */
    size_t out_len;
    uint8_t* native_data = c0_codec_collapse(arena,
        codec_name, codec_name_len,
        (const uint8_t*)c0_data, c0_len,
        faithful,
        &out_len);

    if (!native_data) {
#if HAS_SUBPROCESS_CODECS
        /* Try subprocess codec as fallback */
        const SubprocessCodec* sub = NULL;
        if (codec_name) {
            sub = find_subprocess_codec(codec_name);
        } else {
            /* Try to infer codec name from C0 "format" field.
             * Decode C0, look for {format:<name>,...} */
            C0Value* val = c0_decode(arena, (const uint8_t*)c0_data, c0_len);
            if (val && c0_is_object(val)) {
                size_t obj_len = c0_object_len(val);
                for (size_t i = 0; i < obj_len; i++) {
                    size_t key_len;
                    const char* key = c0_object_key(val, i, &key_len);
                    if (key_len == 6 && memcmp(key, "format", 6) == 0) {
                        C0Value* fval = c0_object_value(val, i);
                        if (fval && c0_is_string(fval)) {
                            size_t fname_len;
                            const char* fname = c0_string_data(fval, &fname_len);
                            /* Use a null-terminated copy for lookup */
                            char fname_buf[256];
                            if (fname_len < sizeof(fname_buf)) {
                                memcpy(fname_buf, fname, fname_len);
                                fname_buf[fname_len] = '\0';
                                sub = find_subprocess_codec(fname_buf);
                            }
                        }
                        break;
                    }
                }
            }
        }
        if (sub) {
            size_t sub_out_len;
            char* sub_out = run_subprocess_codec(sub->path, "collapse",
                                                 !faithful,
                                                 c0_data, c0_len,
                                                 &sub_out_len);
            if (sub_out) {
#ifdef _WIN32
                _setmode(_fileno(stdout), _O_BINARY);
#endif
                size_t written = fwrite(sub_out, 1, sub_out_len, stdout);
                free(sub_out);
                c0_arena_free(arena);
                free(c0_data);
                return (written == sub_out_len) ? 0 : 1;
            }
            fprintf(stderr, "Error: Subprocess codec '%s' failed to collapse data\n",
                    sub->name);
            c0_arena_free(arena);
            free(c0_data);
            return 1;
        }
#endif
        fprintf(stderr, "Error: Failed to collapse C0 data (codec not found or invalid data)\n");
        c0_arena_free(arena);
        free(c0_data);
        return 1;
    }

    /* Write native bytes to stdout */
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    size_t written = fwrite(native_data, 1, out_len, stdout);
    if (written != out_len) {
        fprintf(stderr, "Error: Failed to write output\n");
        c0_arena_free(arena);
        free(c0_data);
        return 1;
    }

    c0_arena_free(arena);
    free(c0_data);
    return 0;
}

/**
 * Codecs command: list available codecs
 */
static int cmd_codecs(void) {
    size_t count = c0_codec_count();

    printf("Built-in codecs:\n\n");
    if (count == 0) {
        printf("  (none)\n");
    }
    for (size_t i = 0; i < count; i++) {
        C0CodecInfo info = c0_codec_info(i);
        printf("  %.*s", (int)info.name_len, info.name);

        /* Modes */
        if (info.supports_faithful && info.supports_editable) {
            printf("  [faithful, editable]");
        } else if (info.supports_faithful) {
            printf("  [faithful]");
        } else if (info.supports_editable) {
            printf("  [editable]");
        }

        printf("\n");
        printf("    %.*s\n", (int)info.description_len, info.description);
    }

#if HAS_SUBPROCESS_CODECS
    discover_subprocess_codecs();
    if (subprocess_codec_count > 0) {
        printf("\nExternal codecs (subprocess):\n\n");
        for (size_t i = 0; i < subprocess_codec_count; i++) {
            printf("  %s\n", subprocess_codecs[i].name);
            printf("    %s\n", subprocess_codecs[i].path);
        }
    }
#endif

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

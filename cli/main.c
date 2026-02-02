/**
 * C0 CLI - Command-line interface for C0 binary format
 *
 * Commands:
 *   encode - Read stdin as text, encode as C0 string, write binary to stdout
 *   decode - Read stdin as C0 binary, pretty-print the structure
 *
 * Usage:
 *   c0 encode < input.txt > output.c0
 *   c0 decode < input.c0
 *   echo "hello" | c0 encode | c0 decode
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../ffi/c0.h"

#define INITIAL_BUFFER_SIZE 4096

/* Forward declarations */
static void print_usage(const char* program_name);
static int cmd_encode(void);
static int cmd_decode(void);
static void pretty_print(const C0Value* val, int indent);
static char* read_stdin(size_t* out_len);
static void print_indent(int level);
static void print_escaped_string(const char* data, size_t len);

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
    } else {
        fprintf(stderr, "Error: Unknown command '%s'\n\n", argv[1]);
        print_usage(argv[0]);
        return 1;
    }
}

static void print_usage(const char* program_name) {
    fprintf(stderr, "C0 - Hierarchical Binary Data Stream Format\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Usage: %s <command>\n", program_name);
    fprintf(stderr, "\n");
    fprintf(stderr, "Commands:\n");
    fprintf(stderr, "  encode    Read text from stdin, encode as C0 string, write to stdout\n");
    fprintf(stderr, "  decode    Read C0 binary from stdin, pretty-print to stdout\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -h, --help    Show this help message\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  echo \"hello\" | %s encode > hello.c0\n", program_name);
    fprintf(stderr, "  %s decode < hello.c0\n", program_name);
    fprintf(stderr, "  echo \"hello\" | %s encode | %s decode\n", program_name, program_name);
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

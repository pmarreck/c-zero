/*
 * codec_host.c - discovery, metadata, selection and execution of c0 codec plugins
 *
 * Implements the host half of protocol c0-codec/1 (docs/plan_context/codec_plugins.md)
 * for POSIX (fork/exec, poll-driven pipes) and Windows (CreateProcess, writer thread).
 */
#if !defined(_WIN32)
#define _XOPEN_SOURCE 700 /* POSIX.1-2008 plus realpath */
#define _DARWIN_C_SOURCE
#endif

#include "codec_host.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../ffi/c0.h"

#ifdef _WIN32
#include <windows.h>
#define PATH_LIST_SEP ';'
#define DIR_SEP '\\'
#define EXE_SUFFIX ".exe"
#else
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#define PATH_LIST_SEP ':'
#define DIR_SEP '/'
#define EXE_SUFFIX ""
#endif

#define PLUGIN_PREFIX "c0-codec-"
#define PLUGIN_PREFIX_LEN 9
#define PROTOCOL "c0-codec/1"
#define MAX_PATH_LEN 4096

static CodecPlugin* plugins = NULL;
static size_t plugins_len = 0;
static size_t plugins_cap = 0;
static int discovered = 0;

static char* dup_range(const char* s, size_t len) {
    char* d = malloc(len + 1);
    if (!d) return NULL;
    memcpy(d, s, len);
    d[len] = '\0';
    return d;
}

static char* dup_str(const char* s) { return dup_range(s, strlen(s)); }

/* Codec names are restricted so they are safe in file names, argv and messages. */
static int valid_codec_name(const char* s, size_t len) {
    if (len == 0 || len > 64) return 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '-' || c == '_')) return 0;
    }
    return 1;
}

/* Extracts the codec name from a directory entry name, or returns 0. */
static int codec_name_from_entry(const char* entry, char* name, size_t name_cap) {
    size_t len = strlen(entry);
    if (len <= PLUGIN_PREFIX_LEN || strncmp(entry, PLUGIN_PREFIX, PLUGIN_PREFIX_LEN) != 0) return 0;
    const char* rest = entry + PLUGIN_PREFIX_LEN;
    size_t rest_len = len - PLUGIN_PREFIX_LEN;
#ifdef _WIN32
    if (rest_len <= 4 || _stricmp(rest + rest_len - 4, EXE_SUFFIX) != 0) return 0;
    rest_len -= 4;
#endif
    if (!valid_codec_name(rest, rest_len) || rest_len >= name_cap) return 0;
    memcpy(name, rest, rest_len);
    name[rest_len] = '\0';
    return 1;
}

static void add_plugin(const char* name, const char* path) {
    for (size_t i = 0; i < plugins_len; i++) {
        if (strcmp(plugins[i].name, name) == 0) return; /* first directory wins */
    }
    if (plugins_len == plugins_cap) {
        size_t cap = plugins_cap ? plugins_cap * 2 : 16;
        CodecPlugin* grown = realloc(plugins, cap * sizeof(CodecPlugin));
        if (!grown) return;
        plugins = grown;
        plugins_cap = cap;
    }
    CodecPlugin* p = &plugins[plugins_len];
    memset(p, 0, sizeof(*p));
    p->name = dup_str(name);
    p->path = dup_str(path);
    if (!p->name || !p->path) {
        free(p->name);
        free(p->path);
        return;
    }
    plugins_len++;
}

static int compare_names(const void* a, const void* b) {
    return strcmp(*(char* const*)a, *(char* const*)b);
}

/* Adds every plugin in one directory, in sorted name order. */
static void scan_dir(const char* dir) {
    if (!dir || !dir[0]) return;
    char** names = NULL;
    size_t names_len = 0, names_cap = 0;
    char name[128];

#ifdef _WIN32
    char pattern[MAX_PATH_LEN];
    snprintf(pattern, sizeof(pattern), "%s\\" PLUGIN_PREFIX "*" EXE_SUFFIX, dir);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (!codec_name_from_entry(fd.cFileName, name, sizeof(name))) continue;
#else
    DIR* d = opendir(dir);
    if (!d) return;
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        if (!codec_name_from_entry(e->d_name, name, sizeof(name))) continue;
        char full[MAX_PATH_LEN];
        snprintf(full, sizeof(full), "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(full, &st) != 0 || !S_ISREG(st.st_mode) || access(full, X_OK) != 0) continue;
#endif
        if (names_len == names_cap) {
            size_t cap = names_cap ? names_cap * 2 : 16;
            char** grown = realloc(names, cap * sizeof(char*));
            if (!grown) break;
            names = grown;
            names_cap = cap;
        }
        char* copy = dup_str(name);
        if (copy) names[names_len++] = copy;
#ifdef _WIN32
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    }
    closedir(d);
#endif

    if (names_len > 1) qsort(names, names_len, sizeof(char*), compare_names);
    for (size_t i = 0; i < names_len; i++) {
        char full[MAX_PATH_LEN];
        snprintf(full, sizeof(full), "%s%c" PLUGIN_PREFIX "%s" EXE_SUFFIX, dir, DIR_SEP, names[i]);
        add_plugin(names[i], full);
        free(names[i]);
    }
    free(names);
}

static void scan_path_list(const char* list) {
    if (!list) return;
    char* copy = dup_str(list);
    if (!copy) return;
    char* start = copy;
    for (char* p = copy;; p++) {
        if (*p == PATH_LIST_SEP || *p == '\0') {
            int end = *p == '\0';
            *p = '\0';
            scan_dir(start);
            if (end) break;
            start = p + 1;
        }
    }
    free(copy);
}

/* Directory containing the running executable, written into buf; returns 1 on success. */
static int own_exe_dir(const char* argv0, char* buf, size_t cap) {
    char path[MAX_PATH_LEN];
    int ok = 0;
#ifdef _WIN32
    (void)argv0;
    DWORD n = GetModuleFileNameA(NULL, path, sizeof(path));
    ok = n > 0 && n < sizeof(path);
#else
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (n > 0) {
        path[n] = '\0';
        ok = 1;
    }
#elif defined(__APPLE__)
    uint32_t size = sizeof(path);
    char raw[MAX_PATH_LEN];
    if (_NSGetExecutablePath(raw, &size) == 0 && realpath(raw, path)) ok = 1;
#endif
    if (!ok && argv0 && strchr(argv0, '/') && realpath(argv0, path)) ok = 1;
#endif
    if (!ok) return 0;
    char* slash = strrchr(path, DIR_SEP);
#ifdef _WIN32
    char* fwd = strrchr(path, '/');
    if (fwd > slash) slash = fwd;
#endif
    if (!slash) return 0;
    *slash = '\0';
    if (strlen(path) + 1 > cap) return 0;
    memcpy(buf, path, strlen(path) + 1);
    return 1;
}

void codec_host_discover(const char* argv0) {
    if (discovered) return;
    discovered = 1;

    const char* override = getenv("C0_CODEC_PATH");
    if (override) {
        scan_path_list(override);
        return;
    }
    char dir[MAX_PATH_LEN];
    if (own_exe_dir(argv0, dir, sizeof(dir))) scan_dir(dir);
#ifdef _WIN32
    const char* home = getenv("USERPROFILE");
#else
    const char* home = getenv("HOME");
#endif
    if (home) {
        char user_dir[MAX_PATH_LEN];
        snprintf(user_dir, sizeof(user_dir), "%s%c.c0%ccodecs", home, DIR_SEP, DIR_SEP);
        scan_dir(user_dir);
    }
    scan_path_list(getenv("PATH"));
}

size_t codec_host_count(void) { return plugins_len; }

CodecPlugin* codec_host_get(size_t index) { return index < plugins_len ? &plugins[index] : NULL; }

CodecPlugin* codec_host_find(const char* name) {
    for (size_t i = 0; i < plugins_len; i++) {
        if (strcmp(plugins[i].name, name) == 0) return &plugins[i];
    }
    return NULL;
}

/* ------------------------------------------------------------------------- */
/* info parsing                                                               */
/* ------------------------------------------------------------------------- */

static C0Value* get_field(const C0Value* obj, const char* key) {
    if (!obj || !c0_is_object(obj)) return NULL;
    size_t klen = strlen(key);
    size_t n = c0_object_len(obj);
    for (size_t i = 0; i < n; i++) {
        size_t len;
        const char* k = c0_object_key(obj, i, &len);
        if (len == klen && memcmp(k, key, len) == 0) return c0_object_value(obj, i);
    }
    return NULL;
}

/* Copies a string field; a missing field yields "" when optional, NULL (error) otherwise. */
static char* get_string(const C0Value* obj, const char* key, int optional) {
    C0Value* v = get_field(obj, key);
    if (!v) return optional ? dup_str("") : NULL;
    if (!c0_is_string(v)) return NULL;
    size_t len;
    const char* s = c0_string_data(v, &len);
    if (memchr(s, '\0', len)) return NULL;
    return dup_range(s, len);
}

static int get_bool(const C0Value* obj, const char* key, int* out) {
    char* s = get_string(obj, key, 0);
    if (!s) return 0;
    int ok = 1;
    if (strcmp(s, "true") == 0) *out = 1;
    else if (strcmp(s, "false") == 0) *out = 0;
    else ok = 0;
    free(s);
    return ok;
}

static int get_string_list(const C0Value* obj, const char* key, char*** out, size_t* out_len) {
    C0Value* arr = get_field(obj, key);
    *out = NULL;
    *out_len = 0;
    if (!arr) return 1;
    if (!c0_is_array(arr)) return 0;
    size_t n = c0_array_len(arr);
    if (n == 0) return 1;
    char** items = calloc(n, sizeof(char*));
    if (!items) return 0;
    for (size_t i = 0; i < n; i++) {
        C0Value* v = c0_array_get(arr, i);
        if (!c0_is_string(v)) { *out = items; *out_len = i; return 0; }
        size_t len;
        const char* s = c0_string_data(v, &len);
        items[i] = dup_range(s, len);
        if (!items[i]) { *out = items; *out_len = i; return 0; }
    }
    *out = items;
    *out_len = n;
    return 1;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_size(const char* s, size_t* out) {
    if (!s[0]) return 0;
    size_t v = 0;
    for (const char* p = s; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        size_t d = (size_t)(*p - '0');
        if (v > (SIZE_MAX - d) / 10) return 0;
        v = v * 10 + d;
    }
    *out = v;
    return 1;
}

static int parse_magic(const C0Value* info, CodecPlugin* p) {
    C0Value* arr = get_field(info, "magic");
    if (!arr) return 1;
    if (!c0_is_array(arr)) return 0;
    size_t n = c0_array_len(arr);
    if (n == 0) return 1;
    p->magic = calloc(n, sizeof(CodecMagic));
    if (!p->magic) return 0;
    for (size_t i = 0; i < n; i++) {
        C0Value* m = c0_array_get(arr, i);
        char* off = get_string(m, "offset", 0);
        char* hex = get_string(m, "hex", 0);
        size_t hex_len = hex ? strlen(hex) : 0;
        int ok = off && hex && parse_size(off, &p->magic[i].offset) && hex_len > 0 && hex_len % 2 == 0;
        if (ok) {
            p->magic[i].len = hex_len / 2;
            p->magic[i].bytes = malloc(p->magic[i].len);
            ok = p->magic[i].bytes != NULL;
            for (size_t j = 0; ok && j < p->magic[i].len; j++) {
                int hi = hex_digit(hex[2 * j]), lo = hex_digit(hex[2 * j + 1]);
                if (hi < 0 || lo < 0) ok = 0;
                else p->magic[i].bytes[j] = (uint8_t)(hi << 4 | lo);
            }
        }
        free(off);
        free(hex);
        p->magic_len = i + 1;
        if (!ok) return 0;
    }
    return 1;
}

static int parse_args(const C0Value* info, CodecPlugin* p) {
    C0Value* arr = get_field(info, "args");
    if (!arr) return 1;
    if (!c0_is_array(arr)) return 0;
    size_t n = c0_array_len(arr);
    if (n == 0) return 1;
    p->args = calloc(n, sizeof(CodecArgSpec));
    if (!p->args) return 0;
    for (size_t i = 0; i < n; i++) {
        C0Value* a = c0_array_get(arr, i);
        p->args[i].name = get_string(a, "name", 0);
        p->args[i].value_name = get_string(a, "value_name", 1);
        p->args[i].description = get_string(a, "description", 1);
        p->args_len = i + 1;
        if (!p->args[i].name || !p->args[i].value_name || !p->args[i].description) return 0;
        if (!valid_codec_name(p->args[i].name, strlen(p->args[i].name))) return 0;
    }
    return 1;
}

static int fail_info(CodecPlugin* p, const char* fmt, const char* detail) {
    char msg[512];
    snprintf(msg, sizeof(msg), fmt, detail ? detail : "");
    free(p->info_error);
    p->info_error = dup_str(msg);
    p->info_state = -1;
    return 0;
}

int codec_host_load_info(CodecPlugin* p) {
    if (p->info_state != 0) return p->info_state == 1;
    const char* args[] = {"info"};
    uint8_t* out = NULL;
    size_t out_len = 0;
    int exit_code = 0;
    if (codec_host_run(p->path, args, 1, NULL, 0, &out, &out_len, &exit_code) != 0)
        return fail_info(p, "could not run '%s info'", p->path);
    if (exit_code != 0) {
        free(out);
        char code[32];
        snprintf(code, sizeof(code), "%d", exit_code);
        return fail_info(p, "'info' exited with status %s", code);
    }

    C0Arena* arena = c0_arena_new();
    C0Value* info = arena ? c0_decode(arena, out, out_len) : NULL;
    free(out);
    if (!info || !c0_is_object(info)) {
        if (arena) c0_arena_free(arena);
        return fail_info(p, "'info' did not print a C0 object%s", NULL);
    }

    char* protocol = get_string(info, "protocol", 0);
    char* name = get_string(info, "name", 0);
    int ok = 1;
    if (!protocol || strcmp(protocol, PROTOCOL) != 0) {
        fail_info(p, "unsupported protocol '%s' (expected " PROTOCOL ")", protocol ? protocol : "(missing)");
        ok = 0;
    } else if (!name || strcmp(name, p->name) != 0) {
        fail_info(p, "'info' names the codec '%s', which does not match its executable name", name ? name : "(missing)");
        ok = 0;
    } else {
        p->description = get_string(info, "description", 1);
        p->help = get_string(info, "help", 1);
        ok = p->description && p->help &&
             get_bool(info, "faithful", &p->faithful) && get_bool(info, "editable", &p->editable) &&
             get_string_list(info, "extensions", &p->extensions, &p->extensions_len) &&
             get_string_list(info, "format_names", &p->format_names, &p->format_names_len) &&
             parse_magic(info, p) && parse_args(info, p);
        if (!ok) fail_info(p, "malformed 'info' metadata%s", NULL);
    }
    free(protocol);
    free(name);
    c0_arena_free(arena);
    if (ok) p->info_state = 1;
    return ok;
}

/* ------------------------------------------------------------------------- */
/* selection                                                                  */
/* ------------------------------------------------------------------------- */

static int ascii_ieq(const char* a, const char* b) {
    for (; *a && *b; a++, b++) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    }
    return *a == *b;
}

CodecPlugin* codec_host_detect(const uint8_t* data, size_t len, const char* filename) {
    for (size_t i = 0; i < plugins_len; i++) {
        CodecPlugin* p = &plugins[i];
        if (!codec_host_load_info(p)) continue;
        for (size_t m = 0; m < p->magic_len; m++) {
            const CodecMagic* mg = &p->magic[m];
            if (mg->offset <= len && mg->len <= len - mg->offset &&
                memcmp(data + mg->offset, mg->bytes, mg->len) == 0)
                return p;
        }
    }
    if (!filename) return NULL;
    const char* base = filename;
    for (const char* s = filename; *s; s++) {
        if (*s == '/' || *s == '\\') base = s + 1;
    }
    const char* dot = strrchr(base, '.');
    if (!dot || dot == base) return NULL;
    for (size_t i = 0; i < plugins_len; i++) {
        CodecPlugin* p = &plugins[i];
        if (p->info_state != 1) continue;
        for (size_t e = 0; e < p->extensions_len; e++) {
            if (ascii_ieq(dot, p->extensions[e])) return p;
        }
    }
    return NULL;
}

CodecPlugin* codec_host_find_format(const uint8_t* format, size_t format_len) {
    for (size_t i = 0; i < plugins_len; i++) {
        CodecPlugin* p = &plugins[i];
        if (!codec_host_load_info(p)) continue;
        for (size_t f = 0; f < p->format_names_len; f++) {
            if (strlen(p->format_names[f]) == format_len && memcmp(p->format_names[f], format, format_len) == 0)
                return p;
        }
        if (strlen(p->name) == format_len && memcmp(p->name, format, format_len) == 0) return p;
    }
    return NULL;
}

long codec_host_arg_index(const CodecPlugin* p, const char* key) {
    for (size_t i = 0; i < p->args_len; i++) {
        if (strcmp(p->args[i].name, key) == 0) return (long)i;
    }
    return -1;
}

/* ------------------------------------------------------------------------- */
/* process execution                                                          */
/* ------------------------------------------------------------------------- */

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
} ByteBuf;

static int buf_reserve(ByteBuf* b, size_t extra) {
    if (b->cap - b->len >= extra) return 1;
    size_t cap = b->cap ? b->cap : 65536;
    while (cap - b->len < extra) {
        if (cap > SIZE_MAX / 2) return 0;
        cap *= 2;
    }
    uint8_t* grown = realloc(b->data, cap);
    if (!grown) return 0;
    b->data = grown;
    b->cap = cap;
    return 1;
}

#ifdef _WIN32

/* Appends one argument with the quoting CommandLineToArgvW and the MSVC runtime expect. */
static int append_quoted(ByteBuf* cmd, const char* arg) {
    int needs = arg[0] == '\0' || strpbrk(arg, " \t\n\v\"") != NULL;
    if (!buf_reserve(cmd, strlen(arg) * 2 + 4)) return 0;
    if (cmd->len) cmd->data[cmd->len++] = ' ';
    if (!needs) {
        memcpy(cmd->data + cmd->len, arg, strlen(arg));
        cmd->len += strlen(arg);
        return 1;
    }
    cmd->data[cmd->len++] = '"';
    for (const char* p = arg;; p++) {
        size_t backslashes = 0;
        while (*p == '\\') { backslashes++; p++; }
        if (!buf_reserve(cmd, backslashes * 2 + 2)) return 0;
        if (*p == '\0') {
            for (size_t i = 0; i < backslashes * 2; i++) cmd->data[cmd->len++] = '\\';
            break;
        }
        size_t emit = *p == '"' ? backslashes * 2 + 1 : backslashes;
        for (size_t i = 0; i < emit; i++) cmd->data[cmd->len++] = '\\';
        cmd->data[cmd->len++] = (uint8_t)*p;
    }
    cmd->data[cmd->len++] = '"';
    return 1;
}

typedef struct {
    HANDLE pipe;
    const uint8_t* data;
    size_t len;
} WriterJob;

static DWORD WINAPI writer_thread(LPVOID param) {
    WriterJob* job = (WriterJob*)param;
    size_t off = 0;
    while (off < job->len) {
        DWORD chunk = (DWORD)(job->len - off > 1u << 20 ? 1u << 20 : job->len - off);
        DWORD written = 0;
        if (!WriteFile(job->pipe, job->data + off, chunk, &written, NULL)) break;
        off += written;
    }
    CloseHandle(job->pipe);
    return 0;
}

int codec_host_run(const char* path, const char* const* args, size_t args_len,
                   const uint8_t* input, size_t input_len,
                   uint8_t** output, size_t* output_len, int* exit_code) {
    ByteBuf cmd = {0};
    if (!append_quoted(&cmd, path)) { free(cmd.data); return -1; }
    for (size_t i = 0; i < args_len; i++) {
        if (!append_quoted(&cmd, args[i])) { free(cmd.data); return -1; }
    }
    if (!buf_reserve(&cmd, 1)) { free(cmd.data); return -1; }
    cmd.data[cmd.len] = '\0';

    SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
    HANDLE in_r, in_w, out_r, out_w;
    if (!CreatePipe(&in_r, &in_w, &sa, 0)) { free(cmd.data); return -1; }
    if (!CreatePipe(&out_r, &out_w, &sa, 0)) {
        CloseHandle(in_r); CloseHandle(in_w); free(cmd.data);
        return -1;
    }
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION pi;
    BOOL started = CreateProcessA(path, (char*)cmd.data, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    free(cmd.data);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (!started) {
        CloseHandle(in_w); CloseHandle(out_r);
        return -1;
    }

    WriterJob job = {in_w, input, input_len};
    HANDLE writer = CreateThread(NULL, 0, writer_thread, &job, 0, NULL);
    if (!writer) CloseHandle(in_w);

    ByteBuf out = {0};
    int failed = 0;
    for (;;) {
        if (!buf_reserve(&out, 65536)) { failed = 1; break; }
        DWORD n = 0;
        if (!ReadFile(out_r, out.data + out.len, (DWORD)(out.cap - out.len), &n, NULL) || n == 0) break;
        out.len += n;
    }
    CloseHandle(out_r);
    if (writer) {
        WaitForSingleObject(writer, INFINITE);
        CloseHandle(writer);
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    if (failed) { free(out.data); return -1; }
    *output = out.data;
    *output_len = out.len;
    *exit_code = (int)code;
    return 0;
}

#else /* POSIX */

int codec_host_run(const char* path, const char* const* args, size_t args_len,
                   const uint8_t* input, size_t input_len,
                   uint8_t** output, size_t* output_len, int* exit_code) {
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0) return -1;
    if (pipe(out_pipe) != 0) {
        close(in_pipe[0]); close(in_pipe[1]);
        return -1;
    }
    char** argv = calloc(args_len + 2, sizeof(char*));
    if (!argv) {
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]);
        return -1;
    }
    argv[0] = (char*)path;
    for (size_t i = 0; i < args_len; i++) argv[i + 1] = (char*)args[i];

    /* A plugin that exits early must surface as EPIPE, not kill the host. */
    struct sigaction ignore, previous;
    memset(&ignore, 0, sizeof(ignore));
    ignore.sa_handler = SIG_IGN;
    sigaction(SIGPIPE, &ignore, &previous);

    pid_t pid = fork();
    if (pid < 0) {
        sigaction(SIGPIPE, &previous, NULL);
        free(argv);
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]);
        return -1;
    }
    if (pid == 0) {
        signal(SIGPIPE, SIG_DFL);
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]);
        execv(path, argv);
        _exit(127);
    }
    free(argv);
    close(in_pipe[0]);
    close(out_pipe[1]);
    int in_fd = in_pipe[1];
    int out_fd = out_pipe[0];
    fcntl(in_fd, F_SETFL, fcntl(in_fd, F_GETFL) | O_NONBLOCK);
    if (input_len == 0) {
        close(in_fd);
        in_fd = -1;
    }

    ByteBuf out = {0};
    size_t written = 0;
    int failed = 0;
    while (out_fd >= 0) {
        struct pollfd fds[2];
        nfds_t nfds = 0;
        fds[nfds++] = (struct pollfd){out_fd, POLLIN, 0};
        if (in_fd >= 0) fds[nfds++] = (struct pollfd){in_fd, POLLOUT, 0};
        if (poll(fds, nfds, -1) < 0) {
            if (errno == EINTR) continue;
            failed = 1;
            break;
        }
        if (in_fd >= 0 && fds[1].revents) {
            if (fds[1].revents & POLLOUT) {
                ssize_t n = write(in_fd, input + written, input_len - written);
                if (n > 0) written += (size_t)n;
                else if (n < 0 && errno != EAGAIN && errno != EINTR) written = input_len; /* plugin stopped reading */
            } else {
                written = input_len; /* POLLERR/POLLHUP: reader is gone */
            }
            if (written >= input_len) {
                close(in_fd);
                in_fd = -1;
            }
        }
        if (fds[0].revents) {
            if (!buf_reserve(&out, 65536)) {
                failed = 1;
                break;
            }
            ssize_t n = read(out_fd, out.data + out.len, out.cap - out.len);
            if (n > 0) out.len += (size_t)n;
            else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
                close(out_fd);
                out_fd = -1;
            }
        }
    }
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    sigaction(SIGPIPE, &previous, NULL);
    if (failed) {
        free(out.data);
        return -1;
    }
    *output = out.data;
    *output_len = out.len;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    return 0;
}

#endif

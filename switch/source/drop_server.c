#define _POSIX_C_SOURCE 200809L
#include "drop_server.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <dirent.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define HEADER_MAX 8192
#define BLOCK_SIZE 65536
#define PATH_BUFFER 768
#define DIRECTORY_PAGE_SIZE 120
#define DIRECTORY_RESPONSE_MAX 131072

static bool send_all(int fd, const void *bytes, size_t count) {
    const unsigned char *cursor = bytes;
    while (count) {
        ssize_t n = send(fd, cursor, count, 0);
        if (n <= 0) return false;
        cursor += n;
        count -= (size_t)n;
    }
    return true;
}

static void set_status(DropServer *s, const char *message) {
    pthread_mutex_lock(&s->mutex);
    snprintf(s->status, sizeof(s->status), "%s", message);
    pthread_mutex_unlock(&s->mutex);
}

static void reply(int fd, int status, const char *reason, const char *body) {
    char header[512];
    size_t size = strlen(body);
    int len = snprintf(header, sizeof(header),
                       "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                       "Content-Length: %zu\r\nConnection: close\r\n"
                       "Cache-Control: no-store\r\n\r\n", status, reason, size);
    if (len > 0 && len < (int)sizeof(header)) {
        (void)send_all(fd, header, (size_t)len);
        (void)send_all(fd, body, size);
    }
}

static int unhex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool decode_component(const char *source, char *out, size_t limit) {
    size_t i = 0;
    while (*source) {
        unsigned char ch = (unsigned char)*source++;
        if (ch == '%') {
            int hi = unhex(source[0]);
            if (!source[0] || !source[1] || hi < 0 || unhex(source[1]) < 0) return false;
            ch = (unsigned char)((hi << 4) | unhex(source[1]));
            source += 2;
        } else if (ch == '+') {
            ch = ' ';
        }
        if (ch < 32 || ch == 127 || i + 1 >= limit) return false;
        out[i++] = (char)ch;
    }
    out[i] = '\0';
    return true;
}

static bool query_value(const char *path, const char *key, char *out, size_t limit) {
    const char *part = strchr(path, '?');
    if (!part) return false;
    part++;
    size_t keylen = strlen(key);
    while (*part) {
        const char *end = strchr(part, '&');
        if (!end) end = part + strlen(part);
        if ((size_t)(end - part) > keylen + 1 &&
            strncmp(part, key, keylen) == 0 && part[keylen] == '=') {
            char encoded[1024];
            size_t n = (size_t)(end - (part + keylen + 1));
            if (n >= sizeof(encoded)) return false;
            memcpy(encoded, part + keylen + 1, n);
            encoded[n] = '\0';
            return decode_component(encoded, out, limit);
        }
        if (!*end) break;
        part = end + 1;
    }
    return false;
}

static bool filename_allowed(const char *name) {
    if (!name[0] || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return false;
    if (name[0] == '.') return false;  // No hidden files or stale upload names.
    for (const char *p = name; *p; p++) {
        if (*p == '/' || *p == '\\' || *p == ':') return false;
    }
    return true;
}

// The API exposes the SD card only. Paths are always absolute within this
// root, and every component is checked so `..`, device names and symlinks
// cannot move browsing or uploads outside sdmc:/.
static bool safe_directory(DropServer *s, const char *path, char *out, size_t cap) {
    if (!path || path[0] != '/') return false;
    size_t used = strlen(s->root);
    if (used + strlen(path) + 1 >= cap) return false;
    memcpy(out, s->root, used);
    out[used] = '\0';

    const char *part = path + 1;
    if (!*part) {
        snprintf(out + used, cap - used, "/");
    } else {
        while (*part) {
            const char *end = strchr(part, '/');
            if (!end) end = part + strlen(part);
            size_t length = (size_t)(end - part);
            if (!length || (length == 1 && part[0] == '.') ||
                (length == 2 && part[0] == '.' && part[1] == '.')) return false;
            for (size_t i = 0; i < length; i++) {
                unsigned char c = (unsigned char)part[i];
                if (c < 32 || c == 127 || c == '\\' || c == ':' || c == '?') return false;
            }
            if (used + length + 2 >= cap) return false;
            out[used++] = '/';
            memcpy(out + used, part, length);
            used += length;
            out[used] = '\0';
            struct stat st;
            if (lstat(out, &st) != 0 || !S_ISDIR(st.st_mode)) return false;
            if (!*end) break;
            part = end + 1;
        }
    }
    struct stat st;
    return lstat(out, &st) == 0 && S_ISDIR(st.st_mode);
}

typedef struct { char *text; size_t used; size_t cap; } Json;

static bool json_printf(Json *json, const char *format, ...) {
    if (json->used >= json->cap) return false;
    va_list arguments;
    va_start(arguments, format);
    int n = vsnprintf(json->text + json->used, json->cap - json->used,
                      format, arguments);
    va_end(arguments);
    if (n < 0 || (size_t)n >= json->cap - json->used) return false;
    json->used += (size_t)n;
    return true;
}

static bool json_string(Json *json, const char *value) {
    if (!json_printf(json, "\"")) return false;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        if (*p == '"' || *p == '\\') {
            if (!json_printf(json, "\\%c", *p)) return false;
        } else if (*p < 32 || *p == 127) {
            if (!json_printf(json, "\\u%04x", *p)) return false;
        } else if (!json_printf(json, "%c", *p)) return false;
    }
    return json_printf(json, "\"");
}

static void browse(DropServer *s, int fd, const char *path, unsigned offset) {
    char target[PATH_BUFFER];
    if (!safe_directory(s, path, target, sizeof(target))) {
        reply(fd, 400, "Bad Request", "{\"error\":\"Invalid or inaccessible SD folder\"}");
        return;
    }
    DIR *directory = opendir(target);
    if (!directory) {
        reply(fd, 403, "Forbidden", "{\"error\":\"Unable to browse folder\"}");
        return;
    }
    char *bytes = calloc(1, DIRECTORY_RESPONSE_MAX);
    if (!bytes) {
        closedir(directory);
        reply(fd, 500, "Internal Server Error", "{\"error\":\"Out of memory\"}");
        return;
    }
    Json json = {.text = bytes, .cap = DIRECTORY_RESPONSE_MAX};
    bool okay = json_printf(&json, "{\"path\":") && json_string(&json, path) &&
                json_printf(&json, ",\"items\":[");
    unsigned index = 0, page_count = 0;
    bool has_more = false;
    struct dirent *entry;
    while (okay && (entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (strchr(entry->d_name, '/') || strchr(entry->d_name, '\\')) continue;
        char file[PATH_BUFFER];
        int len = snprintf(file, sizeof(file), "%s/%s", target, entry->d_name);
        if (len < 0 || (size_t)len >= sizeof(file)) continue;
        struct stat st;
        if (lstat(file, &st) != 0 || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) continue;
        if (index++ < offset) continue;
        if (page_count >= DIRECTORY_PAGE_SIZE) { has_more = true; break; }
        okay = json_printf(&json, "%s{\"name\":", page_count ? "," : "") &&
               json_string(&json, entry->d_name) &&
               json_printf(&json, ",\"type\":\"%s\",\"size\":%llu}",
                           S_ISDIR(st.st_mode) ? "folder" : "file",
                           (unsigned long long)st.st_size);
        page_count++;
    }
    closedir(directory);
    okay = okay && json_printf(&json, "] ,\"nextOffset\":");
    if (has_more) okay = okay && json_printf(&json, "%u}", offset + page_count);
    else okay = okay && json_printf(&json, "null}");
    if (okay) reply(fd, 200, "OK", bytes);
    else reply(fd, 500, "Internal Server Error", "{\"error\":\"Directory listing too large\"}");
    free(bytes);
}

static bool read_headers(int fd, char *buf, size_t capacity) {
    size_t n = 0;
    while (n + 1 < capacity) {
        ssize_t r = recv(fd, buf + n, 1, 0);
        if (r <= 0) return false;
        n += (size_t)r;
        if (n >= 4 && memcmp(buf + n - 4, "\r\n\r\n", 4) == 0) {
            buf[n] = '\0';
            return true;
        }
    }
    return false;
}

static bool content_length(const char *headers, unsigned long long *length) {
    const char *p = strstr(headers, "\r\n");
    if (!p) return false;
    while (*(p += 2) && *p != '\r') {
        const char *e = strstr(p, "\r\n");
        if (!e) break;
        if (strncasecmp(p, "Content-Length:", 15) == 0) {
            p += 15;
            while (*p == ' ' || *p == '\t') p++;
            if (!isdigit((unsigned char)*p)) return false;
            errno = 0;
            char *stop;
            unsigned long long parsed = strtoull(p, &stop, 10);
            while (*stop == ' ' || *stop == '\t') stop++;
            if (errno != 0 || stop != e) return false;
            *length = parsed;
            return true;
        }
        p = e;
    }
    return false;
}

static bool unique_path(const char *root, const char *name, char *out, size_t outcap) {
    char stem[128], extension[32] = "";
    snprintf(stem, sizeof(stem), "%s", name);
    char *dot = strrchr(stem, '.');
    if (dot && dot != stem && strlen(dot) <= sizeof(extension) - 1) {
        snprintf(extension, sizeof(extension), "%s", dot);
        *dot = '\0';
    }
    for (unsigned i = 0; i < 10000; i++) {
        int len;
        if (i == 0) len = snprintf(out, outcap, "%s/%s", root, name);
        else len = snprintf(out, outcap, "%s/%s (%u)%s", root, stem, i + 1, extension);
        if (len < 0 || (size_t)len >= outcap) return false;
        struct stat st;
        if (lstat(out, &st) != 0 && errno == ENOENT) return true;
    }
    return false;
}

static void upload(DropServer *s, int fd, const char *name, const char *directory,
                   unsigned long long length) {
    if (length == 0 || length > DROP_MAX_BYTES) {
        reply(fd, 413, "Payload Too Large", "{\"error\":\"Invalid file size\"}");
        return;
    }
    char target[PATH_BUFFER], final[PATH_BUFFER], partial[PATH_BUFFER];
    if (!safe_directory(s, directory, target, sizeof(target))) {
        reply(fd, 400, "Bad Request", "{\"error\":\"Invalid or inaccessible destination\"}");
        return;
    }
    if (!unique_path(target, name, final, sizeof(final))) {
        reply(fd, 409, "Conflict", "{\"error\":\"No available filename\"}");
        return;
    }
    int len = snprintf(partial, sizeof(partial), "%s/.switchdrop-%s.part", target, s->token);
    if (len < 0 || (size_t)len >= sizeof(partial)) {
        reply(fd, 500, "Internal Server Error", "{\"error\":\"Path too long\"}");
        return;
    }
    int out = open(partial, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (out < 0) {
        reply(fd, 507, "Insufficient Storage", "{\"error\":\"Cannot open SD destination\"}");
        return;
    }

    pthread_mutex_lock(&s->mutex);
    snprintf(s->last_file, sizeof(s->last_file), "%s", name);
    s->bytes_received = 0;
    s->bytes_expected = length;
    snprintf(s->status, sizeof(s->status), "Receiving file...");
    pthread_mutex_unlock(&s->mutex);

    bool success = true;
    unsigned long long received = 0;
    unsigned char buffer[BLOCK_SIZE];
    while (received < length && atomic_load(&s->running)) {
        size_t wanted = (length - received) < BLOCK_SIZE ? (size_t)(length - received) : BLOCK_SIZE;
        ssize_t count = recv(fd, buffer, wanted, 0);
        if (count <= 0) { success = false; break; }
        ssize_t written = 0;
        while (written < count) {
            ssize_t step = write(out, buffer + written, (size_t)(count - written));
            if (step <= 0) { success = false; break; }
            written += step;
        }
        if (!success) break;
        received += (unsigned long long)count;
        pthread_mutex_lock(&s->mutex);
        s->bytes_received = received;
        pthread_mutex_unlock(&s->mutex);
    }
    if (received != length) success = false;
    if (close(out) != 0) success = false;
    if (success && rename(partial, final) != 0) success = false;
    if (!success) {
        unlink(partial);
        set_status(s, "Transfer failed. Try again.");
        reply(fd, 500, "Internal Server Error", "{\"error\":\"File transfer was interrupted\"}");
        return;
    }
    pthread_mutex_lock(&s->mutex);
    s->files_received++;
    snprintf(s->status, sizeof(s->status), "File received!");
    pthread_mutex_unlock(&s->mutex);
    reply(fd, 201, "Created", "{\"ok\":true}");
}

static void handle_client(DropServer *s, int fd) {
    struct timeval timeout = {.tv_sec = 20, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    char headers[HEADER_MAX], method[8], path[1024], version[16], token[64];
    if (!read_headers(fd, headers, sizeof(headers))) return;
    if (sscanf(headers, "%7s %1023s %15s", method, path, version) != 3 ||
        strcmp(version, "HTTP/1.1") != 0) {
        reply(fd, 400, "Bad Request", "{\"error\":\"Invalid request\"}");
        return;
    }
    if (!query_value(path, "t", token, sizeof(token)) || strcmp(token, s->token) != 0) {
        reply(fd, 403, "Forbidden", "{\"error\":\"Scan the QR code to pair\"}");
        return;
    }
    if (strcmp(method, "GET") == 0 && strncmp(path, "/health?", 8) == 0) {
        reply(fd, 200, "OK", "{\"name\":\"SwitchDrop\",\"protocol\":2}");
        return;
    }
    if (strcmp(method, "GET") == 0 && strncmp(path, "/browse?", 8) == 0) {
        char directory[512] = "/";
        char offset_text[24];
        unsigned offset = 0;
        if (strstr(path, "dir=") && !query_value(path, "dir", directory, sizeof(directory))) {
            reply(fd, 400, "Bad Request", "{\"error\":\"Invalid folder\"}");
            return;
        }
        if (query_value(path, "offset", offset_text, sizeof(offset_text))) {
            char *end;
            errno = 0;
            unsigned long parsed = strtoul(offset_text, &end, 10);
            if (errno || *end || end == offset_text || parsed > 1000000) {
                reply(fd, 400, "Bad Request", "{\"error\":\"Invalid page\"}");
                return;
            }
            offset = (unsigned)parsed;
        }
        browse(s, fd, directory, offset);
        return;
    }
    if (strcmp(method, "POST") == 0 && strncmp(path, "/upload?", 8) == 0) {
        char filename[128];
        char directory[512] = "/switch/switchdrop/inbox";
        unsigned long long length;
        if (!query_value(path, "name", filename, sizeof(filename)) ||
            !filename_allowed(filename)) {
            reply(fd, 400, "Bad Request", "{\"error\":\"Invalid filename\"}");
        } else if (strstr(path, "dir=") && !query_value(path, "dir", directory, sizeof(directory))) {
            reply(fd, 400, "Bad Request", "{\"error\":\"Invalid destination\"}");
        } else if (!content_length(headers, &length)) {
            reply(fd, 411, "Length Required", "{\"error\":\"Content-Length is required\"}");
        } else {
            upload(s, fd, filename, directory, length);
        }
        return;
    }
    reply(fd, 404, "Not Found", "{\"error\":\"Not found\"}");
}

static void *server_loop(void *user) {
    DropServer *s = (DropServer *)user;
    while (atomic_load(&s->running)) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(s->listen_fd, &fds);
        struct timeval timeout = {.tv_sec = 0, .tv_usec = 200000};
        int result = select(s->listen_fd + 1, &fds, NULL, NULL, &timeout);
        if (result <= 0) continue;
        int fd = accept(s->listen_fd, NULL, NULL);
        if (fd >= 0) {
            handle_client(s, fd);
            close(fd);
        }
    }
    return NULL;
}

bool drop_server_start(DropServer *s, const char *root, const char *token) {
    memset(s, 0, sizeof(*s));
    s->listen_fd = -1;
    snprintf(s->root, sizeof(s->root), "%s", root);
    snprintf(s->token, sizeof(s->token), "%s", token);
    pthread_mutex_init(&s->mutex, NULL);
    snprintf(s->status, sizeof(s->status), "Ready to receive");
    s->listen_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s->listen_fd < 0) goto fail;
    int reuse = 1;
    setsockopt(s->listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(DROP_PORT),
                                  .sin_addr.s_addr = INADDR_ANY};
    if (bind(s->listen_fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(s->listen_fd, 3) != 0) goto fail;
    atomic_store(&s->running, true);
    if (pthread_create(&s->thread, NULL, server_loop, s) != 0) goto fail;
    return true;
fail:
    atomic_store(&s->running, false);
    if (s->listen_fd >= 0) close(s->listen_fd);
    pthread_mutex_destroy(&s->mutex);
    return false;
}

void drop_server_stop(DropServer *s) {
    if (!atomic_load(&s->running)) return;
    atomic_store(&s->running, false);
    pthread_join(s->thread, NULL);
    close(s->listen_fd);
    pthread_mutex_destroy(&s->mutex);
}

void drop_server_status(DropServer *s, char *status, size_t status_size,
                        char *filename, size_t filename_size, unsigned *files,
                        unsigned long long *received, unsigned long long *expected) {
    pthread_mutex_lock(&s->mutex);
    snprintf(status, status_size, "%s", s->status);
    snprintf(filename, filename_size, "%s", s->last_file);
    *files = s->files_received;
    *received = s->bytes_received;
    *expected = s->bytes_expected;
    pthread_mutex_unlock(&s->mutex);
}

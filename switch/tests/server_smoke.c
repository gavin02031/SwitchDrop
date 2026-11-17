#define _POSIX_C_SOURCE 200809L
#include "../source/drop_server.h"
#include <arpa/inet.h>
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static char response_body[131072];

static int send_request(const char *request, const char *body, size_t bodylen) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_in addr = { .sin_family = AF_INET,
        .sin_port = htons(DROP_PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(send(fd, request, strlen(request), 0) == (ssize_t)strlen(request));
    if (bodylen) assert(send(fd, body, bodylen, 0) == (ssize_t)bodylen);
    shutdown(fd, SHUT_WR);
    size_t used = 0;
    ssize_t n;
    while (used + 1 < sizeof(response_body) &&
           (n = recv(fd, response_body + used, sizeof(response_body) - 1 - used, 0)) > 0)
        used += (size_t)n;
    assert(used > 12);
    response_body[used] = '\0';
    close(fd);
    int code = 0;
    assert(sscanf(response_body, "HTTP/1.1 %d", &code) == 1);
    return code;
}

int main(void) {
    char folder[] = "/tmp/switchdrop-test-XXXXXX";
    assert(mkdtemp(folder));
    char nested[512];
    snprintf(nested, sizeof(nested), "%s/Mods", folder);
    assert(mkdir(nested, 0700) == 0);
    const char *token = "1234567890abcdef1234567890abcdef";
    DropServer server;
    assert(drop_server_start(&server, folder, token));
    char request[1024];
    snprintf(request, sizeof(request),
             "GET /health?t=%s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "\"protocol\":2"));
    assert(strstr(response_body, "\"download\":true"));
    assert(strstr(response_body, "\"preview\":true"));
    assert(send_request("GET /health?t=wrong HTTP/1.1\r\n\r\n", NULL, 0) == 403);
    snprintf(request, sizeof(request),
             "GET /browse?t=%s&dir=%%2F HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "\"name\":\"Mods\",\"type\":\"folder\""));
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&dir=%%2F&name=test.txt HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
    assert(send_request(request, "hello", 5) == 201);
    assert(send_request(request, "world", 5) == 201);
    char filename[512];
    snprintf(filename, sizeof(filename), "%s/test.txt", folder);
    FILE *first = fopen(filename, "rb");
    assert(first);
    char content[8] = {0};
    assert(fread(content, 1, 5, first) == 5);
    assert(strcmp(content, "hello") == 0);
    fclose(first);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&dir=%%2FMods&name=inside.txt HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
    assert(send_request(request, "inner", 5) == 201);
    snprintf(request, sizeof(request),
             "GET /browse?t=%s&dir=%%2FMods HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "\"name\":\"inside.txt\",\"type\":\"file\""));
    snprintf(request, sizeof(request),
             "GET /browse?t=%s&dir=%%2F..%%2Fetc HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 400);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&dir=%%2FMods%%2F..&name=no.txt HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
    assert(send_request(request, "hello", 5) == 400);
    snprintf(filename, sizeof(filename), "%s/link", folder);
    assert(symlink("/tmp", filename) == 0);
    snprintf(request, sizeof(request),
             "GET /browse?t=%s&dir=%%2Flink HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 400);
    snprintf(filename, sizeof(filename), "%s/test (2).txt", folder);
    first = fopen(filename, "rb");
    assert(first);
    assert(fread(content, 1, 5, first) == 5);
    assert(strncmp(content, "world", 5) == 0);
    fclose(first);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&dir=%%2F&name=..%%2Fsecret HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
    assert(send_request(request, "hello", 5) == 400);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&dir=%%2F&name=empty.txt HTTP/1.1\r\nContent-Length: 0\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 413);

    // Download and preview require the pairing token, must stay inside the
    // SD root and must never follow a symlink into another filesystem path.
    snprintf(request, sizeof(request),
             "GET /download?t=%s&dir=%%2F&name=test.txt HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "Content-Type: application/octet-stream"));
    assert(strstr(response_body, "Content-Length: 5\r\n"));
    char *payload = strstr(response_body, "\r\n\r\n");
    assert(payload && strcmp(payload + 4, "hello") == 0);
    snprintf(request, sizeof(request),
             "GET /preview?t=%s&dir=%%2FMods&name=inside.txt HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "X-SwitchDrop-Truncated: 0\r\n"));
    assert(strstr(response_body, "\r\n\r\ninner"));
    assert(send_request("GET /download?t=wrong&dir=%2F&name=test.txt HTTP/1.1\r\n\r\n", NULL, 0) == 403);
    snprintf(request, sizeof(request),
             "GET /download?t=%s&dir=%%2F..%%2Fetc&name=passwd HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 400);
    snprintf(request, sizeof(request),
             "GET /download?t=%s&dir=%%2F&name=link HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 404);
    snprintf(request, sizeof(request),
             "GET /download?t=%s&dir=%%2F&name=missing.txt HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 404);
    // A large log preview must be capped, while downloading returns the
    // original bytes without truncation.
    snprintf(filename, sizeof(filename), "%s/large.log", folder);
    FILE *large = fopen(filename, "wb");
    assert(large);
    for (int i = 0; i < 80000; ++i) assert(fputc('a', large) != EOF);
    assert(fclose(large) == 0);
    snprintf(request, sizeof(request),
             "GET /preview?t=%s&dir=%%2F&name=large.log HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(strstr(response_body, "Content-Length: 65536\r\n"));
    assert(strstr(response_body, "X-SwitchDrop-Truncated: 1\r\n"));
    payload = strstr(response_body, "\r\n\r\n");
    assert(payload && strlen(payload + 4) == 65536);
    snprintf(request, sizeof(request),
             "GET /download?t=%s&dir=%%2F&name=large.log HTTP/1.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    payload = strstr(response_body, "\r\n\r\n");
    assert(payload && strlen(payload + 4) == 80000);
    drop_server_stop(&server);
    snprintf(filename, sizeof(filename), "%s/large.log", folder);
    unlink(filename);
    snprintf(filename, sizeof(filename), "%s/test.txt", folder);
    unlink(filename);
    snprintf(filename, sizeof(filename), "%s/test (2).txt", folder);
    unlink(filename);
    snprintf(filename, sizeof(filename), "%s/link", folder);
    unlink(filename);
    snprintf(filename, sizeof(filename), "%s/Mods/inside.txt", folder);
    unlink(filename);
    rmdir(nested);
    rmdir(folder);
    puts("SwitchDrop receiver smoke tests passed");
    return 0;
}

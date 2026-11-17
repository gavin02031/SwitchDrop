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

static int send_request(const char *request, const char *body, size_t bodylen) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_in addr = { .sin_family = AF_INET,
        .sin_port = htons(DROP_PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(send(fd, request, strlen(request), 0) == (ssize_t)strlen(request));
    if (bodylen) assert(send(fd, body, bodylen, 0) == (ssize_t)bodylen);
    shutdown(fd, SHUT_WR);
    char response[2048] = {0};
    ssize_t n = recv(fd, response, sizeof(response) - 1, 0);
    assert(n > 12);
    close(fd);
    int code = 0;
    assert(sscanf(response, "HTTP/1.1 %d", &code) == 1);
    return code;
}

int main(void) {
    char folder[] = "/tmp/switchdrop-test-XXXXXX";
    assert(mkdtemp(folder));
    const char *token = "1234567890abcdef1234567890abcdef";
    DropServer server;
    assert(drop_server_start(&server, folder, token));
    char request[1024];
    snprintf(request, sizeof(request),
             "GET /health?t=%s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 200);
    assert(send_request("GET /health?t=wrong HTTP/1.1\r\n\r\n", NULL, 0) == 403);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&name=test.txt HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
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
    snprintf(filename, sizeof(filename), "%s/test (2).txt", folder);
    first = fopen(filename, "rb");
    assert(first);
    assert(fread(content, 1, 5, first) == 5);
    assert(strncmp(content, "world", 5) == 0);
    fclose(first);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&name=..%%2Fsecret HTTP/1.1\r\nContent-Length: 5\r\n\r\n", token);
    assert(send_request(request, "hello", 5) == 400);
    snprintf(request, sizeof(request),
             "POST /upload?t=%s&name=empty.txt HTTP/1.1\r\nContent-Length: 0\r\n\r\n", token);
    assert(send_request(request, NULL, 0) == 413);
    drop_server_stop(&server);
    snprintf(filename, sizeof(filename), "%s/test.txt", folder);
    unlink(filename);
    snprintf(filename, sizeof(filename), "%s/test (2).txt", folder);
    unlink(filename);
    rmdir(folder);
    puts("SwitchDrop receiver smoke tests passed");
    return 0;
}

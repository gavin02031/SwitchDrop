#pragma once

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#define DROP_PORT 38470
#define DROP_MAX_BYTES (16ULL * 1024 * 1024 * 1024)

typedef struct {
    int listen_fd;
    atomic_bool running;
    pthread_t thread;
    pthread_mutex_t mutex;
    char token[33];
    char root[256];
    char last_file[128];
    char status[128];
    unsigned long long bytes_received;
    unsigned long long bytes_expected;
    unsigned int files_received;
} DropServer;

bool drop_server_start(DropServer *server, const char *root, const char *token);
void drop_server_stop(DropServer *server);
void drop_server_status(DropServer *server, char *status, size_t status_size,
                        char *filename, size_t filename_size, unsigned *files,
                        unsigned long long *received, unsigned long long *expected);

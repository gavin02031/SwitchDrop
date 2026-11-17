#include <switch.h>
#include <SDL2/SDL.h>
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "drop_server.h"
#include "../vendor/qrcodegen.h"

#define WIDTH 1280
#define HEIGHT 720

// Tiny built-in 5x7 font; avoids filesystem/font dependencies on the console.
typedef struct { char ch; unsigned char pixels[7]; } Glyph;
static const Glyph font[] = {
    {'A',{14,17,17,31,17,17,17}}, {'B',{30,17,17,30,17,17,30}},
    {'C',{15,16,16,16,16,16,15}}, {'D',{30,17,17,17,17,17,30}},
    {'E',{31,16,16,30,16,16,31}}, {'F',{31,16,16,30,16,16,16}},
    {'G',{15,16,16,23,17,17,15}}, {'H',{17,17,17,31,17,17,17}},
    {'I',{31,4,4,4,4,4,31}}, {'J',{7,2,2,2,18,18,12}},
    {'K',{17,18,20,24,20,18,17}}, {'L',{16,16,16,16,16,16,31}},
    {'M',{17,27,21,21,17,17,17}}, {'N',{17,25,21,19,17,17,17}},
    {'O',{14,17,17,17,17,17,14}}, {'P',{30,17,17,30,16,16,16}},
    {'Q',{14,17,17,17,21,18,13}}, {'R',{30,17,17,30,20,18,17}},
    {'S',{15,16,16,14,1,1,30}}, {'T',{31,4,4,4,4,4,4}},
    {'U',{17,17,17,17,17,17,14}}, {'V',{17,17,17,17,17,10,4}},
    {'W',{17,17,17,21,21,21,10}}, {'X',{17,17,10,4,10,17,17}},
    {'Y',{17,17,10,4,4,4,4}}, {'Z',{31,1,2,4,8,16,31}},
    {'0',{14,17,19,21,25,17,14}}, {'1',{4,12,4,4,4,4,14}},
    {'2',{14,17,1,2,4,8,31}}, {'3',{30,1,1,14,1,1,30}},
    {'4',{2,6,10,18,31,2,2}}, {'5',{31,16,16,30,1,1,30}},
    {'6',{14,16,16,30,17,17,14}}, {'7',{31,1,2,4,8,8,8}},
    {'8',{14,17,17,14,17,17,14}}, {'9',{14,17,17,15,1,1,14}},
    {':',{0,4,4,0,4,4,0}}, {'.',{0,0,0,0,0,12,12}},
    {'/',{1,1,2,4,8,16,16}}, {'-',{0,0,0,31,0,0,0}},
    {'+',{0,4,4,31,4,4,0}}, {'%',{25,25,2,4,8,19,19}},
    {'(',{2,4,8,8,8,4,2}}, {')',{8,4,2,2,2,4,8}},
    {'_',{0,0,0,0,0,0,31}}, {'!',{4,4,4,4,4,0,4}},
    {'?',{14,17,1,2,4,0,4}}, {' ',{0,0,0,0,0,0,0}},
};

static void fill(SDL_Renderer *r, int x, int y, int w, int h, SDL_Color color) {
    SDL_SetRenderDrawColor(r, color.r, color.g, color.b, color.a);
    SDL_Rect rect = {x, y, w, h};
    SDL_RenderFillRect(r, &rect);
}

static void label(SDL_Renderer *r, int x, int y, const char *str,
                  int scale, SDL_Color color) {
    SDL_SetRenderDrawColor(r, color.r, color.g, color.b, 255);
    for (; *str; str++, x += scale * 6) {
        const unsigned char *bits = NULL;
        int wanted = toupper((unsigned char)*str);
        for (unsigned i = 0; i < sizeof(font) / sizeof(font[0]); i++) {
            if (font[i].ch == wanted) { bits = font[i].pixels; break; }
        }
        if (!bits) continue;
        for (int row = 0; row < 7; row++) for (int col = 0; col < 5; col++) {
            if (bits[row] & (1 << (4 - col))) {
                SDL_Rect pixel = {x + col * scale, y + row * scale, scale, scale};
                SDL_RenderFillRect(r, &pixel);
            }
        }
    }
}

static void qr_render(SDL_Renderer *r, const uint8_t *qr, int center_x, int center_y) {
    int size = qrcodegen_getSize(qr);
    if (size <= 0) return;
    const int cell = 8, quiet = 4;
    int start_x = center_x - (size + quiet * 2) * cell / 2;
    int start_y = center_y - (size + quiet * 2) * cell / 2;
    fill(r, start_x, start_y, (size + quiet * 2) * cell,
         (size + quiet * 2) * cell, (SDL_Color){255, 255, 255, 255});
    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
        if (qrcodegen_getModule(qr, x, y))
            fill(r, start_x + (x + quiet) * cell, start_y + (y + quiet) * cell,
                 cell, cell, (SDL_Color){42, 44, 69, 255});
    }
}

static void get_pairing_key(char token[33]) {
    const char *key_path = "sdmc:/switch/switchdrop/pairing.key";
    FILE *saved = fopen(key_path, "rb");
    if (saved) {
        size_t bytes = fread(token, 1, 32, saved);
        int extra = fgetc(saved);
        fclose(saved);
        bool valid = bytes == 32 && extra == EOF;
        for (size_t i = 0; i < bytes && valid; ++i)
            if (!isxdigit((unsigned char)token[i])) valid = false;
        if (valid) { token[32] = '\0'; return; }
    }
    // Persistent key: the iPhone stays linked between homebrew launches.
    snprintf(token, 33, "%016llx%016llx",
             (unsigned long long)randomGet64(), (unsigned long long)randomGet64());
    const char *temp_path = "sdmc:/switch/switchdrop/.pairing.tmp";
    int out = open(temp_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out >= 0) {
        ssize_t written = write(out, token, 32);
        if (written == 32) (void)fsync(out);  // Best effort on SD filesystems.
        int close_result = close(out);
        if (written == 32 && close_result == 0 &&
            rename(temp_path, key_path) == 0) return;
        unlink(temp_path);
    }
}

static void present(SDL_Renderer *r, const uint8_t *qr, const char *ip, DropServer *s,
                    bool connected) {
    SDL_Color ink = {45, 49, 78, 255}, faded = {111, 117, 144, 255};
    SDL_SetRenderDrawColor(r, 246, 243, 253, 255);
    SDL_RenderClear(r);
    fill(r, 0, 0, WIDTH, 14, (SDL_Color){183, 173, 244, 255});
    fill(r, 56, 62, 1168, 92, (SDL_Color){232, 228, 252, 255});
    label(r, 88, 88, "SWITCHDROP", 5, ink);
    label(r, 870, 100, "LOCAL FILE SHARING", 2, faded);
    fill(r, 56, 178, 502, 438, (SDL_Color){255, 255, 255, 255});
    fill(r, 586, 178, 638, 438, (SDL_Color){255, 255, 255, 255});
    if (connected) {
        qr_render(r, qr, 308, 380);
        label(r, 159, 572, "SCAN WITH IPHONE", 3, ink);
    } else {
        label(r, 150, 370, "CONNECT TO WIFI", 3, ink);
    }
    label(r, 618, 222, "YOUR SWITCH", 3, faded);
    label(r, 618, 279, ip, 4, ink);
    label(r, 618, 352, "SEND FILES TO", 2, faded);
    label(r, 618, 393, "SD:/SWITCH/SWITCHDROP", 2, ink);
    label(r, 618, 421, "/INBOX", 2, ink);
    char status[128], filename[128], number[32];
    unsigned files;
    unsigned long long received, expected;
    drop_server_status(s, status, sizeof(status), filename, sizeof(filename),
                       &files, &received, &expected);
    label(r, 618, 490, status, 2, (SDL_Color){76, 139, 116, 255});
    snprintf(number, sizeof(number), "%u FILES RECEIVED", files);
    label(r, 618, 526, number, 2, faded);
    if (expected > 0 && received < expected) {
        fill(r, 618, 567, 500, 14, (SDL_Color){239, 238, 247, 255});
        fill(r, 618, 567, (int)(500.0 * received / expected), 14,
             (SDL_Color){172, 161, 244, 255});
    }
    label(r, 70, 662, "SAME WIFI NETWORK REQUIRED", 2, faded);
    label(r, 1074, 662, "+ EXIT", 2, faded);
    SDL_RenderPresent(r);
}

int main(void) {
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    PadState pad;
    padInitializeDefault(&pad);
    if (R_FAILED(socketInitializeDefault())) return 1;
    Result nifm_result = nifmInitialize(NifmServiceType_User);
    u32 ip_raw = 0;
    if (R_SUCCEEDED(nifm_result)) (void)nifmGetCurrentIpAddress(&ip_raw);
    const unsigned char *octet = (const unsigned char *)&ip_raw;
    char ip[32];
    snprintf(ip, sizeof(ip), "%u.%u.%u.%u", octet[0], octet[1], octet[2], octet[3]);
    bool connected = ip_raw != 0;
    if (R_SUCCEEDED(nifm_result)) nifmExit();

    (void)fsdevMountSdmc();
    mkdir("sdmc:/switch", 0777);
    mkdir("sdmc:/switch/switchdrop", 0777);
    mkdir("sdmc:/switch/switchdrop/inbox", 0777);

    // The Switch's random service supplies the original pairing secret.
    char token[33];
    get_pairing_key(token);
    char qr_url[128];
    snprintf(qr_url, sizeof(qr_url), "http://%s:%d/?t=%s", ip, DROP_PORT, token);
    uint8_t qr_temp[qrcodegen_BUFFER_LEN_MAX], qr[qrcodegen_BUFFER_LEN_MAX];
    memset(qr, 0, sizeof(qr));
    bool qr_ok = qrcodegen_encodeText(qr_url, qr_temp, qr, qrcodegen_Ecc_MEDIUM,
                                      qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
                                      qrcodegen_Mask_AUTO, true);
    DropServer server;
    if (!drop_server_start(&server, "sdmc:/switch/switchdrop/inbox", token)) {
        socketExit();
        return 2;
    }
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        drop_server_stop(&server);
        socketExit();
        return 3;
    }
    SDL_Window *window = SDL_CreateWindow("SwitchDrop", 0, 0, WIDTH, HEIGHT,
                                           SDL_WINDOW_FULLSCREEN);
    SDL_Renderer *renderer = window ? SDL_CreateRenderer(window, -1,
                                          SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC) : NULL;
    if (!renderer && window) renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    if (renderer) {
        while (appletMainLoop()) {
            padUpdate(&pad);
            if (padGetButtonsDown(&pad) & HidNpadButton_Plus) break;
            SDL_Event event;
            while (SDL_PollEvent(&event)) if (event.type == SDL_QUIT) goto done;
            present(renderer, qr, ip, &server, connected && qr_ok);
            SDL_Delay(16);
        }
    }
done:
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window) SDL_DestroyWindow(window);
    SDL_Quit();
    drop_server_stop(&server);
    fsdevUnmountAll();
    socketExit();
    return 0;
}

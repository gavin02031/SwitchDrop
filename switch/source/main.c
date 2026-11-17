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

static void round_fill(SDL_Renderer *r, int x, int y, int w, int h,
                       int radius, SDL_Color color) {
    if (radius > h / 2) radius = h / 2;
    if (radius > w / 2) radius = w / 2;
    fill(r, x, y + radius, w, h - radius * 2, color);
    for (int row = 0; row < radius; row++) {
        int dy = radius - row;
        int inset = 0;
        while (inset < radius && (radius - inset) * (radius - inset) + dy * dy >
               radius * radius) inset++;
        fill(r, x + inset, y + row, w - inset * 2, 1, color);
        fill(r, x + inset, y + h - row - 1, w - inset * 2, 1, color);
    }
}

// A lightweight, translucent glass treatment for Horizon/SDL. The solid QR
// backing is intentionally kept opaque for reliable scanning.
static void glass_card(SDL_Renderer *r, int x, int y, int w, int h,
                       int radius, SDL_Color tint) {
    round_fill(r, x, y, w, h, radius, (SDL_Color){255, 255, 255, 192});
    round_fill(r, x + 2, y + 2, w - 4, h - 4, radius - 2, tint);
    round_fill(r, x + radius, y + 7, w - radius * 2, 3, 1,
               (SDL_Color){255, 255, 255, 145});
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
    const int cell = 7, quiet = 4;
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
    SDL_Color ink = {46, 41, 75, 255}, faded = {112, 105, 137, 255};
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(r, 248, 243, 255, 255);
    SDL_RenderClear(r);
    for (int y = 0; y < HEIGHT; y += 6) {
        float mix = (float)y / HEIGHT;
        fill(r, 0, y, WIDTH, 6,
             (SDL_Color){(Uint8)(247 - mix * 15),
                         (Uint8)(240 + mix * 14),
                         (Uint8)(253 - mix * 11), 255});
    }
    // Iridescent light pools keep the UI alive without moving the QR code.
    round_fill(r, -95, -124, 440, 440, 220, (SDL_Color){174, 143, 244, 40});
    round_fill(r, 1015, 489, 430, 430, 215, (SDL_Color){141, 242, 217, 62});
    round_fill(r, 412, -180, 310, 310, 155, (SDL_Color){183, 217, 255, 48});
    glass_card(r, 51, 46, 73, 73, 22, (SDL_Color){166, 131, 238, 184});
    // Two small arrows form the SwitchDrop brand mark.
    fill(r, 72, 69, 33, 4, (SDL_Color){255, 255, 255, 255});
    fill(r, 72, 91, 33, 4, (SDL_Color){255, 255, 255, 255});
    SDL_SetRenderDrawColor(r, 255, 255, 255, 255);
    SDL_RenderDrawLine(r, 100, 62, 111, 71);
    SDL_RenderDrawLine(r, 111, 71, 100, 81);
    SDL_RenderDrawLine(r, 79, 82, 68, 93);
    SDL_RenderDrawLine(r, 68, 93, 79, 103);
    label(r, 145, 63, "SWITCHDROP", 6, ink);
    label(r, 151, 122, "AIR-LIKE SHARING FOR HOMEBREW", 2, faded);

    glass_card(r, 61, 180, 510, 449, 30,
               (SDL_Color){248, 248, 255, 209});
    glass_card(r, 595, 180, 623, 449, 30,
               (SDL_Color){248, 250, 255, 201});
    if (connected) {
        qr_render(r, qr, 315, 390);
        label(r, 183, 586, "SCAN WITH IPHONE", 3, ink);
    } else {
        label(r, 172, 360, "CONNECT TO WIFI", 3, ink);
    }

    glass_card(r, 623, 213, 567, 96, 21,
               (SDL_Color){193, 245, 223, 193});
    round_fill(r, 641, 235, 54, 50, 14, (SDL_Color){240, 255, 248, 201});
    label(r, 657, 251, "W", 3, ink);
    label(r, 713, 237, connected ? "CONNECTED TO WI-FI" : "NOT CONNECTED", 3, ink);
    label(r, 714, 274, ip, 2, faded);

    glass_card(r, 623, 328, 567, 109, 21,
               (SDL_Color){230, 220, 251, 174});
    round_fill(r, 642, 350, 53, 57, 14, (SDL_Color){235, 225, 252, 204});
    label(r, 655, 367, "SD", 2, ink);
    label(r, 712, 350, "BROWSE YOUR SD CARD", 3, ink);
    label(r, 712, 386, "FROM IPHONE", 3, ink);

    glass_card(r, 623, 456, 567, 161, 21,
               (SDL_Color){226, 218, 255, 185});
    char status[128], filename[128], number[32];
    unsigned files;
    unsigned long long received, expected;
    drop_server_status(s, status, sizeof(status), filename, sizeof(filename),
                       &files, &received, &expected);
    snprintf(number, sizeof(number), "%u FILES RECEIVED", files);
    label(r, 650, 479, number, 3, ink);
    char short_status[45];
    snprintf(short_status, sizeof(short_status), "%.42s", status);
    label(r, 646, 534, short_status, 2, (SDL_Color){68, 126, 103, 255});
    if (filename[0]) {
        char last_file[43];
        snprintf(last_file, sizeof(last_file), "%.39s", filename);
        label(r, 646, 563, last_file, 2, faded);
    }
    if (expected > 0 && received < expected) {
        round_fill(r, 646, 592, 502, 13, 6, (SDL_Color){239, 238, 247, 255});
        fill(r, 646, 592, (int)(502.0 * received / expected), 13,
             (SDL_Color){172, 161, 244, 255});
    } else if (files > 0) {
        label(r, 646, 592, "READY FOR MORE FILES", 2, faded);
    }
    label(r, 66, 671, "SAME WI-FI  /  KEEP APP OPEN", 2, faded);
    label(r, 1011, 671, "+ EXIT", 2, faded);
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
    if (!drop_server_start(&server, "sdmc:", token)) {
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

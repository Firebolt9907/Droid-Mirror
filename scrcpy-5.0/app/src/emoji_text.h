#ifndef SC_EMOJI_TEXT_H
#define SC_EMOJI_TEXT_H

#include <stdbool.h>
#include <stdint.h>

// SDL text input is valid UTF-8. Emoji commits have no physical key equivalent
// and must bypass both Android's KeyCharacterMap and the UHID keyboard.
static inline bool
sc_text_contains_emoji(const char *text) {
    const unsigned char *p = (const unsigned char *) text;
    while (*p) {
        uint32_t cp = *p++;
        unsigned remaining = 0;
        if (cp >= 0xf0) { cp &= 7; remaining = 3; }
        else if (cp >= 0xe0) { cp &= 15; remaining = 2; }
        else if (cp >= 0xc0) { cp &= 31; remaining = 1; }
        while (remaining--) {
            if ((*p & 0xc0) != 0x80) return false;
            cp = (cp << 6) | (*p++ & 0x3f);
        }
        if ((cp >= 0x1f000 && cp <= 0x1faff) ||
                (cp >= 0x2600 && cp <= 0x27bf) ||
                (cp >= 0x2300 && cp <= 0x23ff) ||
                cp == 0x200d || cp == 0x20e3 || cp == 0xfe0f ||
                cp == 0xa9 || cp == 0xae || cp == 0x203c || cp == 0x2049 ||
                cp == 0x2122 || cp == 0x2139 ||
                (cp >= 0x2194 && cp <= 0x21ff) ||
                (cp >= 0x2b00 && cp <= 0x2bff) ||
                cp == 0x3030 || cp == 0x303d || cp == 0x3297 || cp == 0x3299) {
            return true;
        }
    }
    return false;
}

#endif

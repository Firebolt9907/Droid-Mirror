#include "../scrcpy-5.0/app/src/emoji_text.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const char *emoji[] = {"😀", "❤️", "👍🏽", "👨‍👩‍👧‍👦", "🇨🇦", "1️⃣", "☺", "↔️", "©️", "hello 🎉!"};
    for (unsigned i = 0; i < sizeof(emoji) / sizeof(*emoji); ++i) {
        assert(sc_text_contains_emoji(emoji[i]));
    }
    const char *ordinary[] = {"", "hello", "123", "café", "日本語", "한국어"};
    for (unsigned i = 0; i < sizeof(ordinary) / sizeof(*ordinary); ++i) {
        assert(!sc_text_contains_emoji(ordinary[i]));
    }
    puts("Emoji text: simple, BMP, skin tone, ZWJ, flag and keycap commits passed");
}

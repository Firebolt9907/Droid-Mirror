#include "device_msg.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "util/binary.h"
#include "util/log.h"

ssize_t
sc_device_msg_deserialize(const uint8_t *buf, size_t len,
                          struct sc_device_msg *msg) {
    if (!len) {
        return 0; // no message
    }

    msg->type = buf[0];
    switch (msg->type) {
        case DEVICE_MSG_TYPE_CAMERA_CUTOUT: {
            if (len < 6) return 0;
            unsigned count = buf[5];
            if (count > 4) return -1;
            if (len < 6 + count * 16) return 0;
            struct sc_camera_cutout *cutout = &msg->camera_cutout;
            cutout->width = sc_read16be(buf + 1);
            cutout->height = sc_read16be(buf + 3);
            cutout->count = count;
            if (!cutout->width || !cutout->height) return -1;
            for (unsigned i = 0; i < count; ++i) {
                const uint8_t *p = buf + 6 + i * 16;
                struct sc_cutout_rect *rect = &cutout->rects[i];
                rect->left = (int32_t) sc_read32be(p);
                rect->top = (int32_t) sc_read32be(p + 4);
                rect->right = (int32_t) sc_read32be(p + 8);
                rect->bottom = (int32_t) sc_read32be(p + 12);
                if (rect->left < -65535 || rect->top < -65535
                        || rect->right > 65535 || rect->bottom > 65535
                        || rect->right <= rect->left || rect->bottom <= rect->top) return -1;
            }
            return 6 + count * 16;
        }
        case DEVICE_MSG_TYPE_CLIPBOARD: {
            if (len < 5) {
                // at least type + empty string length
                return 0; // no complete message
            }
            size_t clipboard_len = sc_read32be(&buf[1]);
            if (clipboard_len > len - 5) {
                return 0; // no complete message
            }
            char *text = malloc(clipboard_len + 1);
            if (!text) {
                LOG_OOM();
                return -1;
            }
            if (clipboard_len) {
                memcpy(text, &buf[5], clipboard_len);
            }
            text[clipboard_len] = '\0';

            msg->clipboard.text = text;
            return 5 + clipboard_len;
        }
        case DEVICE_MSG_TYPE_ACK_CLIPBOARD: {
            if (len < 9) {
                return 0; // no complete message
            }
            uint64_t sequence = sc_read64be(&buf[1]);
            msg->ack_clipboard.sequence = sequence;
            return 9;
        }
        case DEVICE_MSG_TYPE_UHID_OUTPUT: {
            if (len < 5) {
                // at least id + size
                return 0; // not available
            }
            uint16_t id = sc_read16be(&buf[1]);
            size_t size = sc_read16be(&buf[3]);
            if (size > len - 5) {
                return 0; // not available
            }
            uint8_t *data = malloc(size);
            if (!data) {
                LOG_OOM();
                return -1;
            }
            if (size) {
                memcpy(data, &buf[5], size);
            }

            msg->uhid_output.id = id;
            msg->uhid_output.size = size;
            msg->uhid_output.data = data;

            return 5 + size;
        }
        default:
            LOGW("Unknown device message type: %d", (int) msg->type);
            return -1; // error, we cannot recover
    }
}

void
sc_device_msg_destroy(struct sc_device_msg *msg) {
    switch (msg->type) {
        case DEVICE_MSG_TYPE_CLIPBOARD:
            free(msg->clipboard.text);
            break;
        case DEVICE_MSG_TYPE_UHID_OUTPUT:
            free(msg->uhid_output.data);
            break;
        default:
            // nothing to do
            break;
    }
}

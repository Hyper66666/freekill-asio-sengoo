#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>
#include <limits.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET sg_socket_t;
#define SG_INVALID_SOCKET INVALID_SOCKET
#define sg_close_socket closesocket
#define sg_mkdir _mkdir
#define sg_popen _popen
#define sg_pclose _pclose
#else
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <strings.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
typedef int sg_socket_t;
#define SG_INVALID_SOCKET (-1)
#define sg_close_socket close
#define sg_mkdir(path) mkdir((path), 0755)
#define sg_popen popen
#define sg_pclose pclose
#endif

void sengoo_print_i64(long long val) {
    printf("%lld\n", val);
    fflush(stdout);
}

void sengoo_print_bool(long long val) {
    printf("%s\n", val ? "true" : "false");
    fflush(stdout);
}

void sengoo_print_f64(double val) {
    printf("%g\n", val);
    fflush(stdout);
}

void sengoo_print_str(const char* s) {
    if (s) {
        printf("%s\n", s);
    } else {
        printf("\n");
    }
    fflush(stdout);
}

void* sengoo_alloc(long long size, long long align) {
    if (align <= 0) align = 1;
    (void)align;
    return malloc((size_t)size);
}

void sengoo_free(void* ptr, long long size, long long align) {
    (void)size;
    (void)align;
    free(ptr);
}

void* sengoo_realloc(void* ptr, long long old_size, long long old_align, long long new_size) {
    (void)old_size;
    (void)old_align;
    return realloc(ptr, (size_t)new_size);
}

#define SG_MAX_NET_HANDLES 2048
#define SG_EXTENSION_SYNC_PAYLOAD_MAX 32768
#define SG_DEFAULT_EXTENSION_REGISTRY_JSON "[{\"name\":\"freekill-core\",\"enabled\":true,\"builtin\":true}]"
#define SG_EXTENSION_BOOTSTRAP_MAX 256
#define SG_EXTENSION_NAME_MAX 128
#define SG_EXTENSION_ENTRY_MAX 1024
#define SG_EXTENSION_HASH_MAX 96
#define SG_EXTENSION_CMD_MAX 4096
#define SG_EXTENSION_SCRIPT_MAX 4096
#define SG_EXTENSION_OUTPUT_MAX 2048
#define SG_TCP_STREAM_BUFFER_MAX 65536
#define SG_PACKET_TYPE_REQUEST 0x100
#define SG_PACKET_TYPE_REPLY 0x200
#define SG_PACKET_TYPE_NOTIFICATION 0x400
#define SG_PACKET_SRC_CLIENT 0x010
#define SG_PACKET_SRC_SERVER 0x020
#define SG_PACKET_DEST_CLIENT 0x001
#define SG_PACKET_DEST_SERVER 0x002
#define SG_PACKET_TYPE_SERVER_NOTIFY (SG_PACKET_TYPE_NOTIFICATION | SG_PACKET_SRC_SERVER | SG_PACKET_DEST_CLIENT)
#define SG_AUTH_PUBLIC_KEY_MAX 8192
#define SG_AUTH_MD5_MAX 96
#define SG_AUTH_VERSION_MAX 96
#define SG_AUTH_NAME_MAX 256
#define SG_AUTH_PASSWORD_MAX 512
#define SG_AUTH_UUID_MAX 256
#define SG_AUTH_AVATAR_MAX 128
#define SG_AUTH_LINE_MAX 2048

typedef struct {
    long long handle;
    sg_socket_t socket;
    int used;
} sg_socket_entry;

typedef struct {
    int used;
    long long handle;
    size_t len;
    unsigned char data[SG_TCP_STREAM_BUFFER_MAX];
} sg_tcp_stream_state;

typedef struct {
    long long request_id;
    long long packet_type;
    int command_major;
    const unsigned char* command_ptr;
    size_t command_len;
    int payload_major;
    const unsigned char* payload_ptr;
    size_t payload_len;
    int field_count;
    long long timeout;
    long long timestamp;
} sg_cbor_wire_packet;

typedef struct {
    int used;
    long long handle;
    int network_delay_sent;
    int setup_received;
    int auth_passed;
    long long player_id;
    char player_name[SG_AUTH_NAME_MAX];
    long long accepted_at_ms;
    long long last_activity_ms;
} sg_auth_state;

typedef struct {
    char name[SG_AUTH_NAME_MAX];
    char password[SG_AUTH_PASSWORD_MAX];
    unsigned char password_raw[SG_AUTH_PASSWORD_MAX];
    size_t password_raw_len;
    int password_major;
    char md5[SG_AUTH_MD5_MAX];
    char version[SG_AUTH_VERSION_MAX];
    char uuid[SG_AUTH_UUID_MAX];
} sg_setup_fields;

typedef struct {
    int found;
    long long id;
    char name[SG_AUTH_NAME_MAX];
    char password[SG_AUTH_PASSWORD_MAX];
    char salt[32];
    char avatar[SG_AUTH_AVATAR_MAX];
    int banned;
    long long ban_expire_epoch;
} sg_auth_user_record;

typedef struct {
    int used;
    unsigned int generation;
    int loaded;
    int last_exit_code;
    char name[SG_EXTENSION_NAME_MAX];
    char entry[SG_EXTENSION_ENTRY_MAX];
    char hash[SG_EXTENSION_HASH_MAX];
} sg_extension_bootstrap_entry;

static sg_socket_entry g_tcp_listeners[SG_MAX_NET_HANDLES];
static sg_socket_entry g_tcp_connections[SG_MAX_NET_HANDLES];
static sg_socket_entry g_udp_sockets[SG_MAX_NET_HANDLES];
static sg_tcp_stream_state g_tcp_streams[SG_MAX_NET_HANDLES];
static sg_auth_state g_auth_states[SG_MAX_NET_HANDLES];
static long long g_next_handle = 1000000;
static int g_net_init_logged = 0;
static char g_extension_sync_payload[SG_EXTENSION_SYNC_PAYLOAD_MAX];
static sg_extension_bootstrap_entry g_extension_bootstrap_entries[SG_EXTENSION_BOOTSTRAP_MAX];
static unsigned int g_extension_bootstrap_generation = 0;
static int g_extension_bootstrap_lua_missing_logged = 0;
static int g_extension_bootstrap_synced_once = 0;
static int g_extension_bootstrap_lua_checked = 0;
static int g_extension_bootstrap_lua_available = 0;
static long long g_extension_sync_refresh_last_ms = 0;
static unsigned long g_extension_sync_payload_fingerprint = 0;
static int g_extension_shutdown_hooks_emitted = 0;
static int g_auth_whitelist_missing_logged = 0;
static int g_auth_ban_words_missing_logged = 0;
static int g_auth_rsa_decrypt_error_logged = 0;
static size_t sg_build_update_package_summary(unsigned char* out, size_t out_cap);

static void sg_logf(const char* level, const char* module, const char* fmt, ...) {
    char timestamp[32];
    timestamp[0] = '\0';
#ifdef _WIN32
    SYSTEMTIME st;
    GetLocalTime(&st);
    _snprintf_s(
        timestamp,
        sizeof(timestamp),
        _TRUNCATE,
        "%04d-%02d-%02d %02d:%02d:%02d",
        (int)st.wYear,
        (int)st.wMonth,
        (int)st.wDay,
        (int)st.wHour,
        (int)st.wMinute,
        (int)st.wSecond
    );
#else
    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &tm_now);
#endif

    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    printf("[%s][%s][%s] %s\n", timestamp, level, module, message);
    fflush(stdout);
}

static int sg_last_socket_error(void) {
#ifdef _WIN32
    return WSAGetLastError();
#else
    return errno;
#endif
}

static long long sg_monotonic_ms(void) {
#ifdef _WIN32
    return (long long)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000L);
#endif
}

static sg_tcp_stream_state* sg_tcp_stream_find(long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_tcp_streams[i].used && g_tcp_streams[i].handle == handle) {
            return &g_tcp_streams[i];
        }
    }
    return NULL;
}

static int sg_tcp_stream_attach(long long handle) {
    sg_tcp_stream_state* existing = sg_tcp_stream_find(handle);
    if (existing != NULL) {
        existing->len = 0;
        return 1;
    }
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!g_tcp_streams[i].used) {
            g_tcp_streams[i].used = 1;
            g_tcp_streams[i].handle = handle;
            g_tcp_streams[i].len = 0;
            return 1;
        }
    }
    return 0;
}

static void sg_tcp_stream_detach(long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_tcp_streams[i].used && g_tcp_streams[i].handle == handle) {
            g_tcp_streams[i].used = 0;
            g_tcp_streams[i].handle = 0;
            g_tcp_streams[i].len = 0;
            return;
        }
    }
}

static sg_auth_state* sg_auth_state_find(long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_auth_states[i].used && g_auth_states[i].handle == handle) {
            return &g_auth_states[i];
        }
    }
    return NULL;
}

static int sg_auth_state_attach(long long handle) {
    long long now_ms = sg_monotonic_ms();
    sg_auth_state* existing = sg_auth_state_find(handle);
    if (existing != NULL) {
        existing->network_delay_sent = 0;
        existing->setup_received = 0;
        existing->auth_passed = 0;
        existing->player_id = 0;
        existing->player_name[0] = '\0';
        existing->accepted_at_ms = now_ms;
        existing->last_activity_ms = now_ms;
        return 1;
    }
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!g_auth_states[i].used) {
            g_auth_states[i].used = 1;
            g_auth_states[i].handle = handle;
            g_auth_states[i].network_delay_sent = 0;
            g_auth_states[i].setup_received = 0;
            g_auth_states[i].auth_passed = 0;
            g_auth_states[i].player_id = 0;
            g_auth_states[i].player_name[0] = '\0';
            g_auth_states[i].accepted_at_ms = now_ms;
            g_auth_states[i].last_activity_ms = now_ms;
            return 1;
        }
    }
    return 0;
}

static void sg_auth_state_detach(long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_auth_states[i].used && g_auth_states[i].handle == handle) {
            g_auth_states[i].used = 0;
            g_auth_states[i].handle = 0;
            g_auth_states[i].network_delay_sent = 0;
            g_auth_states[i].setup_received = 0;
            g_auth_states[i].auth_passed = 0;
            g_auth_states[i].player_id = 0;
            g_auth_states[i].player_name[0] = '\0';
            g_auth_states[i].accepted_at_ms = 0;
            g_auth_states[i].last_activity_ms = 0;
            return;
        }
    }
}

static int sg_send_all(sg_socket_t socket, const unsigned char* data, size_t len) {
    size_t sent_total = 0;
    while (sent_total < len) {
        int sent = send(socket, (const char*)(data + sent_total), (int)(len - sent_total), 0);
        if (sent <= 0) {
            return 0;
        }
        sent_total += (size_t)sent;
    }
    return 1;
}

static int sg_cbor_read_length_by_ai(const unsigned char* data, size_t len, size_t* idx, int ai, unsigned long long* out) {
    if (data == NULL || idx == NULL || out == NULL) {
        return -1;
    }
    if (ai < 24) {
        *out = (unsigned long long)ai;
        return 1;
    }
    if (ai == 24) {
        if (*idx + 1 > len) {
            return 0;
        }
        *out = (unsigned long long)data[*idx];
        *idx += 1;
        return 1;
    }
    if (ai == 25) {
        if (*idx + 2 > len) {
            return 0;
        }
        *out = ((unsigned long long)data[*idx] << 8) | (unsigned long long)data[*idx + 1];
        *idx += 2;
        return 1;
    }
    if (ai == 26) {
        if (*idx + 4 > len) {
            return 0;
        }
        *out =
            ((unsigned long long)data[*idx] << 24) |
            ((unsigned long long)data[*idx + 1] << 16) |
            ((unsigned long long)data[*idx + 2] << 8) |
            (unsigned long long)data[*idx + 3];
        *idx += 4;
        return 1;
    }
    if (ai == 27) {
        if (*idx + 8 > len) {
            return 0;
        }
        *out =
            ((unsigned long long)data[*idx] << 56) |
            ((unsigned long long)data[*idx + 1] << 48) |
            ((unsigned long long)data[*idx + 2] << 40) |
            ((unsigned long long)data[*idx + 3] << 32) |
            ((unsigned long long)data[*idx + 4] << 24) |
            ((unsigned long long)data[*idx + 5] << 16) |
            ((unsigned long long)data[*idx + 6] << 8) |
            (unsigned long long)data[*idx + 7];
        *idx += 8;
        return 1;
    }
    return -1;
}

static int sg_cbor_read_signed_integer(const unsigned char* data, size_t len, size_t* idx, long long* out) {
    if (data == NULL || idx == NULL || out == NULL) {
        return -1;
    }
    if (*idx >= len) {
        return 0;
    }
    unsigned char head = data[*idx];
    int major = (head >> 5) & 0x07;
    int ai = head & 0x1f;
    if (major != 0 && major != 1) {
        return -1;
    }
    *idx += 1;
    unsigned long long uval = 0;
    int len_rc = sg_cbor_read_length_by_ai(data, len, idx, ai, &uval);
    if (len_rc <= 0) {
        return len_rc;
    }
    if (uval > (unsigned long long)LLONG_MAX) {
        return -1;
    }
    if (major == 0) {
        *out = (long long)uval;
    } else {
        *out = -1 - (long long)uval;
    }
    return 1;
}

static int sg_cbor_read_bytes_like(
    const unsigned char* data,
    size_t len,
    size_t* idx,
    int* out_major,
    const unsigned char** out_ptr,
    size_t* out_len
) {
    if (data == NULL || idx == NULL || out_major == NULL || out_ptr == NULL || out_len == NULL) {
        return -1;
    }
    if (*idx >= len) {
        return 0;
    }
    unsigned char head = data[*idx];
    int major = (head >> 5) & 0x07;
    int ai = head & 0x1f;
    if (major != 2 && major != 3) {
        return -1;
    }
    *idx += 1;
    unsigned long long blen = 0;
    int len_rc = sg_cbor_read_length_by_ai(data, len, idx, ai, &blen);
    if (len_rc <= 0) {
        return len_rc;
    }
    if (blen > (unsigned long long)(len - *idx)) {
        return 0;
    }
    *out_major = major;
    *out_ptr = data + *idx;
    *out_len = (size_t)blen;
    *idx += (size_t)blen;
    return 1;
}

static int sg_cbor_parse_wire_packet(
    const unsigned char* data,
    size_t len,
    sg_cbor_wire_packet* out,
    size_t* consumed
) {
    if (data == NULL || out == NULL || consumed == NULL) {
        return -1;
    }
    if (len == 0) {
        return 0;
    }

    size_t idx = 0;
    unsigned char head = data[idx];
    int major = (head >> 5) & 0x07;
    int ai = head & 0x1f;
    if (major != 4) {
        return -1;
    }
    idx += 1;

    unsigned long long field_count = 0;
    int len_rc = sg_cbor_read_length_by_ai(data, len, &idx, ai, &field_count);
    if (len_rc <= 0) {
        return len_rc;
    }
    if (field_count != 4 && field_count != 6) {
        return -1;
    }

    long long request_id = 0;
    long long packet_type = 0;
    long long timeout = 0;
    long long timestamp = 0;
    int command_major = 0;
    int payload_major = 0;
    const unsigned char* command_ptr = NULL;
    const unsigned char* payload_ptr = NULL;
    size_t command_len = 0;
    size_t payload_len = 0;

    int rc = sg_cbor_read_signed_integer(data, len, &idx, &request_id);
    if (rc <= 0) {
        return rc;
    }
    rc = sg_cbor_read_signed_integer(data, len, &idx, &packet_type);
    if (rc <= 0) {
        return rc;
    }
    rc = sg_cbor_read_bytes_like(data, len, &idx, &command_major, &command_ptr, &command_len);
    if (rc <= 0) {
        return rc;
    }
    rc = sg_cbor_read_bytes_like(data, len, &idx, &payload_major, &payload_ptr, &payload_len);
    if (rc <= 0) {
        return rc;
    }

    if (field_count == 6) {
        rc = sg_cbor_read_signed_integer(data, len, &idx, &timeout);
        if (rc <= 0) {
            return rc;
        }
        rc = sg_cbor_read_signed_integer(data, len, &idx, &timestamp);
        if (rc <= 0) {
            return rc;
        }
    }

    out->request_id = request_id;
    out->packet_type = packet_type;
    out->command_major = command_major;
    out->command_ptr = command_ptr;
    out->command_len = command_len;
    out->payload_major = payload_major;
    out->payload_ptr = payload_ptr;
    out->payload_len = payload_len;
    out->field_count = (int)field_count;
    out->timeout = timeout;
    out->timestamp = timestamp;
    *consumed = idx;
    return 1;
}

static int sg_cbor_write_type_and_len(unsigned char* out, size_t out_cap, size_t* idx, int major, unsigned long long len_value) {
    if (out == NULL || idx == NULL || major < 0 || major > 7) {
        return 0;
    }
    if (len_value < 24ULL) {
        if (*idx + 1 > out_cap) {
            return 0;
        }
        out[*idx] = (unsigned char)((major << 5) | (int)len_value);
        *idx += 1;
        return 1;
    }
    if (len_value <= 0xffULL) {
        if (*idx + 2 > out_cap) {
            return 0;
        }
        out[*idx] = (unsigned char)((major << 5) | 24);
        out[*idx + 1] = (unsigned char)len_value;
        *idx += 2;
        return 1;
    }
    if (len_value <= 0xffffULL) {
        if (*idx + 3 > out_cap) {
            return 0;
        }
        out[*idx] = (unsigned char)((major << 5) | 25);
        out[*idx + 1] = (unsigned char)(len_value >> 8);
        out[*idx + 2] = (unsigned char)(len_value);
        *idx += 3;
        return 1;
    }
    if (len_value <= 0xffffffffULL) {
        if (*idx + 5 > out_cap) {
            return 0;
        }
        out[*idx] = (unsigned char)((major << 5) | 26);
        out[*idx + 1] = (unsigned char)(len_value >> 24);
        out[*idx + 2] = (unsigned char)(len_value >> 16);
        out[*idx + 3] = (unsigned char)(len_value >> 8);
        out[*idx + 4] = (unsigned char)(len_value);
        *idx += 5;
        return 1;
    }
    if (*idx + 9 > out_cap) {
        return 0;
    }
    out[*idx] = (unsigned char)((major << 5) | 27);
    out[*idx + 1] = (unsigned char)(len_value >> 56);
    out[*idx + 2] = (unsigned char)(len_value >> 48);
    out[*idx + 3] = (unsigned char)(len_value >> 40);
    out[*idx + 4] = (unsigned char)(len_value >> 32);
    out[*idx + 5] = (unsigned char)(len_value >> 24);
    out[*idx + 6] = (unsigned char)(len_value >> 16);
    out[*idx + 7] = (unsigned char)(len_value >> 8);
    out[*idx + 8] = (unsigned char)(len_value);
    *idx += 9;
    return 1;
}

static int sg_cbor_write_signed_integer(unsigned char* out, size_t out_cap, size_t* idx, long long value) {
    if (value >= 0) {
        return sg_cbor_write_type_and_len(out, out_cap, idx, 0, (unsigned long long)value);
    }
    return sg_cbor_write_type_and_len(out, out_cap, idx, 1, (unsigned long long)(-1 - value));
}

static int sg_cbor_write_bytes_like(
    unsigned char* out,
    size_t out_cap,
    size_t* idx,
    int major,
    const unsigned char* data,
    size_t data_len
) {
    if (major != 2 && major != 3) {
        major = 2;
    }
    if (!sg_cbor_write_type_and_len(out, out_cap, idx, major, (unsigned long long)data_len)) {
        return 0;
    }
    if (*idx + data_len > out_cap) {
        return 0;
    }
    if (data_len > 0 && data != NULL) {
        memcpy(out + *idx, data, data_len);
    }
    *idx += data_len;
    return 1;
}

static void sg_packet_token(const unsigned char* src, size_t src_len, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return;
    }
    size_t limit = src_len;
    if (limit > out_cap - 1) {
        limit = out_cap - 1;
    }
    for (size_t i = 0; i < limit; i++) {
        unsigned char ch = src[i];
        if (ch >= 32 && ch <= 126) {
            out[i] = (char)ch;
        } else {
            out[i] = '.';
        }
    }
    out[limit] = '\0';
}

static void sg_copy_token_to_cstr(const unsigned char* src, size_t src_len, char* dst, size_t dst_cap) {
    if (dst == NULL || dst_cap == 0) {
        return;
    }
    size_t copy_len = src_len;
    if (copy_len > dst_cap - 1) {
        copy_len = dst_cap - 1;
    }
    if (copy_len > 0 && src != NULL) {
        memcpy(dst, src, copy_len);
    }
    dst[copy_len] = '\0';
}

static int sg_packet_command_equals(const sg_cbor_wire_packet* packet, const char* text) {
    if (packet == NULL || text == NULL || packet->command_ptr == NULL) {
        return 0;
    }
    size_t want = strlen(text);
    if (want != packet->command_len) {
        return 0;
    }
    return memcmp(packet->command_ptr, text, want) == 0;
}

static int sg_parse_setup_payload(const unsigned char* payload, size_t payload_len, sg_setup_fields* out) {
    if (payload == NULL || out == NULL || payload_len == 0) {
        return 0;
    }
    memset(out, 0, sizeof(*out));

    size_t idx = 0;
    if (idx >= payload_len) {
        return 0;
    }
    unsigned char head = payload[idx];
    int major = (head >> 5) & 0x07;
    int ai = head & 0x1f;
    if (major != 4) {
        return 0;
    }
    idx += 1;
    unsigned long long field_count = 0;
    int len_rc = sg_cbor_read_length_by_ai(payload, payload_len, &idx, ai, &field_count);
    if (len_rc <= 0 || field_count < 5ULL) {
        return 0;
    }

    const unsigned char* field_ptr = NULL;
    size_t field_len = 0;
    int field_major = 0;
    for (int i = 0; i < 5; i++) {
        int rc = sg_cbor_read_bytes_like(payload, payload_len, &idx, &field_major, &field_ptr, &field_len);
        if (rc <= 0) {
            return 0;
        }
        if (i == 0) {
            sg_copy_token_to_cstr(field_ptr, field_len, out->name, sizeof(out->name));
        } else if (i == 1) {
            out->password_major = field_major;
            if (field_len > sizeof(out->password_raw)) {
                return 0;
            }
            if (field_len > 0) {
                memcpy(out->password_raw, field_ptr, field_len);
            }
            out->password_raw_len = field_len;
            sg_copy_token_to_cstr(field_ptr, field_len, out->password, sizeof(out->password));
        } else if (i == 2) {
            sg_copy_token_to_cstr(field_ptr, field_len, out->md5, sizeof(out->md5));
        } else if (i == 3) {
            sg_copy_token_to_cstr(field_ptr, field_len, out->version, sizeof(out->version));
        } else if (i == 4) {
            sg_copy_token_to_cstr(field_ptr, field_len, out->uuid, sizeof(out->uuid));
        }
    }
    return out->name[0] != '\0' && out->version[0] != '\0';
}

static int sg_parse_version_triplet(const char* version_text, int* major_out, int* minor_out, int* patch_out) {
    if (version_text == NULL || major_out == NULL || minor_out == NULL || patch_out == NULL) {
        return 0;
    }
    const char* p = version_text;
    if (*p == 'v' || *p == 'V') {
        p += 1;
    }
    char* end = NULL;
    long major = strtol(p, &end, 10);
    if (end == p || *end != '.') {
        return 0;
    }
    p = end + 1;
    long minor = strtol(p, &end, 10);
    if (end == p || *end != '.') {
        return 0;
    }
    p = end + 1;
    long patch = strtol(p, &end, 10);
    if (end == p) {
        return 0;
    }
    if (major < 0 || minor < 0 || patch < 0 || major > 1000 || minor > 1000 || patch > 1000000) {
        return 0;
    }
    *major_out = (int)major;
    *minor_out = (int)minor;
    *patch_out = (int)patch;
    return 1;
}

static int sg_is_supported_client_version(const char* version_text) {
    int major = 0;
    int minor = 0;
    int patch = 0;
    if (!sg_parse_version_triplet(version_text, &major, &minor, &patch)) {
        return 0;
    }
    if (major != 0) {
        return 0;
    }
    if (minor != 5) {
        return 0;
    }
    return patch >= 19;
}

static int sg_build_server_notify_packet(
    unsigned char* out,
    size_t out_cap,
    const char* command,
    const unsigned char* payload,
    size_t payload_len,
    int payload_major,
    size_t* out_len
) {
    if (out == NULL || out_cap == 0 || command == NULL || out_len == NULL) {
        return 0;
    }
    size_t idx = 0;
    size_t command_len = strlen(command);
    int ok = 1;
    ok = ok && sg_cbor_write_type_and_len(out, out_cap, &idx, 4, 4);
    ok = ok && sg_cbor_write_signed_integer(out, out_cap, &idx, -2);
    ok = ok && sg_cbor_write_signed_integer(out, out_cap, &idx, SG_PACKET_TYPE_SERVER_NOTIFY);
    ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 2, (const unsigned char*)command, command_len);
    ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, payload_major, payload, payload_len);
    if (!ok) {
        return 0;
    }
    *out_len = idx;
    return 1;
}

static int sg_send_server_notification(
    sg_socket_t socket,
    const char* command,
    const unsigned char* payload,
    size_t payload_len,
    int payload_major
) {
    unsigned char frame[SG_AUTH_PUBLIC_KEY_MAX + 512];
    size_t frame_len = 0;
    if (!sg_build_server_notify_packet(frame, sizeof(frame), command, payload, payload_len, payload_major, &frame_len)) {
        return 0;
    }
    return sg_send_all(socket, frame, frame_len);
}

static size_t sg_load_network_delay_payload(unsigned char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }
    const char* env_path = getenv("SENGOO_RSA_PUBLIC_KEY_PATH");
    const char* key_path = (env_path != NULL && env_path[0] != '\0') ? env_path : "server/rsa_pub";
    FILE* fp = fopen(key_path, "rb");
    if (fp != NULL) {
        size_t n = fread(out, 1, out_cap, fp);
        fclose(fp);
        if (n > 0) {
            return n;
        }
    }

    const char* fallback_key = "SENGOO_FAKE_RSA_PUBLIC_KEY";
    size_t fallback_len = strlen(fallback_key);
    if (fallback_len > out_cap) {
        fallback_len = out_cap;
    }
    memcpy(out, fallback_key, fallback_len);
    return fallback_len;
}

static int sg_send_network_delay_test(sg_socket_t socket) {
    unsigned char payload[SG_AUTH_PUBLIC_KEY_MAX];
    size_t payload_len = sg_load_network_delay_payload(payload, sizeof(payload));
    return sg_send_server_notification(socket, "NetworkDelayTest", payload, payload_len, 2);
}

static int sg_should_send_network_delay(void) {
    const char* raw = getenv("SENGOO_AUTH_SEND_NETWORK_DELAY");
    if (raw == NULL || raw[0] == '\0') {
        return 1;
    }
    if (strcmp(raw, "0") == 0 || strcmp(raw, "FALSE") == 0 || strcmp(raw, "false") == 0) {
        return 0;
    }
    if (strcmp(raw, "OFF") == 0 || strcmp(raw, "off") == 0 || strcmp(raw, "NO") == 0 || strcmp(raw, "no") == 0) {
        return 0;
    }
    return 1;
}

static int sg_send_errordlg_and_close(sg_socket_t socket, const char* msg) {
    const char* text = (msg == NULL ? "UNKNOWN ERROR" : msg);
    size_t msg_len = strlen(text);
    return sg_send_server_notification(socket, "ErrorDlg", (const unsigned char*)text, msg_len, 2);
}

static int sg_send_md5_failure_and_update_package(sg_socket_t socket) {
    const char* msg = "MD5 check failed!";
    if (!sg_send_server_notification(socket, "ErrorMsg", (const unsigned char*)msg, strlen(msg), 2)) {
        return 0;
    }
    unsigned char summary_payload[SG_EXTENSION_SYNC_PAYLOAD_MAX];
    size_t summary_len = sg_build_update_package_summary(summary_payload, sizeof(summary_payload));
    if (summary_len == 0) {
        summary_payload[0] = 0x80;
        summary_len = 1;
    }
    return sg_send_server_notification(socket, "UpdatePackage", summary_payload, summary_len, 2);
}

static int sg_should_enforce_md5(void) {
    const char* raw = getenv("SENGOO_AUTH_ENFORCE_MD5");
    if (raw == NULL || raw[0] == '\0') {
        return 0;
    }
    if (strcmp(raw, "1") == 0 || strcmp(raw, "TRUE") == 0 || strcmp(raw, "true") == 0) {
        return 1;
    }
    if (strcmp(raw, "ON") == 0 || strcmp(raw, "on") == 0 || strcmp(raw, "YES") == 0 || strcmp(raw, "yes") == 0) {
        return 1;
    }
    return 0;
}

static int sg_md5_matches_expected(const char* incoming_md5) {
    const char* expected = getenv("SENGOO_SERVER_MD5");
    if (expected == NULL || expected[0] == '\0') {
        return 1;
    }
    if (incoming_md5 == NULL) {
        return 0;
    }
    return strcmp(incoming_md5, expected) == 0;
}

static void sg_trim_ascii_inplace(char* text) {
    if (text == NULL) {
        return;
    }
    size_t len = strlen(text);
    while (len > 0) {
        unsigned char ch = (unsigned char)text[len - 1];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
            text[len - 1] = '\0';
            len -= 1;
        } else {
            break;
        }
    }
    size_t start = 0;
    while (text[start] == ' ' || text[start] == '\t') {
        start += 1;
    }
    if (start > 0) {
        memmove(text, text + start, strlen(text + start) + 1);
    }
}

static int sg_file_contains_token_line(const char* path, const char* token) {
    if (path == NULL || path[0] == '\0' || token == NULL || token[0] == '\0') {
        return 0;
    }
    FILE* fp = fopen(path, "rb");
    if (fp == NULL) {
        return 0;
    }

    char line[512];
    int matched = 0;
    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        sg_trim_ascii_inplace(line);
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        if (strcmp(line, token) == 0) {
            matched = 1;
            break;
        }
    }

    fclose(fp);
    return matched;
}

static long long sg_parse_i64_cstr(const char* text, long long fallback) {
    if (text == NULL || text[0] == '\0') {
        return fallback;
    }
    char* end = NULL;
    long long value = strtoll(text, &end, 10);
    if (end == text || *end != '\0') {
        return fallback;
    }
    return value;
}

static int sg_parse_bool_env(const char* key, int fallback) {
    const char* raw = getenv(key);
    if (raw == NULL || raw[0] == '\0') {
        return fallback;
    }
    if (strcmp(raw, "1") == 0 || strcmp(raw, "TRUE") == 0 || strcmp(raw, "true") == 0) {
        return 1;
    }
    if (strcmp(raw, "ON") == 0 || strcmp(raw, "on") == 0 || strcmp(raw, "YES") == 0 || strcmp(raw, "yes") == 0) {
        return 1;
    }
    if (strcmp(raw, "0") == 0 || strcmp(raw, "FALSE") == 0 || strcmp(raw, "false") == 0) {
        return 0;
    }
    if (strcmp(raw, "OFF") == 0 || strcmp(raw, "off") == 0 || strcmp(raw, "NO") == 0 || strcmp(raw, "no") == 0) {
        return 0;
    }
    return fallback;
}

static int sg_pipe_split_fields(char* line, char* fields[], int max_fields) {
    if (line == NULL || fields == NULL || max_fields <= 0) {
        return 0;
    }
    int count = 0;
    char* p = line;
    while (*p != '\0' && count < max_fields) {
        fields[count++] = p;
        char* sep = strchr(p, '|');
        if (sep == NULL) {
            break;
        }
        *sep = '\0';
        p = sep + 1;
    }
    return count;
}

static const char* sg_auth_user_file_path(void) {
    const char* raw = getenv("SENGOO_AUTH_USER_FILE");
    if (raw == NULL || raw[0] == '\0') {
        return "server/users.auth.tsv";
    }
    return raw;
}

static const char* sg_auth_uuid_binding_file_path(void) {
    const char* raw = getenv("SENGOO_AUTH_UUID_BINDING_FILE");
    if (raw == NULL || raw[0] == '\0') {
        return ".tmp/runtime_host/auth_uuid_bindings.tsv";
    }
    return raw;
}

static int sg_auth_userdb_enabled(void) {
    return sg_parse_bool_env("SENGOO_AUTH_USERDB_ENABLE", 0);
}

static int sg_auth_userdb_autoregister_enabled(void) {
    return sg_parse_bool_env("SENGOO_AUTH_USERDB_AUTO_REGISTER", 1);
}

static int sg_auth_max_players_per_device(void) {
    int value = 50;
    const char* raw = getenv("SENGOO_AUTH_MAX_PLAYERS_PER_DEVICE");
    if (raw != NULL && raw[0] != '\0') {
        char* end = NULL;
        long parsed = strtol(raw, &end, 10);
        if (end != raw && *end == '\0' && parsed > 0 && parsed <= 10000) {
            value = (int)parsed;
        }
    }
    if (value < 1) {
        value = 1;
    } else if (value > 10000) {
        value = 10000;
    }
    return value;
}

static int sg_is_valid_user_name_token(const char* name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    size_t len = strlen(name);
    if (len == 0 || len > 64) {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)name[i];
        if (ch < 32 || ch == 127 || ch == '|') {
            return 0;
        }
    }
    return 1;
}

static const char* sg_auth_whitelist_file_path(void) {
    const char* raw = getenv("SENGOO_AUTH_WHITELIST_FILE");
    if (raw == NULL || raw[0] == '\0') {
        return NULL;
    }
    return raw;
}

static const char* sg_auth_ban_words_file_path(void) {
    const char* raw = getenv("SENGOO_BAN_WORDS_FILE");
    if (raw == NULL || raw[0] == '\0') {
        return NULL;
    }
    return raw;
}

static int sg_ascii_case_contains(const char* text, const char* token) {
    if (text == NULL || token == NULL || token[0] == '\0') {
        return 0;
    }
    size_t text_len = strlen(text);
    size_t token_len = strlen(token);
    if (token_len == 0 || token_len > text_len) {
        return 0;
    }

    for (size_t i = 0; i + token_len <= text_len; i++) {
        size_t j = 0;
        while (j < token_len) {
            unsigned char lhs = (unsigned char)text[i + j];
            unsigned char rhs = (unsigned char)token[j];
            if (tolower(lhs) != tolower(rhs)) {
                break;
            }
            j += 1;
        }
        if (j == token_len) {
            return 1;
        }
    }
    return 0;
}

static int sg_ascii_case_equal(const char* lhs, const char* rhs) {
    if (lhs == NULL || rhs == NULL) {
        return 0;
    }
    size_t lhs_len = strlen(lhs);
    size_t rhs_len = strlen(rhs);
    if (lhs_len != rhs_len) {
        return 0;
    }
    for (size_t i = 0; i < lhs_len; i++) {
        unsigned char a = (unsigned char)lhs[i];
        unsigned char b = (unsigned char)rhs[i];
        if (tolower(a) != tolower(b)) {
            return 0;
        }
    }
    return 1;
}

static int sg_name_in_whitelist(const char* name) {
    const char* path = sg_auth_whitelist_file_path();
    if (path == NULL || path[0] == '\0') {
        return 1;
    }

    FILE* fp = fopen(path, "rb");
    if (fp == NULL) {
        if (!g_auth_whitelist_missing_logged) {
            g_auth_whitelist_missing_logged = 1;
            sg_logf("WARN", "AUTH", "whitelist file missing path=%s", path);
        }
        return 1;
    }

    int found = 0;
    char line[SG_AUTH_LINE_MAX];
    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        sg_trim_ascii_inplace(line);
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        if (strcmp(line, name) == 0) {
            found = 1;
            break;
        }
    }
    fclose(fp);
    return found;
}

static int sg_name_contains_ban_word(const char* name) {
    const char* path = sg_auth_ban_words_file_path();
    if (path == NULL || path[0] == '\0') {
        return 0;
    }

    FILE* fp = fopen(path, "rb");
    if (fp == NULL) {
        if (!g_auth_ban_words_missing_logged) {
            g_auth_ban_words_missing_logged = 1;
            sg_logf("WARN", "AUTH", "ban words file missing path=%s", path);
        }
        return 0;
    }

    int matched = 0;
    char line[SG_AUTH_LINE_MAX];
    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        sg_trim_ascii_inplace(line);
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        if (sg_ascii_case_contains(name, line)) {
            matched = 1;
            break;
        }
    }
    fclose(fp);
    return matched;
}

static int sg_validate_user_name_policy(const char* name, char* out_error, size_t out_error_cap) {
    if (!sg_is_valid_user_name_token(name)) {
        snprintf(out_error, out_error_cap, "%s", "invalid user name");
        return 0;
    }
    if (sg_name_contains_ban_word(name)) {
        snprintf(out_error, out_error_cap, "%s", "invalid user name");
        return 0;
    }
    if (!sg_name_in_whitelist(name)) {
        snprintf(out_error, out_error_cap, "%s", "user name not in whitelist");
        return 0;
    }
    return 1;
}

static uint32_t sg_rotr32(uint32_t value, uint32_t bits) {
    return (value >> bits) | (value << (32U - bits));
}

static int sg_is_hex_string(const char* text, size_t exact_len) {
    if (text == NULL) {
        return 0;
    }
    size_t len = strlen(text);
    if (len != exact_len) {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)text[i];
        int is_digit = (ch >= '0' && ch <= '9');
        int is_lower = (ch >= 'a' && ch <= 'f');
        int is_upper = (ch >= 'A' && ch <= 'F');
        if (!is_digit && !is_lower && !is_upper) {
            return 0;
        }
    }
    return 1;
}

static void sg_bytes_to_hex_lower(const unsigned char* data, size_t len, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return;
    }
    out[0] = '\0';
    if (data == NULL || len == 0) {
        return;
    }
    static const char* k_hex = "0123456789abcdef";
    size_t max_bytes = (out_cap - 1) / 2;
    if (len > max_bytes) {
        len = max_bytes;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char b = data[i];
        out[i * 2] = k_hex[(b >> 4) & 0x0f];
        out[i * 2 + 1] = k_hex[b & 0x0f];
    }
    out[len * 2] = '\0';
}

static void sg_sha256_transform(uint32_t state[8], const unsigned char block[64]) {
    static const uint32_t k[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
    };

    uint32_t w[64];
    for (size_t i = 0; i < 16; i++) {
        size_t off = i * 4;
        w[i] =
            ((uint32_t)block[off] << 24) |
            ((uint32_t)block[off + 1] << 16) |
            ((uint32_t)block[off + 2] << 8) |
            ((uint32_t)block[off + 3]);
    }
    for (size_t i = 16; i < 64; i++) {
        uint32_t s0 = sg_rotr32(w[i - 15], 7) ^ sg_rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = sg_rotr32(w[i - 2], 17) ^ sg_rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = state[0];
    uint32_t b = state[1];
    uint32_t c = state[2];
    uint32_t d = state[3];
    uint32_t e = state[4];
    uint32_t f = state[5];
    uint32_t g = state[6];
    uint32_t h = state[7];

    for (size_t i = 0; i < 64; i++) {
        uint32_t s1 = sg_rotr32(e, 6) ^ sg_rotr32(e, 11) ^ sg_rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + s1 + ch + k[i] + w[i];
        uint32_t s0 = sg_rotr32(a, 2) ^ sg_rotr32(a, 13) ^ sg_rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = s0 + maj;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

static void sg_sha256_digest_bytes(const unsigned char* data, size_t len, unsigned char out[32]) {
    uint32_t state[8] = {
        0x6a09e667U,
        0xbb67ae85U,
        0x3c6ef372U,
        0xa54ff53aU,
        0x510e527fU,
        0x9b05688cU,
        0x1f83d9abU,
        0x5be0cd19U
    };

    size_t offset = 0;
    while (offset + 64 <= len) {
        sg_sha256_transform(state, data + offset);
        offset += 64;
    }

    unsigned char tail[128];
    size_t rem = len - offset;
    if (rem > 0) {
        memcpy(tail, data + offset, rem);
    }
    tail[rem] = 0x80;
    size_t pad_base = rem + 1;
    size_t pad_len = (pad_base + 8 <= 64) ? (64 - pad_base - 8) : (128 - pad_base - 8);
    if (pad_len > 0) {
        memset(tail + pad_base, 0, pad_len);
    }
    size_t len_pos = pad_base + pad_len;
    uint64_t bit_len = (uint64_t)len * 8ULL;
    tail[len_pos + 0] = (unsigned char)(bit_len >> 56);
    tail[len_pos + 1] = (unsigned char)(bit_len >> 48);
    tail[len_pos + 2] = (unsigned char)(bit_len >> 40);
    tail[len_pos + 3] = (unsigned char)(bit_len >> 32);
    tail[len_pos + 4] = (unsigned char)(bit_len >> 24);
    tail[len_pos + 5] = (unsigned char)(bit_len >> 16);
    tail[len_pos + 6] = (unsigned char)(bit_len >> 8);
    tail[len_pos + 7] = (unsigned char)(bit_len);

    size_t total_tail = len_pos + 8;
    for (size_t i = 0; i < total_tail; i += 64) {
        sg_sha256_transform(state, tail + i);
    }

    for (size_t i = 0; i < 8; i++) {
        out[i * 4 + 0] = (unsigned char)(state[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(state[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(state[i] >> 8);
        out[i * 4 + 3] = (unsigned char)(state[i]);
    }
}

static int sg_sha256_password_with_salt_hex(const char* password, const char* salt, char* out_hex, size_t out_hex_cap) {
    if (password == NULL || salt == NULL || out_hex == NULL || out_hex_cap < 65) {
        return 0;
    }
    size_t pass_len = strlen(password);
    size_t salt_len = strlen(salt);
    if (salt_len == 0 || salt_len > 31) {
        return 0;
    }
    if (pass_len + salt_len > 4096) {
        return 0;
    }
    unsigned char* input = (unsigned char*)malloc(pass_len + salt_len);
    if (input == NULL) {
        return 0;
    }
    memcpy(input, password, pass_len);
    memcpy(input + pass_len, salt, salt_len);

    unsigned char digest[32];
    sg_sha256_digest_bytes(input, pass_len + salt_len, digest);
    free(input);

    sg_bytes_to_hex_lower(digest, sizeof(digest), out_hex, out_hex_cap);
    return out_hex[0] != '\0';
}

static int sg_generate_salt_hex8(char* out, size_t out_cap) {
    if (out == NULL || out_cap < 9) {
        return 0;
    }
    static int seeded = 0;
    if (!seeded) {
        unsigned int seed = (unsigned int)time(NULL);
        seed ^= (unsigned int)(sg_monotonic_ms() & 0xffffffffU);
        srand(seed);
        seeded = 1;
    }
    unsigned int value = (((unsigned int)rand()) << 16) ^ (unsigned int)rand();
    int written = snprintf(out, out_cap, "%08x", value);
    return written == 8;
}

static int sg_parse_inline_sha256_password(
    const char* stored_password,
    char* out_salt,
    size_t out_salt_cap,
    char* out_hash,
    size_t out_hash_cap
) {
    if (stored_password == NULL || out_salt == NULL || out_hash == NULL || out_salt_cap == 0 || out_hash_cap == 0) {
        return 0;
    }
    out_salt[0] = '\0';
    out_hash[0] = '\0';
    if (strncmp(stored_password, "sha256:", 7) != 0) {
        return 0;
    }
    const char* salt = stored_password + 7;
    const char* sep = strchr(salt, ':');
    if (sep == NULL || sep == salt) {
        return 0;
    }
    size_t salt_len = (size_t)(sep - salt);
    const char* hash = sep + 1;
    if (salt_len + 1 > out_salt_cap || strlen(hash) + 1 > out_hash_cap) {
        return 0;
    }
    memcpy(out_salt, salt, salt_len);
    out_salt[salt_len] = '\0';
    snprintf(out_hash, out_hash_cap, "%s", hash);
    return sg_is_hex_string(out_hash, 64);
}

static int sg_parse_user_record_line(const char* line_text, sg_auth_user_record* out, long long* max_id) {
    if (line_text == NULL || out == NULL) {
        return 0;
    }
    char line[SG_AUTH_LINE_MAX];
    snprintf(line, sizeof(line), "%s", line_text);
    sg_trim_ascii_inplace(line);
    if (line[0] == '\0' || line[0] == '#') {
        return 0;
    }

    char* fields[8];
    int field_count = sg_pipe_split_fields(line, fields, 8);
    if (field_count < 6) {
        return 0;
    }

    long long id = sg_parse_i64_cstr(fields[0], 0);
    if (id <= 0) {
        return 0;
    }
    if (max_id != NULL && id > *max_id) {
        *max_id = id;
    }

    out->found = 1;
    out->id = id;
    snprintf(out->name, sizeof(out->name), "%s", fields[1]);
    snprintf(out->password, sizeof(out->password), "%s", fields[2]);
    out->salt[0] = '\0';
    if (field_count >= 7 && fields[6] != NULL && fields[6][0] != '\0') {
        snprintf(out->salt, sizeof(out->salt), "%s", fields[6]);
    }
    snprintf(out->avatar, sizeof(out->avatar), "%s", fields[3]);
    out->banned = (int)sg_parse_i64_cstr(fields[4], 0);
    out->ban_expire_epoch = sg_parse_i64_cstr(fields[5], 0);
    if (out->avatar[0] == '\0') {
        snprintf(out->avatar, sizeof(out->avatar), "%s", "liubei");
    }
    return 1;
}

static int sg_load_auth_user_record(const char* user_file, const char* user_name, sg_auth_user_record* out, long long* max_id) {
    if (out == NULL || user_name == NULL) {
        return 0;
    }
    memset(out, 0, sizeof(*out));
    if (max_id != NULL) {
        *max_id = 0;
    }
    FILE* fp = fopen(user_file, "rb");
    if (fp == NULL) {
        return 1;
    }

    char line[SG_AUTH_LINE_MAX];
    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        sg_auth_user_record record;
        memset(&record, 0, sizeof(record));
        if (!sg_parse_user_record_line(line, &record, max_id)) {
            continue;
        }
        if (strcmp(record.name, user_name) == 0) {
            *out = record;
        }
    }
    fclose(fp);
    return 1;
}

static int sg_count_uuid_bindings(const char* binding_file, const char* uuid) {
    if (binding_file == NULL || uuid == NULL || uuid[0] == '\0') {
        return 0;
    }
    FILE* fp = fopen(binding_file, "rb");
    if (fp == NULL) {
        return 0;
    }

    int count = 0;
    char line[SG_AUTH_LINE_MAX];
    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        sg_trim_ascii_inplace(line);
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        char* sep = strchr(line, '|');
        if (sep == NULL) {
            continue;
        }
        *sep = '\0';
        if (strcmp(line, uuid) == 0) {
            count += 1;
        }
    }
    fclose(fp);
    return count;
}

static int sg_append_auth_line(const char* path, const char* line) {
    if (path == NULL || path[0] == '\0' || line == NULL) {
        return 0;
    }

    if (strncmp(path, ".tmp/runtime_host/", 18) == 0) {
        sg_mkdir(".tmp");
        sg_mkdir(".tmp/runtime_host");
    }

    FILE* fp = fopen(path, "ab");
    if (fp == NULL) {
        return 0;
    }
    size_t line_len = strlen(line);
    size_t wrote_line = fwrite(line, 1, line_len, fp);
    size_t wrote_nl = fwrite("\n", 1, 1, fp);
    fclose(fp);
    return wrote_line == line_len && wrote_nl == 1;
}

static int sg_format_user_record_line(
    const sg_auth_user_record* record,
    int banned,
    long long ban_expire_epoch,
    char* out,
    size_t out_cap
) {
    if (record == NULL || out == NULL || out_cap == 0) {
        return 0;
    }
    int written = 0;
    if (record->salt[0] != '\0') {
        written = snprintf(
            out,
            out_cap,
            "%lld|%s|%s|%s|%d|%lld|%s",
            record->id,
            record->name,
            record->password,
            record->avatar,
            banned,
            ban_expire_epoch,
            record->salt
        );
    } else {
        written = snprintf(
            out,
            out_cap,
            "%lld|%s|%s|%s|%d|%lld",
            record->id,
            record->name,
            record->password,
            record->avatar,
            banned,
            ban_expire_epoch
        );
    }
    return written > 0 && written < (int)out_cap;
}

static int sg_rewrite_user_ban_status(
    const char* user_file,
    const sg_auth_user_record* target,
    int banned,
    long long ban_expire_epoch
) {
    if (user_file == NULL || user_file[0] == '\0' || target == NULL || target->id <= 0 || target->name[0] == '\0') {
        return 0;
    }
    FILE* in = fopen(user_file, "rb");
    if (in == NULL) {
        return 0;
    }

    char tmp_file[SG_AUTH_LINE_MAX];
    int tmp_len = snprintf(tmp_file, sizeof(tmp_file), "%s.tmp", user_file);
    if (tmp_len <= 0 || tmp_len >= (int)sizeof(tmp_file)) {
        fclose(in);
        return 0;
    }
    FILE* out = fopen(tmp_file, "wb");
    if (out == NULL) {
        fclose(in);
        return 0;
    }

    int updated = 0;
    char raw_line[SG_AUTH_LINE_MAX];
    while (fgets(raw_line, (int)sizeof(raw_line), in) != NULL) {
        char parse_line[SG_AUTH_LINE_MAX];
        snprintf(parse_line, sizeof(parse_line), "%s", raw_line);
        sg_auth_user_record parsed;
        memset(&parsed, 0, sizeof(parsed));
        if (sg_parse_user_record_line(parse_line, &parsed, NULL) &&
            parsed.id == target->id &&
            strcmp(parsed.name, target->name) == 0) {
            char rewritten[SG_AUTH_LINE_MAX];
            if (sg_format_user_record_line(target, banned, ban_expire_epoch, rewritten, sizeof(rewritten))) {
                fwrite(rewritten, 1, strlen(rewritten), out);
                fwrite("\n", 1, 1, out);
                updated = 1;
                continue;
            }
        }
        fwrite(raw_line, 1, strlen(raw_line), out);
    }

    fclose(in);
    fclose(out);

    if (!updated) {
        remove(tmp_file);
        return 0;
    }

    if (remove(user_file) != 0) {
        remove(tmp_file);
        return 0;
    }
    if (rename(tmp_file, user_file) != 0) {
        return 0;
    }
    return 1;
}

static int sg_format_ban_expire_local(long long epoch_sec, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0 || epoch_sec <= 0) {
        return 0;
    }
    time_t t = (time_t)epoch_sec;
    struct tm tm_value;
#ifdef _WIN32
    if (localtime_s(&tm_value, &t) != 0) {
        return 0;
    }
#else
    if (localtime_r(&t, &tm_value) == NULL) {
        return 0;
    }
#endif
    int written = snprintf(
        out,
        out_cap,
        "%04d-%02d-%02d %02d:%02d:%02d.",
        tm_value.tm_year + 1900,
        tm_value.tm_mon + 1,
        tm_value.tm_mday,
        tm_value.tm_hour,
        tm_value.tm_min,
        tm_value.tm_sec
    );
    return written > 0 && written < (int)out_cap;
}

static int sg_password_bytes_are_printable(const unsigned char* data, size_t len) {
    if (data == NULL) {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = data[i];
        if (ch < 32 || ch > 126) {
            return 0;
        }
    }
    return 1;
}

static void sg_password_bytes_to_hex(const unsigned char* data, size_t len, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return;
    }
    out[0] = '\0';
    if (data == NULL || len == 0) {
        return;
    }
    static const char* k_hex = "0123456789abcdef";
    size_t max_bytes = (out_cap - 1) / 2;
    if (len > max_bytes) {
        len = max_bytes;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char b = data[i];
        out[i * 2] = k_hex[(b >> 4) & 0x0f];
        out[i * 2 + 1] = k_hex[b & 0x0f];
    }
    out[len * 2] = '\0';
}

static int sg_auth_rsa_decrypt_enabled(void) {
    return sg_parse_bool_env("SENGOO_AUTH_RSA_DECRYPT_ENABLE", 0);
}

static const char* sg_auth_rsa_private_key_path(void) {
    const char* raw = getenv("SENGOO_AUTH_RSA_PRIVATE_KEY_PATH");
    if (raw == NULL || raw[0] == '\0') {
        return "server/rsa";
    }
    return raw;
}

static const char* sg_auth_openssl_exe(void) {
    const char* raw = getenv("SENGOO_AUTH_OPENSSL_EXE");
    if (raw == NULL || raw[0] == '\0') {
        return "openssl";
    }
    return raw;
}

static int sg_try_decrypt_password_with_openssl(
    const unsigned char* encrypted_bytes,
    size_t encrypted_len,
    char* out,
    size_t out_cap
) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }
    out[0] = '\0';
    if (encrypted_bytes == NULL || encrypted_len == 0 || encrypted_len > 8192) {
        return 0;
    }
    if (!sg_auth_rsa_decrypt_enabled()) {
        return 0;
    }

    const char* openssl_exe = sg_auth_openssl_exe();
    const char* private_key = sg_auth_rsa_private_key_path();
    if (openssl_exe == NULL || openssl_exe[0] == '\0' || private_key == NULL || private_key[0] == '\0') {
        return 0;
    }

    sg_mkdir(".tmp");
    sg_mkdir(".tmp/runtime_host");

    long long stamp = sg_monotonic_ms();
    char in_path[SG_AUTH_LINE_MAX];
    char out_path[SG_AUTH_LINE_MAX];
    int in_len = snprintf(in_path, sizeof(in_path), ".tmp/runtime_host/auth_pw_in_%lld.bin", stamp);
    int out_len = snprintf(out_path, sizeof(out_path), ".tmp/runtime_host/auth_pw_out_%lld.bin", stamp);
    if (in_len <= 0 || in_len >= (int)sizeof(in_path) || out_len <= 0 || out_len >= (int)sizeof(out_path)) {
        return 0;
    }

    FILE* in_fp = fopen(in_path, "wb");
    if (in_fp == NULL) {
        return 0;
    }
    size_t wrote = fwrite(encrypted_bytes, 1, encrypted_len, in_fp);
    fclose(in_fp);
    if (wrote != encrypted_len) {
        remove(in_path);
        return 0;
    }

    char cmd[SG_EXTENSION_CMD_MAX];
#ifdef _WIN32
    int cmd_len = snprintf(
        cmd,
        sizeof(cmd),
        "\"%s\" pkeyutl -decrypt -inkey \"%s\" -in \"%s\" -out \"%s\" >nul 2>&1",
        openssl_exe,
        private_key,
        in_path,
        out_path
    );
#else
    int cmd_len = snprintf(
        cmd,
        sizeof(cmd),
        "\"%s\" pkeyutl -decrypt -inkey \"%s\" -in \"%s\" -out \"%s\" >/dev/null 2>&1",
        openssl_exe,
        private_key,
        in_path,
        out_path
    );
#endif
    if (cmd_len <= 0 || cmd_len >= (int)sizeof(cmd)) {
        remove(in_path);
        return 0;
    }

    int rc = system(cmd);
    remove(in_path);
    if (rc != 0) {
        remove(out_path);
        return 0;
    }

    FILE* out_fp = fopen(out_path, "rb");
    if (out_fp == NULL) {
        remove(out_path);
        return 0;
    }
    unsigned char tmp[SG_AUTH_PASSWORD_MAX];
    size_t n = fread(tmp, 1, sizeof(tmp), out_fp);
    fclose(out_fp);
    remove(out_path);
    if (n == 0) {
        return 0;
    }

    size_t text_len = 0;
    while (text_len < n && tmp[text_len] != '\0') {
        text_len += 1;
    }
    if (text_len == 0) {
        text_len = n;
    }
    if (text_len > out_cap - 1) {
        text_len = out_cap - 1;
    }
    memcpy(out, tmp, text_len);
    out[text_len] = '\0';
    return text_len > 0;
}

static int sg_should_strip_password_prefix32(void) {
    return sg_parse_bool_env("SENGOO_AUTH_PASSWORD_STRIP32", 1);
}

static int sg_make_password_text_candidate(const sg_setup_fields* setup, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }
    out[0] = '\0';
    if (setup == NULL || setup->password_raw_len == 0) {
        return 0;
    }
    if (!sg_password_bytes_are_printable(setup->password_raw, setup->password_raw_len)) {
        return 0;
    }
    size_t copy_len = setup->password_raw_len;
    if (copy_len > out_cap - 1) {
        copy_len = out_cap - 1;
    }
    memcpy(out, setup->password_raw, copy_len);
    out[copy_len] = '\0';
    return 1;
}

static int sg_password_matches_record(
    const char* stored_password,
    const char* candidate_text,
    const char* stripped_text,
    const char* candidate_hex
) {
    if (stored_password == NULL) {
        return 0;
    }
    if (strncmp(stored_password, "hex:", 4) == 0) {
        const char* expect_hex = stored_password + 4;
        if (candidate_hex == NULL || candidate_hex[0] == '\0') {
            return 0;
        }
        return strcmp(expect_hex, candidate_hex) == 0;
    }
    if (candidate_text != NULL && candidate_text[0] != '\0' && strcmp(stored_password, candidate_text) == 0) {
        return 1;
    }
    if (stripped_text != NULL && stripped_text[0] != '\0' && strcmp(stored_password, stripped_text) == 0) {
        return 1;
    }
    return 0;
}

static int sg_password_matches_salted_sha256(
    const char* stored_hash_hex,
    const char* salt,
    const char* candidate_text,
    const char* stripped_text
) {
    if (stored_hash_hex == NULL || salt == NULL || stored_hash_hex[0] == '\0' || salt[0] == '\0') {
        return 0;
    }
    if (!sg_is_hex_string(stored_hash_hex, 64)) {
        return 0;
    }
    char digest_hex[65];
    digest_hex[0] = '\0';
    if (candidate_text != NULL && candidate_text[0] != '\0') {
        if (sg_sha256_password_with_salt_hex(candidate_text, salt, digest_hex, sizeof(digest_hex)) &&
            sg_ascii_case_equal(stored_hash_hex, digest_hex)) {
            return 1;
        }
    }
    if (stripped_text != NULL && stripped_text[0] != '\0') {
        if (sg_sha256_password_with_salt_hex(stripped_text, salt, digest_hex, sizeof(digest_hex)) &&
            sg_ascii_case_equal(stored_hash_hex, digest_hex)) {
            return 1;
        }
    }
    return 0;
}

static int sg_check_userdb_credentials(
    const sg_setup_fields* setup,
    long long* out_player_id,
    char* out_avatar,
    size_t out_avatar_cap,
    char* out_error,
    size_t out_error_cap
) {
    if (out_player_id != NULL) {
        *out_player_id = 0;
    }
    if (out_avatar != NULL && out_avatar_cap > 0) {
        out_avatar[0] = '\0';
    }
    if (out_error != NULL && out_error_cap > 0) {
        out_error[0] = '\0';
    }
    if (setup == NULL) {
        return 0;
    }
    if (!sg_validate_user_name_policy(setup->name, out_error, out_error_cap)) {
        return 0;
    }
    if (!sg_auth_userdb_enabled()) {
        return 1;
    }
    char candidate_password[SG_AUTH_PASSWORD_MAX];
    char stripped_password[SG_AUTH_PASSWORD_MAX];
    char candidate_password_hex[SG_AUTH_PASSWORD_MAX * 2 + 1];
    candidate_password[0] = '\0';
    stripped_password[0] = '\0';
    candidate_password_hex[0] = '\0';

    int has_text_password = sg_make_password_text_candidate(setup, candidate_password, sizeof(candidate_password));
    if (!has_text_password && setup->password[0] != '\0') {
        snprintf(candidate_password, sizeof(candidate_password), "%s", setup->password);
        has_text_password = 1;
    }
    if (!has_text_password && setup->password_raw_len > 0) {
        if (sg_try_decrypt_password_with_openssl(
            setup->password_raw,
            setup->password_raw_len,
            candidate_password,
            sizeof(candidate_password)
        )) {
            has_text_password = 1;
        } else if (sg_auth_rsa_decrypt_enabled() && !g_auth_rsa_decrypt_error_logged) {
            g_auth_rsa_decrypt_error_logged = 1;
            sg_logf("WARN", "AUTH", "rsa password decrypt failed, fallback to raw password mode");
        }
    }
    if (setup->password_raw_len > 0) {
        sg_password_bytes_to_hex(setup->password_raw, setup->password_raw_len, candidate_password_hex, sizeof(candidate_password_hex));
    }
    if (has_text_password && sg_should_strip_password_prefix32()) {
        size_t pass_len = strlen(candidate_password);
        if (pass_len > 32) {
            snprintf(stripped_password, sizeof(stripped_password), "%s", candidate_password + 32);
        }
    }

    if (!has_text_password && candidate_password_hex[0] == '\0') {
        snprintf(out_error, out_error_cap, "%s", "unknown password error");
        return 0;
    }

    const char* user_file = sg_auth_user_file_path();
    sg_auth_user_record record;
    long long max_id = 0;
    if (!sg_load_auth_user_record(user_file, setup->name, &record, &max_id)) {
        snprintf(out_error, out_error_cap, "%s", "server internal auth storage error");
        return 0;
    }

    if (record.found) {
        if (record.banned) {
            long long now_sec = (long long)time(NULL);
            if (record.ban_expire_epoch > 0 && record.ban_expire_epoch > now_sec) {
                char expire_text[64];
                if (sg_format_ban_expire_local(record.ban_expire_epoch, expire_text, sizeof(expire_text))) {
                    snprintf(out_error, out_error_cap, "[\"you have been banned! expire at %%1\", \"%s\"]", expire_text);
                } else {
                    snprintf(out_error, out_error_cap, "%s", "you have been banned!");
                }
                return 0;
            }
            if (record.ban_expire_epoch <= 0 || record.ban_expire_epoch > now_sec) {
                snprintf(out_error, out_error_cap, "%s", "you have been banned!");
                return 0;
            }
            if (record.ban_expire_epoch > 0 && record.ban_expire_epoch <= now_sec) {
                (void)sg_rewrite_user_ban_status(user_file, &record, 0, 0);
                record.banned = 0;
                record.ban_expire_epoch = 0;
            }
        }
        int matched = 0;
        if (record.salt[0] != '\0') {
            matched = sg_password_matches_salted_sha256(
                record.password,
                record.salt,
                candidate_password,
                stripped_password
            );
        } else {
            char inline_salt[32];
            char inline_hash[96];
            inline_salt[0] = '\0';
            inline_hash[0] = '\0';
            if (sg_parse_inline_sha256_password(record.password, inline_salt, sizeof(inline_salt), inline_hash, sizeof(inline_hash))) {
                matched = sg_password_matches_salted_sha256(
                    inline_hash,
                    inline_salt,
                    candidate_password,
                    stripped_password
                );
            } else {
                matched = sg_password_matches_record(
                    record.password,
                    candidate_password,
                    stripped_password,
                    candidate_password_hex
                );
            }
        }
        if (!matched) {
            snprintf(out_error, out_error_cap, "%s", "username or password error");
            return 0;
        }
        if (out_player_id != NULL) {
            *out_player_id = record.id;
        }
        if (out_avatar != NULL && out_avatar_cap > 0) {
            snprintf(out_avatar, out_avatar_cap, "%s", record.avatar);
        }
        return 1;
    }

    if (!sg_auth_userdb_autoregister_enabled()) {
        snprintf(out_error, out_error_cap, "%s", "username or password error");
        return 0;
    }

    int max_per_device = sg_auth_max_players_per_device();
    const char* binding_file = sg_auth_uuid_binding_file_path();
    if (setup->uuid[0] != '\0' && sg_count_uuid_bindings(binding_file, setup->uuid) >= max_per_device) {
        snprintf(out_error, out_error_cap, "%s", "cannot register more new users on this device");
        return 0;
    }

    long long new_id = (max_id > 0 ? max_id + 1 : 1);
    const char* default_avatar = getenv("SENGOO_DEFAULT_AVATAR");
    if (default_avatar == NULL || default_avatar[0] == '\0') {
        default_avatar = "liubei";
    }
    const char* store_password = candidate_password;
    if (stripped_password[0] != '\0') {
        store_password = stripped_password;
    }
    if (store_password == NULL || store_password[0] == '\0') {
        snprintf(out_error, out_error_cap, "%s", "unknown password error");
        return 0;
    }

    char salt_hex[16];
    char password_hash_hex[65];
    salt_hex[0] = '\0';
    password_hash_hex[0] = '\0';
    if (!sg_generate_salt_hex8(salt_hex, sizeof(salt_hex)) ||
        !sg_sha256_password_with_salt_hex(store_password, salt_hex, password_hash_hex, sizeof(password_hash_hex))) {
        snprintf(out_error, out_error_cap, "%s", "server internal auth storage error");
        return 0;
    }

    char user_line[SG_AUTH_LINE_MAX];
    int user_line_len = snprintf(
        user_line,
        sizeof(user_line),
        "%lld|%s|%s|%s|0|0|%s",
        new_id,
        setup->name,
        password_hash_hex,
        default_avatar,
        salt_hex
    );
    if (user_line_len <= 0 || user_line_len >= (int)sizeof(user_line)) {
        snprintf(out_error, out_error_cap, "%s", "server internal auth storage error");
        return 0;
    }
    if (!sg_append_auth_line(user_file, user_line)) {
        snprintf(out_error, out_error_cap, "%s", "server internal auth storage error");
        return 0;
    }

    if (setup->uuid[0] != '\0') {
        char bind_line[SG_AUTH_LINE_MAX];
        int bind_len = snprintf(bind_line, sizeof(bind_line), "%s|%s", setup->uuid, setup->name);
        if (bind_len > 0 && bind_len < (int)sizeof(bind_line)) {
            (void)sg_append_auth_line(binding_file, bind_line);
        }
    }

    if (out_player_id != NULL) {
        *out_player_id = new_id;
    }
    if (out_avatar != NULL && out_avatar_cap > 0) {
        snprintf(out_avatar, out_avatar_cap, "%s", default_avatar);
    }
    return 1;
}

static int sg_is_ip_banned(const char* ip) {
    const char* path = getenv("SENGOO_BAN_IP_FILE");
    return sg_file_contains_token_line(path, ip);
}

static int sg_is_ip_temp_banned(const char* ip) {
    const char* path = getenv("SENGOO_TEMP_BAN_IP_FILE");
    return sg_file_contains_token_line(path, ip);
}

static int sg_is_uuid_banned(const char* uuid) {
    const char* path = getenv("SENGOO_BAN_UUID_FILE");
    return sg_file_contains_token_line(path, uuid);
}

static long long sg_now_unix_ms(void) {
#ifdef _WIN32
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER uli;
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;
    unsigned long long unix_100ns = uli.QuadPart - 116444736000000000ULL;
    return (long long)(unix_100ns / 10000ULL);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000L);
#endif
}

static sg_socket_entry* sg_find_tcp_connection_entry(long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_tcp_connections[i].used && g_tcp_connections[i].handle == handle) {
            return &g_tcp_connections[i];
        }
    }
    return NULL;
}

static int sg_force_close_tcp_connection(long long handle) {
    sg_socket_entry* entry = sg_find_tcp_connection_entry(handle);
    if (entry != NULL) {
        sg_socket_t s = entry->socket;
        entry->used = 0;
        entry->handle = 0;
        entry->socket = SG_INVALID_SOCKET;
        if (s != SG_INVALID_SOCKET) {
            sg_close_socket(s);
        }
    }
    sg_tcp_stream_detach(handle);
    sg_auth_state_detach(handle);
    return entry != NULL;
}

static int sg_kick_duplicate_online_sessions(long long current_handle, long long player_id, const char* player_name) {
    long long targets[SG_MAX_NET_HANDLES];
    int target_count = 0;
    int has_name = (player_name != NULL && player_name[0] != '\0');

    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        sg_auth_state* state = &g_auth_states[i];
        if (!state->used || !state->auth_passed || state->handle == current_handle) {
            continue;
        }
        int same_player = (player_id > 0 && state->player_id > 0 && state->player_id == player_id);
        int same_name = (has_name && state->player_name[0] != '\0' && strcmp(state->player_name, player_name) == 0);
        if (!same_player && !same_name) {
            continue;
        }
        if (target_count < SG_MAX_NET_HANDLES) {
            targets[target_count++] = state->handle;
        }
    }

    int kicked = 0;
    for (int i = 0; i < target_count; i++) {
        long long handle = targets[i];
        sg_socket_entry* entry = sg_find_tcp_connection_entry(handle);
        if (entry != NULL) {
            (void)sg_send_errordlg_and_close(entry->socket, "others logged in again with this name");
        }
        if (sg_force_close_tcp_connection(handle)) {
            kicked += 1;
        }
    }
    return kicked;
}

static int sg_send_post_setup_packets(
    sg_socket_t socket,
    const sg_setup_fields* setup,
    long long resolved_player_id,
    const char* resolved_avatar
) {
    if (setup == NULL) {
        return 0;
    }
    const char* avatar = resolved_avatar;
    if (avatar == NULL || avatar[0] == '\0') {
        avatar = getenv("SENGOO_DEFAULT_AVATAR");
    }
    if (avatar == NULL || avatar[0] == '\0') {
        avatar = "liubei";
    }
    long long player_id = resolved_player_id;
    if (player_id <= 0) {
        player_id = 1;
        const char* player_id_raw = getenv("SENGOO_DEFAULT_PLAYER_ID");
        if (player_id_raw != NULL && player_id_raw[0] != '\0') {
            long parsed = strtol(player_id_raw, NULL, 10);
            if (parsed > 0) {
                player_id = (long long)parsed;
            }
        }
    }
    unsigned char setup_payload[SG_AUTH_NAME_MAX + 256];
    size_t setup_payload_len = 0;
    {
        size_t idx = 0;
        int ok = 1;
        ok = ok && sg_cbor_write_type_and_len(setup_payload, sizeof(setup_payload), &idx, 4, 4);
        ok = ok && sg_cbor_write_signed_integer(setup_payload, sizeof(setup_payload), &idx, player_id);
        ok = ok && sg_cbor_write_bytes_like(setup_payload, sizeof(setup_payload), &idx, 2, (const unsigned char*)setup->name, strlen(setup->name));
        ok = ok && sg_cbor_write_bytes_like(setup_payload, sizeof(setup_payload), &idx, 2, (const unsigned char*)avatar, strlen(avatar));
        ok = ok && sg_cbor_write_signed_integer(setup_payload, sizeof(setup_payload), &idx, sg_now_unix_ms());
        if (!ok) {
            return 0;
        }
        setup_payload_len = idx;
    }
    if (!sg_send_server_notification(socket, "Setup", setup_payload, setup_payload_len, 2)) {
        return 0;
    }

    unsigned char settings_payload[512];
    size_t settings_len = 0;
    {
        size_t idx = 0;
        const char* motd = getenv("SENGOO_MOTD");
        if (motd == NULL) {
            motd = "";
        }
        int ok = 1;
        ok = ok && sg_cbor_write_type_and_len(settings_payload, sizeof(settings_payload), &idx, 4, 3);
        ok = ok && sg_cbor_write_bytes_like(settings_payload, sizeof(settings_payload), &idx, 2, (const unsigned char*)motd, strlen(motd));
        ok = ok && sg_cbor_write_type_and_len(settings_payload, sizeof(settings_payload), &idx, 4, 0);
        ok = ok && sg_cbor_write_type_and_len(settings_payload, sizeof(settings_payload), &idx, 4, 0);
        if (!ok) {
            return 0;
        }
        settings_len = idx;
    }
    if (!sg_send_server_notification(socket, "SetServerSettings", settings_payload, settings_len, 2)) {
        return 0;
    }

    unsigned char game_time_payload[64];
    size_t game_time_len = 0;
    {
        size_t idx = 0;
        int ok = 1;
        ok = ok && sg_cbor_write_type_and_len(game_time_payload, sizeof(game_time_payload), &idx, 4, 2);
        ok = ok && sg_cbor_write_signed_integer(game_time_payload, sizeof(game_time_payload), &idx, player_id);
        ok = ok && sg_cbor_write_signed_integer(game_time_payload, sizeof(game_time_payload), &idx, 0);
        if (!ok) {
            return 0;
        }
        game_time_len = idx;
    }
    return sg_send_server_notification(socket, "AddTotalGameTime", game_time_payload, game_time_len, 2);
}

static int sg_handle_auth_setup_packet(long long conn_handle, sg_socket_t socket, const sg_cbor_wire_packet* packet, sg_auth_state* auth_state) {
    if (packet == NULL || auth_state == NULL) {
        return -1;
    }
    if (packet->request_id != -2) {
        sg_send_errordlg_and_close(socket, "INVALID SETUP STRING");
        return -2;
    }
    if ((packet->packet_type & SG_PACKET_TYPE_NOTIFICATION) == 0 ||
        (packet->packet_type & SG_PACKET_SRC_CLIENT) == 0 ||
        (packet->packet_type & SG_PACKET_DEST_SERVER) == 0) {
        sg_send_errordlg_and_close(socket, "INVALID SETUP STRING");
        return -2;
    }

    sg_setup_fields setup;
    if (!sg_parse_setup_payload(packet->payload_ptr, packet->payload_len, &setup)) {
        sg_send_errordlg_and_close(socket, "INVALID SETUP STRING");
        return -2;
    }
    auth_state->setup_received = 1;

    if (!sg_is_supported_client_version(setup.version)) {
        const char* msg = "[\"server supports version %1, please update\",\"0.5.19+\"]";
        sg_send_errordlg_and_close(socket, msg);
        return -2;
    }

    if (sg_is_uuid_banned(setup.uuid)) {
        sg_send_errordlg_and_close(socket, "you have been banned!");
        return -2;
    }

    if (sg_should_enforce_md5() && !sg_md5_matches_expected(setup.md5)) {
        sg_send_md5_failure_and_update_package(socket);
        return -2;
    }

    long long resolved_player_id = 0;
    char resolved_avatar[SG_AUTH_AVATAR_MAX];
    char auth_error[256];
    resolved_avatar[0] = '\0';
    auth_error[0] = '\0';
    if (!sg_check_userdb_credentials(
        &setup,
        &resolved_player_id,
        resolved_avatar,
        sizeof(resolved_avatar),
        auth_error,
        sizeof(auth_error)
    )) {
        const char* msg = (auth_error[0] == '\0' ? "username or password error" : auth_error);
        sg_send_errordlg_and_close(socket, msg);
        return -2;
    }

    int kicked_duplicate = sg_kick_duplicate_online_sessions(conn_handle, resolved_player_id, setup.name);
    if (kicked_duplicate > 0) {
        sg_logf(
            "INFO",
            "AUTH",
            "duplicate session kicked name=%s player_id=%lld kicked=%d",
            setup.name,
            resolved_player_id,
            kicked_duplicate
        );
    }

    auth_state->auth_passed = 1;
    auth_state->player_id = resolved_player_id;
    snprintf(auth_state->player_name, sizeof(auth_state->player_name), "%s", setup.name);
    if (!sg_send_post_setup_packets(socket, &setup, resolved_player_id, resolved_avatar)) {
        return -1;
    }
    sg_logf(
        "INFO",
        "AUTH",
        "setup accepted name=%s version=%s uuid=%s player_id=%lld userdb=%d",
        setup.name,
        setup.version,
        setup.uuid,
        (resolved_player_id > 0 ? resolved_player_id : -1),
        sg_auth_userdb_enabled()
    );
    return 1;
}

static int sg_handle_cbor_wire_packet(long long conn_handle, sg_socket_t socket, const sg_cbor_wire_packet* packet) {
    if (packet == NULL) {
        return -1;
    }
    sg_auth_state* auth_state = sg_auth_state_find(conn_handle);
    if (auth_state == NULL && !sg_auth_state_attach(conn_handle)) {
        return -1;
    }
    auth_state = sg_auth_state_find(conn_handle);
    if (auth_state == NULL) {
        return -1;
    }
    auth_state->last_activity_ms = sg_monotonic_ms();

    char command_tag[96];
    sg_packet_token(packet->command_ptr, packet->command_len, command_tag, sizeof(command_tag));
    int is_setup_notification =
        ((packet->packet_type & SG_PACKET_TYPE_NOTIFICATION) != 0) &&
        sg_packet_command_equals(packet, "Setup");

    if (!auth_state->auth_passed) {
        if (is_setup_notification) {
            return sg_handle_auth_setup_packet(conn_handle, socket, packet, auth_state);
        }
        sg_logf(
            "WARN",
            "AUTH",
            "pre-auth packet rejected req=%lld type=%lld cmd=%s",
            packet->request_id,
            packet->packet_type,
            command_tag
        );
        sg_send_errordlg_and_close(socket, "INVALID SETUP STRING");
        return -2;
    }

    if ((packet->packet_type & SG_PACKET_TYPE_REQUEST) != 0) {
        int close_after_reply = 0;
        int reply_payload_major = packet->payload_major;
        const unsigned char* reply_payload_ptr = packet->payload_ptr;
        size_t reply_payload_len = packet->payload_len;
        unsigned char reply_payload_local[256];

        if (sg_packet_command_equals(packet, "ping")) {
            const char* pong = "PONG";
            size_t pong_len = strlen(pong);
            if (pong_len < sizeof(reply_payload_local)) {
                memcpy(reply_payload_local, pong, pong_len);
                reply_payload_major = 2;
                reply_payload_ptr = reply_payload_local;
                reply_payload_len = pong_len;
            }
        } else if (sg_packet_command_equals(packet, "bye")) {
            const char* goodbye = "Goodbye";
            size_t goodbye_len = strlen(goodbye);
            if (goodbye_len < sizeof(reply_payload_local)) {
                memcpy(reply_payload_local, goodbye, goodbye_len);
                reply_payload_major = 2;
                reply_payload_ptr = reply_payload_local;
                reply_payload_len = goodbye_len;
                close_after_reply = 1;
            }
        }

        long long reply_type = (packet->packet_type & ~((long long)SG_PACKET_TYPE_REQUEST)) | SG_PACKET_TYPE_REPLY;
        size_t out_cap = 96 + packet->command_len + reply_payload_len;
        unsigned char* out = (unsigned char*)malloc(out_cap);
        if (out == NULL) {
            return -1;
        }
        size_t idx = 0;
        int ok = 1;
        ok = ok && sg_cbor_write_type_and_len(out, out_cap, &idx, 4, 4);
        ok = ok && sg_cbor_write_signed_integer(out, out_cap, &idx, packet->request_id);
        ok = ok && sg_cbor_write_signed_integer(out, out_cap, &idx, reply_type);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, packet->command_major, packet->command_ptr, packet->command_len);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, reply_payload_major, reply_payload_ptr, reply_payload_len);

        if (!ok || !sg_send_all(socket, out, idx)) {
            free(out);
            return -1;
        }
        sg_logf(
            "INFO",
            "PROTO",
            "cbor request handled req=%lld type=%lld cmd=%s payload=%u",
            packet->request_id,
            packet->packet_type,
            command_tag,
            (unsigned)reply_payload_len
        );
        free(out);
        if (close_after_reply) {
            return -2;
        }
        return 1;
    }

    if ((packet->packet_type & SG_PACKET_TYPE_NOTIFICATION) != 0) {
        if (is_setup_notification) {
            sg_logf("INFO", "AUTH", "duplicate setup ignored req=%lld", packet->request_id);
            return 1;
        }
        if (sg_packet_command_equals(packet, "bye")) {
            sg_logf("INFO", "PROTO", "client bye notification req=%lld", packet->request_id);
            return -2;
        }
        sg_logf(
            "INFO",
            "PROTO",
            "cbor notification req=%lld type=%lld cmd=%s payload=%u",
            packet->request_id,
            packet->packet_type,
            command_tag,
            (unsigned)packet->payload_len
        );
        return 1;
    }

    if ((packet->packet_type & SG_PACKET_TYPE_REPLY) != 0) {
        sg_logf(
            "INFO",
            "PROTO",
            "client reply packet ignored req=%lld type=%lld cmd=%s payload=%u",
            packet->request_id,
            packet->packet_type,
            command_tag,
            (unsigned)packet->payload_len
        );
        return 1;
    }

    return -1;
}

static int sg_read_file_text(const char* path, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0 || path == NULL || path[0] == '\0') {
        return 0;
    }
    FILE* fp = fopen(path, "rb");
    if (fp == NULL) {
        return 0;
    }
    size_t n = fread(out, 1, out_cap - 1, fp);
    out[n] = '\0';
    fclose(fp);
    if (n == 0) {
        return 0;
    }
    return 1;
}

static void sg_strip_utf8_bom(char* text) {
    if (text == NULL) {
        return;
    }
    unsigned char* p = (unsigned char*)text;
    if (p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
        size_t len = strlen(text);
        if (len >= 3) {
            memmove(text, text + 3, len - 2);
        }
    }
}

static int sg_path_exists(const char* path) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    FILE* fp = fopen(path, "rb");
    if (fp == NULL) {
        return 0;
    }
    fclose(fp);
    return 1;
}

static const char* sg_trim_leading_whitespace(const char* text) {
    if (text == NULL) {
        return "";
    }
    const unsigned char* p = (const unsigned char*)text;
    if (p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
        p += 3;
    }
    while (*p != '\0' && isspace(*p)) {
        p += 1;
    }
    return (const char*)p;
}

static int sg_registry_json_is_empty(const char* json) {
    const char* p = sg_trim_leading_whitespace(json);
    if (*p == '\0') {
        return 1;
    }
    if (*p != '[') {
        return 0;
    }
    p += 1;
    p = sg_trim_leading_whitespace(p);
    if (*p != ']') {
        return 0;
    }
    p += 1;
    p = sg_trim_leading_whitespace(p);
    return *p == '\0';
}

static void sg_trim_trailing_whitespace(char* text) {
    if (text == NULL) {
        return;
    }
    size_t len = strlen(text);
    while (len > 0) {
        char ch = text[len - 1];
        if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
            text[len - 1] = '\0';
            len -= 1;
        } else {
            break;
        }
    }
}

static unsigned long sg_hash_text(const char* text) {
    const unsigned char* p = (const unsigned char*)(text == NULL ? "" : text);
    unsigned long h = 5381UL;
    while (*p != 0) {
        h = ((h << 5) + h) + (unsigned long)(*p);
        p += 1;
    }
    return h;
}

static int sg_str_ieq(const char* a, const char* b) {
    if (a == NULL || b == NULL) {
        return 0;
    }
#ifdef _WIN32
    return _stricmp(a, b) == 0;
#else
    return strcasecmp(a, b) == 0;
#endif
}

static int sg_extension_bootstrap_enabled(void) {
    const char* raw = getenv("SENGOO_EXTENSION_BOOTSTRAP");
    if (raw == NULL || raw[0] == '\0') {
        return 1;
    }
    if (sg_str_ieq(raw, "0") || sg_str_ieq(raw, "false") || sg_str_ieq(raw, "off") || sg_str_ieq(raw, "no")) {
        return 0;
    }
    return 1;
}

static int sg_extension_sync_refresh_interval_ms(void) {
    const char* raw = getenv("SENGOO_EXTENSION_REFRESH_MS");
    if (raw == NULL || raw[0] == '\0') {
        return 3000;
    }
    char* end = NULL;
    long value = strtol(raw, &end, 10);
    if (end == raw || *end != '\0' || value <= 0) {
        return 3000;
    }
    if (value < 200) {
        value = 200;
    } else if (value > 600000) {
        value = 600000;
    }
    return (int)value;
}

static const char* sg_default_core_entry_path(char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return "";
    }
    const char* env_path = getenv("SENGOO_EXTENSION_CORE_ENTRY");
    if (env_path != NULL && env_path[0] != '\0') {
        snprintf(out, out_cap, "%s", env_path);
        return out;
    }

    const char* nested = "packages/packages/freekill-core/lua/server/rpc/entry.lua";
    const char* root = "packages/freekill-core/lua/server/rpc/entry.lua";
    if (sg_path_exists(nested)) {
        snprintf(out, out_cap, "%s", nested);
    } else {
        snprintf(out, out_cap, "%s", root);
    }
    return out;
}

static const char* sg_extension_bootstrap_lua_exe(void) {
    const char* raw = getenv("SENGOO_LUA_EXE");
    if (raw == NULL || raw[0] == '\0') {
        return "lua5.4";
    }
    return raw;
}

static int sg_extension_bootstrap_check_lua_runtime(void) {
    if (g_extension_bootstrap_lua_checked) {
        return g_extension_bootstrap_lua_available;
    }
    g_extension_bootstrap_lua_checked = 1;
    g_extension_bootstrap_lua_available = 0;

    const char* lua_exe = sg_extension_bootstrap_lua_exe();
    if (lua_exe == NULL || lua_exe[0] == '\0') {
        return 0;
    }

    if (strchr(lua_exe, '\\') != NULL || strchr(lua_exe, '/') != NULL || strchr(lua_exe, ':') != NULL) {
        g_extension_bootstrap_lua_available = sg_path_exists(lua_exe);
    } else {
        char check_cmd[SG_EXTENSION_CMD_MAX];
#ifdef _WIN32
        int check_len = snprintf(check_cmd, sizeof(check_cmd), "where %s >nul 2>&1", lua_exe);
#else
        int check_len = snprintf(check_cmd, sizeof(check_cmd), "command -v %s >/dev/null 2>&1", lua_exe);
#endif
        if (check_len > 0 && check_len < (int)sizeof(check_cmd)) {
            int check_rc = system(check_cmd);
            g_extension_bootstrap_lua_available = (check_rc == 0);
        }
    }

    if (!g_extension_bootstrap_lua_available && !g_extension_bootstrap_lua_missing_logged) {
        g_extension_bootstrap_lua_missing_logged = 1;
        sg_logf("WARN", "EXT", "lua runtime unavailable exe=%s", lua_exe);
    }
    return g_extension_bootstrap_lua_available;
}

static int sg_ensure_runtime_tmp_dirs(void) {
    if (sg_mkdir(".tmp") != 0 && errno != EEXIST) {
        return 0;
    }
    if (sg_mkdir(".tmp/runtime_host") != 0 && errno != EEXIST) {
        return 0;
    }
    return 1;
}

static const char* sg_find_substr_in_range(const char* begin, const char* end, const char* needle) {
    if (begin == NULL || end == NULL || needle == NULL) {
        return NULL;
    }
    size_t needle_len = strlen(needle);
    if (needle_len == 0 || begin >= end) {
        return NULL;
    }
    const char* p = begin;
    while (p + needle_len <= end) {
        if (memcmp(p, needle, needle_len) == 0) {
            return p;
        }
        p += 1;
    }
    return NULL;
}

static int sg_extract_json_string_field(
    const char* obj_begin,
    const char* obj_end,
    const char* field_name,
    char* out,
    size_t out_cap
) {
    if (obj_begin == NULL || obj_end == NULL || field_name == NULL || out == NULL || out_cap == 0 || obj_begin >= obj_end) {
        return 0;
    }
    out[0] = '\0';

    char key_pattern[128];
    int key_len = snprintf(key_pattern, sizeof(key_pattern), "\"%s\"", field_name);
    if (key_len <= 0 || key_len >= (int)sizeof(key_pattern)) {
        return 0;
    }

    const char* key = sg_find_substr_in_range(obj_begin, obj_end, key_pattern);
    if (key == NULL) {
        return 0;
    }
    const char* p = key + key_len;
    while (p < obj_end && isspace((unsigned char)*p)) {
        p += 1;
    }
    if (p >= obj_end || *p != ':') {
        return 0;
    }
    p += 1;
    while (p < obj_end && isspace((unsigned char)*p)) {
        p += 1;
    }
    if (p >= obj_end || *p != '"') {
        return 0;
    }
    p += 1;

    size_t out_len = 0;
    int escaped = 0;
    while (p < obj_end) {
        char ch = *p;
        if (!escaped) {
            if (ch == '\\') {
                escaped = 1;
            } else if (ch == '"') {
                out[out_len] = '\0';
                return 1;
            } else {
                if (out_len + 1 < out_cap) {
                    out[out_len++] = ch;
                }
            }
        } else {
            char decoded = ch;
            if (ch == 'n') decoded = '\n';
            else if (ch == 'r') decoded = '\r';
            else if (ch == 't') decoded = '\t';
            else if (ch == '\\') decoded = '\\';
            else if (ch == '"') decoded = '"';
            else if (ch == '/') decoded = '/';
            if (out_len + 1 < out_cap) {
                out[out_len++] = decoded;
            }
            escaped = 0;
        }
        p += 1;
    }
    out[out_len] = '\0';
    return 0;
}

static int sg_extract_registry_json_from_sync_payload(char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }
    out[0] = '\0';
    if (g_extension_sync_payload[0] == '\0') {
        return 0;
    }

    const char* marker = "\"registry\":";
    const char* p = strstr(g_extension_sync_payload, marker);
    if (p == NULL) {
        return 0;
    }
    p += strlen(marker);
    while (*p != '\0' && isspace((unsigned char)*p)) {
        p += 1;
    }
    if (*p != '[') {
        return 0;
    }

    const char* start = p;
    int depth = 0;
    int in_string = 0;
    int escaped = 0;
    while (*p != '\0') {
        char ch = *p;
        if (in_string) {
            if (escaped) {
                escaped = 0;
            } else if (ch == '\\') {
                escaped = 1;
            } else if (ch == '"') {
                in_string = 0;
            }
        } else {
            if (ch == '"') {
                in_string = 1;
            } else if (ch == '[') {
                depth += 1;
            } else if (ch == ']') {
                depth -= 1;
                if (depth == 0) {
                    size_t len = (size_t)(p - start + 1);
                    if (len >= out_cap) {
                        len = out_cap - 1;
                    }
                    memcpy(out, start, len);
                    out[len] = '\0';
                    return 1;
                }
                if (depth < 0) {
                    break;
                }
            }
        }
        p += 1;
    }

    return 0;
}

static int sg_json_object_is_enabled(const char* obj_begin, const char* obj_end) {
    if (obj_begin == NULL || obj_end == NULL || obj_begin >= obj_end) {
        return 1;
    }
    const char* key = sg_find_substr_in_range(obj_begin, obj_end, "\"enabled\"");
    if (key == NULL) {
        return 1;
    }
    const char* p = key + strlen("\"enabled\"");
    while (p < obj_end && isspace((unsigned char)*p)) {
        p += 1;
    }
    if (p >= obj_end || *p != ':') {
        return 1;
    }
    p += 1;
    while (p < obj_end && isspace((unsigned char)*p)) {
        p += 1;
    }
    if (p + 5 <= obj_end && memcmp(p, "false", 5) == 0) {
        return 0;
    }
    return 1;
}

static size_t sg_build_update_package_summary(unsigned char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }

    typedef struct {
        char name[SG_EXTENSION_NAME_MAX];
        char hash[SG_EXTENSION_HASH_MAX];
        char url[SG_EXTENSION_ENTRY_MAX];
    } sg_update_summary_entry;

    sg_update_summary_entry entries[SG_EXTENSION_BOOTSTRAP_MAX];
    int entry_count = 0;

    char registry_json[SG_EXTENSION_SYNC_PAYLOAD_MAX];
    registry_json[0] = '\0';
    if (!sg_extract_registry_json_from_sync_payload(registry_json, sizeof(registry_json))) {
        out[0] = 0x80;
        return 1;
    }

    const char* cursor = registry_json;
    while (cursor != NULL && *cursor != '\0' && entry_count < SG_EXTENSION_BOOTSTRAP_MAX) {
        const char* obj_begin = strchr(cursor, '{');
        if (obj_begin == NULL) {
            break;
        }
        const char* obj_end = strchr(obj_begin, '}');
        if (obj_end == NULL) {
            break;
        }

        if (!sg_json_object_is_enabled(obj_begin, obj_end + 1)) {
            cursor = obj_end + 1;
            continue;
        }

        char name[SG_EXTENSION_NAME_MAX];
        char hash[SG_EXTENSION_HASH_MAX];
        char url[SG_EXTENSION_ENTRY_MAX];
        name[0] = '\0';
        hash[0] = '\0';
        url[0] = '\0';

        int has_name = sg_extract_json_string_field(obj_begin, obj_end + 1, "name", name, sizeof(name));
        (void)sg_extract_json_string_field(obj_begin, obj_end + 1, "hash", hash, sizeof(hash));
        if (!sg_extract_json_string_field(obj_begin, obj_end + 1, "url", url, sizeof(url))) {
            (void)sg_extract_json_string_field(obj_begin, obj_end + 1, "entry", url, sizeof(url));
        }

        if (has_name && name[0] != '\0') {
            sg_update_summary_entry* item = &entries[entry_count];
            snprintf(item->name, sizeof(item->name), "%s", name);
            snprintf(item->hash, sizeof(item->hash), "%s", hash);
            snprintf(item->url, sizeof(item->url), "%s", url);
            entry_count += 1;
        }

        cursor = obj_end + 1;
    }

    size_t idx = 0;
    int ok = 1;
    ok = ok && sg_cbor_write_type_and_len(out, out_cap, &idx, 4, (unsigned long long)entry_count);
    for (int i = 0; i < entry_count && ok; i++) {
        sg_update_summary_entry* item = &entries[i];
        ok = ok && sg_cbor_write_type_and_len(out, out_cap, &idx, 5, 3);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)"name", 4);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)item->name, strlen(item->name));
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)"hash", 4);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)item->hash, strlen(item->hash));
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)"url", 3);
        ok = ok && sg_cbor_write_bytes_like(out, out_cap, &idx, 3, (const unsigned char*)item->url, strlen(item->url));
    }

    if (!ok || idx == 0) {
        out[0] = 0x80;
        return 1;
    }
    return idx;
}

static void sg_sanitize_filename_token(const char* input, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return;
    }
    out[0] = '\0';
    if (input == NULL || input[0] == '\0') {
        snprintf(out, out_cap, "unknown");
        return;
    }
    size_t j = 0;
    for (size_t i = 0; input[i] != '\0' && j + 1 < out_cap; i++) {
        unsigned char c = (unsigned char)input[i];
        if (isalnum(c) || c == '-' || c == '_') {
            out[j++] = (char)c;
        } else {
            out[j++] = '_';
        }
    }
    out[j] = '\0';
    if (j == 0) {
        snprintf(out, out_cap, "unknown");
    }
}

static int sg_write_text_file(const char* path, const char* content) {
    if (path == NULL || content == NULL) {
        return 0;
    }
    FILE* fp = fopen(path, "wb");
    if (fp == NULL) {
        return 0;
    }
    size_t n = fwrite(content, 1, strlen(content), fp);
    fclose(fp);
    return n == strlen(content);
}

static int sg_run_command_capture(const char* command, char* output, size_t output_cap) {
    if (command == NULL || command[0] == '\0' || output == NULL || output_cap == 0) {
        return -1;
    }
    output[0] = '\0';
    FILE* pipe = sg_popen(command, "r");
    if (pipe == NULL) {
        return -1;
    }
    size_t used = 0;
    char chunk[256];
    while (fgets(chunk, (int)sizeof(chunk), pipe) != NULL) {
        size_t chunk_len = strlen(chunk);
        if (used + chunk_len + 1 < output_cap) {
            memcpy(output + used, chunk, chunk_len);
            used += chunk_len;
            output[used] = '\0';
        }
    }
    int exit_code = sg_pclose(pipe);
    sg_trim_trailing_whitespace(output);
    return exit_code;
}

static int sg_find_extension_bootstrap_slot(const char* name, int* found_existing) {
    int first_free = -1;
    if (found_existing != NULL) {
        *found_existing = 0;
    }
    for (int i = 0; i < SG_EXTENSION_BOOTSTRAP_MAX; i++) {
        if (!g_extension_bootstrap_entries[i].used) {
            if (first_free < 0) {
                first_free = i;
            }
            continue;
        }
        if (strcmp(g_extension_bootstrap_entries[i].name, name) == 0) {
            if (found_existing != NULL) {
                *found_existing = 1;
            }
            return i;
        }
    }
    return first_free;
}

static int sg_bootstrap_extension(const char* name, const char* entry_path, const char* hash) {
    const char* lua_exe = sg_extension_bootstrap_lua_exe();
    if (!sg_extension_bootstrap_check_lua_runtime()) {
        return 0;
    }
    if (!sg_ensure_runtime_tmp_dirs()) {
        sg_logf("WARN", "EXT", "extension bootstrap skipped mkdir failed");
        return 0;
    }

    char safe_name[SG_EXTENSION_NAME_MAX];
    sg_sanitize_filename_token(name, safe_name, sizeof(safe_name));

    char script_path[SG_EXTENSION_SCRIPT_MAX];
    snprintf(script_path, sizeof(script_path), ".tmp/runtime_host/ext_bootstrap_%s.lua", safe_name);

    char lua_script[SG_EXTENSION_SCRIPT_MAX];
    int script_len = snprintf(
        lua_script,
        sizeof(lua_script),
        "local entry = [=[%s]=]\n"
        "local ext_name = [=[%s]=]\n"
        "local function _sg_norm(p) return (string.gsub(p, '\\\\', '/')) end\n"
        "local function _sg_is_abs(p) return (string.match(p, '^%%a:[/\\\\]') ~= nil) or string.sub(p, 1, 1) == '/' end\n"
        "local function _sg_parent(p)\n"
        "  local n = _sg_norm(p)\n"
        "  local parent = string.match(n, '^(.*)/[^/]+$')\n"
        "  if parent == nil or parent == '' then return '.' end\n"
        "  return parent\n"
        "end\n"
        "local function _sg_root(p)\n"
        "  local n = _sg_norm(p)\n"
        "  local root = string.gsub(n, '/lua/server/rpc/entry%%.lua$', '')\n"
        "  if root ~= n then return root end\n"
        "  root = string.gsub(n, '/lua/init%%.lua$', '')\n"
        "  if root ~= n then return root end\n"
        "  return _sg_parent(n)\n"
        "end\n"
        "local package_root = _sg_root(entry)\n"
        "local function _sg_join(root, rel)\n"
        "  if string.sub(root, -1) == '/' then return root .. rel end\n"
        "  return root .. '/' .. rel\n"
        "end\n"
        "local _orig_dofile = dofile\n"
        "dofile = function(path)\n"
        "  if type(path) == 'string' and path ~= '' and not _sg_is_abs(path) then\n"
        "    return _orig_dofile(_sg_join(package_root, path))\n"
        "  end\n"
        "  return _orig_dofile(path)\n"
        "end\n"
        "package.path = package.path .. ';'\n"
        "  .. _sg_join(package_root, '?.lua') .. ';'\n"
        "  .. _sg_join(package_root, '?/init.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/lib/?.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/?.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/?/init.lua')\n"
        "local chunk, load_err = loadfile(entry)\n"
        "if type(chunk) ~= 'function' then io.stderr:write(tostring(load_err)); os.exit(21) end\n"
        "local ok, mod = pcall(chunk, 'sengoo_bootstrap')\n"
        "if not ok then io.stderr:write(tostring(mod)); os.exit(21) end\n"
        "local init_fn = nil\n"
        "if type(mod) == 'table' then init_fn = mod.on_server_start or mod.bootstrap or mod.init end\n"
        "if type(init_fn) == 'function' then\n"
        "  local call_ok, ret = pcall(init_fn)\n"
        "  if not call_ok then io.stderr:write(tostring(ret)); os.exit(22) end\n"
        "  if ret ~= nil then io.write(tostring(ret)) end\n"
        "end\n"
        "io.write('EXT_BOOTSTRAP_OK:' .. ext_name)\n",
        entry_path,
        name
    );
    if (script_len <= 0 || script_len >= (int)sizeof(lua_script)) {
        sg_logf("WARN", "EXT", "extension bootstrap script too large name=%s", name);
        return 0;
    }
    if (!sg_write_text_file(script_path, lua_script)) {
        sg_logf("WARN", "EXT", "extension bootstrap script write failed name=%s path=%s", name, script_path);
        return 0;
    }

    char command[SG_EXTENSION_CMD_MAX];
#ifdef _WIN32
    int command_len = snprintf(command, sizeof(command), "cmd /c \"\"%s\" \"%s\" 2>&1\"", lua_exe, script_path);
#else
    int command_len = snprintf(command, sizeof(command), "\"%s\" \"%s\" 2>&1", lua_exe, script_path);
#endif
    if (command_len <= 0 || command_len >= (int)sizeof(command)) {
        remove(script_path);
        sg_logf("WARN", "EXT", "extension bootstrap command too large name=%s", name);
        return 0;
    }

    char output[SG_EXTENSION_OUTPUT_MAX];
    int exit_code = sg_run_command_capture(command, output, sizeof(output));
    remove(script_path);

    if (exit_code != 0) {
        sg_logf(
            "WARN",
            "EXT",
            "extension bootstrap failed name=%s exit=%d hash=%s output=%s",
            name,
            exit_code,
            (hash == NULL ? "" : hash),
            (output[0] == '\0' ? "<empty>" : output)
        );
        return 0;
    }

    sg_logf(
        "INFO",
        "EXT",
        "extension bootstrap loaded name=%s hash=%s output=%s",
        name,
        (hash == NULL ? "" : hash),
        (output[0] == '\0' ? "<empty>" : output)
    );
    return 1;
}

static int sg_run_extension_hook_once(
    const char* name,
    const char* entry_path,
    const char* hash,
    const char* hook_name
) {
    if (name == NULL || name[0] == '\0' || entry_path == NULL || entry_path[0] == '\0' || hook_name == NULL || hook_name[0] == '\0') {
        return 0;
    }
    if (!sg_extension_bootstrap_check_lua_runtime()) {
        return 0;
    }
    if (!sg_ensure_runtime_tmp_dirs()) {
        return 0;
    }

    const char* lua_exe = sg_extension_bootstrap_lua_exe();
    char safe_name[SG_EXTENSION_NAME_MAX];
    char safe_hook[SG_EXTENSION_NAME_MAX];
    sg_sanitize_filename_token(name, safe_name, sizeof(safe_name));
    sg_sanitize_filename_token(hook_name, safe_hook, sizeof(safe_hook));

    char script_path[SG_EXTENSION_SCRIPT_MAX];
    snprintf(script_path, sizeof(script_path), ".tmp/runtime_host/ext_hook_%s_%s.lua", safe_name, safe_hook);

    char lua_script[SG_EXTENSION_SCRIPT_MAX];
    int script_len = snprintf(
        lua_script,
        sizeof(lua_script),
        "local entry = [=[%s]=]\n"
        "local ext_name = [=[%s]=]\n"
        "local hook_name = [=[%s]=]\n"
        "local function _sg_norm(p) return (string.gsub(p, '\\\\', '/')) end\n"
        "local function _sg_is_abs(p) return (string.match(p, '^%%a:[/\\\\]') ~= nil) or string.sub(p, 1, 1) == '/' end\n"
        "local function _sg_parent(p)\n"
        "  local n = _sg_norm(p)\n"
        "  local parent = string.match(n, '^(.*)/[^/]+$')\n"
        "  if parent == nil or parent == '' then return '.' end\n"
        "  return parent\n"
        "end\n"
        "local function _sg_root(p)\n"
        "  local n = _sg_norm(p)\n"
        "  local root = string.gsub(n, '/lua/server/rpc/entry%%.lua$', '')\n"
        "  if root ~= n then return root end\n"
        "  root = string.gsub(n, '/lua/init%%.lua$', '')\n"
        "  if root ~= n then return root end\n"
        "  return _sg_parent(n)\n"
        "end\n"
        "local package_root = _sg_root(entry)\n"
        "local function _sg_join(root, rel)\n"
        "  if string.sub(root, -1) == '/' then return root .. rel end\n"
        "  return root .. '/' .. rel\n"
        "end\n"
        "local _orig_dofile = dofile\n"
        "dofile = function(path)\n"
        "  if type(path) == 'string' and path ~= '' and not _sg_is_abs(path) then\n"
        "    return _orig_dofile(_sg_join(package_root, path))\n"
        "  end\n"
        "  return _orig_dofile(path)\n"
        "end\n"
        "package.path = package.path .. ';'\n"
        "  .. _sg_join(package_root, '?.lua') .. ';'\n"
        "  .. _sg_join(package_root, '?/init.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/lib/?.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/?.lua') .. ';'\n"
        "  .. _sg_join(package_root, 'lua/?/init.lua')\n"
        "local chunk, load_err = loadfile(entry)\n"
        "if type(chunk) ~= 'function' then io.stderr:write(tostring(load_err)); os.exit(31) end\n"
        "local ok, mod = pcall(chunk, 'sengoo_hook')\n"
        "if not ok then io.stderr:write(tostring(mod)); os.exit(31) end\n"
        "local hook_fn = nil\n"
        "if type(mod) == 'table' then hook_fn = mod[hook_name] end\n"
        "if type(hook_fn) ~= 'function' and type(_G[hook_name]) == 'function' then hook_fn = _G[hook_name] end\n"
        "if type(hook_fn) == 'function' then\n"
        "  local call_ok, ret = pcall(hook_fn)\n"
        "  if not call_ok then io.stderr:write(tostring(ret)); os.exit(32) end\n"
        "  if ret ~= nil then io.write(tostring(ret)) end\n"
        "  io.write(' EXT_HOOK_OK:' .. hook_name .. ':' .. ext_name)\n"
        "else\n"
        "  io.write('EXT_HOOK_SKIP:' .. hook_name .. ':' .. ext_name)\n"
        "end\n",
        entry_path,
        name,
        hook_name
    );
    if (script_len <= 0 || script_len >= (int)sizeof(lua_script)) {
        sg_logf("WARN", "EXT", "extension hook script too large name=%s hook=%s", name, hook_name);
        return 0;
    }
    if (!sg_write_text_file(script_path, lua_script)) {
        sg_logf("WARN", "EXT", "extension hook script write failed name=%s hook=%s path=%s", name, hook_name, script_path);
        return 0;
    }

    char command[SG_EXTENSION_CMD_MAX];
#ifdef _WIN32
    int command_len = snprintf(command, sizeof(command), "cmd /c \"\"%s\" \"%s\" 2>&1\"", lua_exe, script_path);
#else
    int command_len = snprintf(command, sizeof(command), "\"%s\" \"%s\" 2>&1", lua_exe, script_path);
#endif
    if (command_len <= 0 || command_len >= (int)sizeof(command)) {
        remove(script_path);
        sg_logf("WARN", "EXT", "extension hook command too large name=%s hook=%s", name, hook_name);
        return 0;
    }

    char output[SG_EXTENSION_OUTPUT_MAX];
    int exit_code = sg_run_command_capture(command, output, sizeof(output));
    remove(script_path);
    if (exit_code != 0) {
        sg_logf(
            "WARN",
            "EXT",
            "extension hook failed name=%s hook=%s exit=%d hash=%s output=%s",
            name,
            hook_name,
            exit_code,
            (hash == NULL ? "" : hash),
            (output[0] == '\0' ? "<empty>" : output)
        );
        return 0;
    }

    if (strstr(output, "EXT_HOOK_SKIP:") == output) {
        sg_logf("INFO", "EXT", "extension hook skipped name=%s hook=%s", name, hook_name);
    } else {
        sg_logf(
            "INFO",
            "EXT",
            "extension hook executed name=%s hook=%s hash=%s output=%s",
            name,
            hook_name,
            (hash == NULL ? "" : hash),
            (output[0] == '\0' ? "<empty>" : output)
        );
    }
    return 1;
}

static void sg_emit_extension_shutdown_hooks(void) {
    if (g_extension_shutdown_hooks_emitted) {
        return;
    }
    g_extension_shutdown_hooks_emitted = 1;
    if (!sg_extension_bootstrap_enabled()) {
        return;
    }

    int discovered = 0;
    int executed = 0;
    for (int i = 0; i < SG_EXTENSION_BOOTSTRAP_MAX; i++) {
        sg_extension_bootstrap_entry* item = &g_extension_bootstrap_entries[i];
        if (!item->used || !item->loaded || item->entry[0] == '\0') {
            continue;
        }
        discovered += 1;
        if (sg_run_extension_hook_once(item->name, item->entry, item->hash, "on_server_stop")) {
            executed += 1;
        }
    }

    if (discovered > 0) {
        sg_logf("INFO", "EXT", "extension shutdown hook summary discovered=%d executed=%d", discovered, executed);
    }
}

static void sg_sync_extension_bootstrap(const char* registry_json) {
    if (!sg_extension_bootstrap_enabled() || registry_json == NULL || registry_json[0] == '\0') {
        return;
    }

    g_extension_bootstrap_generation += 1;
    if (g_extension_bootstrap_generation == 0) {
        g_extension_bootstrap_generation = 1;
    }
    unsigned int generation = g_extension_bootstrap_generation;

    int discovered_count = 0;
    int loaded_count = 0;
    int reload_count = 0;
    int changed_any = 0;

    const char* cursor = registry_json;
    while (cursor != NULL && *cursor != '\0') {
        const char* obj_begin = strchr(cursor, '{');
        if (obj_begin == NULL) {
            break;
        }
        const char* obj_end = strchr(obj_begin, '}');
        if (obj_end == NULL) {
            break;
        }

        char name[SG_EXTENSION_NAME_MAX];
        char entry[SG_EXTENSION_ENTRY_MAX];
        char hash[SG_EXTENSION_HASH_MAX];
        name[0] = '\0';
        entry[0] = '\0';
        hash[0] = '\0';

        int has_name = sg_extract_json_string_field(obj_begin, obj_end + 1, "name", name, sizeof(name));
        (void)sg_extract_json_string_field(obj_begin, obj_end + 1, "entry", entry, sizeof(entry));
        (void)sg_extract_json_string_field(obj_begin, obj_end + 1, "hash", hash, sizeof(hash));

        if (has_name && entry[0] == '\0' && strcmp(name, "freekill-core") == 0) {
            char core_entry_buf[SG_EXTENSION_ENTRY_MAX];
            const char* core_entry = sg_default_core_entry_path(core_entry_buf, sizeof(core_entry_buf));
            snprintf(entry, sizeof(entry), "%s", core_entry);
        }

        if (has_name && entry[0] != '\0') {
            discovered_count += 1;
            int found_existing = 0;
            int slot = sg_find_extension_bootstrap_slot(name, &found_existing);
            if (slot >= 0) {
                sg_extension_bootstrap_entry* item = &g_extension_bootstrap_entries[slot];
                int changed = (!found_existing)
                    || strcmp(item->entry, entry) != 0
                    || strcmp(item->hash, hash) != 0
                    || !item->loaded;

                if (!found_existing) {
                    memset(item, 0, sizeof(*item));
                    item->used = 1;
                    snprintf(item->name, sizeof(item->name), "%s", name);
                }

                if (changed) {
                    changed_any = 1;
                    if (item->loaded) {
                        reload_count += 1;
                    }
                    item->loaded = sg_bootstrap_extension(name, entry, hash);
                    item->last_exit_code = (item->loaded ? 0 : 1);
                    snprintf(item->entry, sizeof(item->entry), "%s", entry);
                    snprintf(item->hash, sizeof(item->hash), "%s", hash);
                }
                item->generation = generation;
                if (item->loaded) {
                    loaded_count += 1;
                }
            }
        }

        cursor = obj_end + 1;
    }

    for (int i = 0; i < SG_EXTENSION_BOOTSTRAP_MAX; i++) {
        sg_extension_bootstrap_entry* item = &g_extension_bootstrap_entries[i];
        if (!item->used) {
            continue;
        }
        if (item->generation != generation) {
            if (item->loaded) {
                sg_logf("INFO", "EXT", "extension bootstrap unloaded name=%s", item->name);
            }
            changed_any = 1;
            memset(item, 0, sizeof(*item));
        }
    }

    if ((discovered_count > 0 && (changed_any || !g_extension_bootstrap_synced_once)) || (changed_any && discovered_count == 0)) {
        sg_logf(
            "INFO",
            "EXT",
            "extension bootstrap sync discovered=%d loaded=%d reloaded=%d",
            discovered_count,
            loaded_count,
            reload_count
        );
    }
    g_extension_bootstrap_synced_once = 1;
}

static void sg_fill_registry_fallback(char* registry_json, size_t cap) {
    char core_entry_buf[SG_EXTENSION_ENTRY_MAX];
    const char* core_entry_path = sg_default_core_entry_path(core_entry_buf, sizeof(core_entry_buf));
    if (sg_path_exists(core_entry_path)) {
        snprintf(registry_json, cap, "%s", SG_DEFAULT_EXTENSION_REGISTRY_JSON);
        sg_logf("INFO", "EXT", "extension registry fallback=freekill-core source=%s", core_entry_path);
        return;
    }
    snprintf(registry_json, cap, "[]");
    sg_logf("WARN", "EXT", "extension registry fallback empty-list; core entry missing path=%s", core_entry_path);
}

static void sg_prepare_extension_sync_payload(void) {
    const char* registry_path = getenv("SENGOO_EXTENSION_REGISTRY");
    if (registry_path == NULL || registry_path[0] == '\0') {
        registry_path = "packages/packages.registry.json";
    }

    char registry_json[SG_EXTENSION_SYNC_PAYLOAD_MAX - 128];
    registry_json[0] = '\0';
    int read_ok = sg_read_file_text(registry_path, registry_json, sizeof(registry_json));
    if (!read_ok) {
        sg_logf("WARN", "EXT", "extension registry missing or unreadable path=%s", registry_path);
        sg_fill_registry_fallback(registry_json, sizeof(registry_json));
    }
    sg_strip_utf8_bom(registry_json);
    sg_trim_trailing_whitespace(registry_json);
    if (sg_registry_json_is_empty(registry_json)) {
        sg_fill_registry_fallback(registry_json, sizeof(registry_json));
    }
    sg_sync_extension_bootstrap(registry_json);

    int payload_len = snprintf(
        g_extension_sync_payload,
        sizeof(g_extension_sync_payload),
        "{\"event\":\"extension_sync\",\"registry\":%s}\n",
        registry_json
    );
    if (payload_len <= 0 || payload_len >= (int)sizeof(g_extension_sync_payload)) {
        snprintf(
            g_extension_sync_payload,
            sizeof(g_extension_sync_payload),
            "{\"event\":\"extension_sync\",\"registry\":[]}\n"
        );
        sg_logf("WARN", "EXT", "extension registry payload overflow; fallback to empty list");
    }

    unsigned long fingerprint = sg_hash_text(g_extension_sync_payload);
    if (fingerprint != g_extension_sync_payload_fingerprint) {
        g_extension_sync_payload_fingerprint = fingerprint;
        sg_logf("INFO", "EXT", "extension sync payload ready bytes=%u from=%s", (unsigned)strlen(g_extension_sync_payload), registry_path);
    }
}

static void sg_tick_extension_sync_refresh(void) {
    int interval_ms = sg_extension_sync_refresh_interval_ms();
    long long now_ms = sg_monotonic_ms();
    if (g_extension_sync_refresh_last_ms > 0 && now_ms - g_extension_sync_refresh_last_ms < (long long)interval_ms) {
        return;
    }
    g_extension_sync_refresh_last_ms = now_ms;
    sg_prepare_extension_sync_payload();
}

static long long sg_send_extension_sync_payload(sg_socket_t conn) {
    sg_prepare_extension_sync_payload();
    const char* cursor = g_extension_sync_payload;
    size_t remaining = strlen(g_extension_sync_payload);
    size_t sent_total = 0;
    while (remaining > 0) {
        int sent = send(conn, cursor, (int)remaining, 0);
        if (sent <= 0) {
            int err = sg_last_socket_error();
            sg_logf(
                "WARN",
                "EXT",
                "extension sync send incomplete sent=%u remaining=%u err=%d",
                (unsigned)sent_total,
                (unsigned)remaining,
                err
            );
            return -1;
        }
        sent_total += (size_t)sent;
        cursor += sent;
        remaining -= (size_t)sent;
    }
    return (long long)sent_total;
}

static long long sg_next_handle(void) {
    g_next_handle += 1;
    if (g_next_handle <= 0) {
        g_next_handle = 1000001;
    }
    return g_next_handle;
}

#ifdef _WIN32
static int sg_net_init(void) {
    static volatile LONG initialized = 0;
    LONG prev = InterlockedCompareExchange(&initialized, 1, 0);
    if (prev == 0) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            InterlockedExchange(&initialized, 0);
            return 0;
        }
        g_net_init_logged = 0;
    }
    if (!g_net_init_logged) {
        sg_logf("INFO", "SERVER", "server is starting");
        sg_logf("INFO", "NET", "winsock initialized");
        g_net_init_logged = 1;
    }
    return 1;
}

static int sg_would_block(void) {
    int err = WSAGetLastError();
    return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
}
#else
static int sg_net_init(void) {
    if (!g_net_init_logged) {
        sg_logf("INFO", "SERVER", "server is starting");
        sg_logf("INFO", "NET", "posix network runtime initialized");
        g_net_init_logged = 1;
    }
    return 1;
}

static int sg_would_block(void) {
    return errno == EWOULDBLOCK || errno == EAGAIN;
}
#endif

static int sg_set_nonblocking(sg_socket_t s) {
#ifdef _WIN32
    u_long mode = 1;
    return ioctlsocket(s, FIONBIO, &mode) == 0;
#else
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0) {
        return 0;
    }
    return fcntl(s, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}

static int sg_port_valid(long long port) {
    return port >= 1 && port <= 65535;
}

static size_t sg_buffer_size(long long max_bytes) {
    if (max_bytes <= 0) {
        return 1024;
    }
    if (max_bytes > 65536) {
        return 65536;
    }
    return (size_t)max_bytes;
}

static int sg_store_socket(sg_socket_entry* table, sg_socket_t s, long long* out_handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!table[i].used) {
            long long h = sg_next_handle();
            table[i].used = 1;
            table[i].handle = h;
            table[i].socket = s;
            *out_handle = h;
            return 1;
        }
    }
    return 0;
}

static sg_socket_entry* sg_find_socket(sg_socket_entry* table, long long handle) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (table[i].used && table[i].handle == handle) {
            return &table[i];
        }
    }
    return NULL;
}

static int sg_remove_socket(sg_socket_entry* table, long long handle, int close_now) {
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (table[i].used && table[i].handle == handle) {
            sg_socket_t s = table[i].socket;
            table[i].used = 0;
            table[i].handle = 0;
            table[i].socket = SG_INVALID_SOCKET;
            if (close_now && s != SG_INVALID_SOCKET) {
                sg_close_socket(s);
            }
            return 1;
        }
    }
    return 0;
}

static int sg_count_active_tcp_connections(void) {
    int count = 0;
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (g_tcp_connections[i].used) {
            count += 1;
        }
    }
    return count;
}

static int sg_parse_positive_env_i32(const char* key, int fallback) {
    const char* raw = getenv(key);
    if (raw == NULL || raw[0] == '\0') {
        return fallback;
    }
    char* end = NULL;
    long value = strtol(raw, &end, 10);
    if (end == raw || *end != '\0' || value <= 0 || value > 2147483647L) {
        return fallback;
    }
    return (int)value;
}

static int sg_parse_port_env_i32(const char* key, int fallback) {
    const char* raw = getenv(key);
    if (raw == NULL || raw[0] == '\0') {
        return fallback;
    }
    char* end = NULL;
    long value = strtol(raw, &end, 10);
    if (end == raw || *end != '\0' || value < 1 || value > 65535) {
        return fallback;
    }
    return (int)value;
}

long long sengoo_runtime_tcp_port(void) {
    int port = sg_parse_port_env_i32("SENGOO_TCP_PORT", 9527);
    return (long long)port;
}

long long sengoo_runtime_udp_port(void) {
    int udp_port = sg_parse_port_env_i32("SENGOO_UDP_PORT", 9528);
    return (long long)udp_port;
}

long long sengoo_runtime_tick_sleep_ms(void) {
    int value = sg_parse_positive_env_i32("SENGOO_TICK_SLEEP_MS", 20);
    return (long long)value;
}

long long sengoo_runtime_busy_sleep_ms(void) {
    int value = sg_parse_positive_env_i32("SENGOO_BUSY_SLEEP_MS", 1);
    return (long long)value;
}

long long sengoo_runtime_max_packet_bytes(void) {
    int value = sg_parse_positive_env_i32("SENGOO_MAX_PACKET_BYTES", 65536);
    if (value < 256) {
        value = 256;
    } else if (value > 65536) {
        value = 65536;
    }
    return (long long)value;
}

long long sengoo_runtime_max_error_count(void) {
    int value = sg_parse_positive_env_i32("SENGOO_MAX_ERROR_COUNT", 200);
    return (long long)value;
}

long long sengoo_runtime_max_accept_per_tick(void) {
    int value = sg_parse_positive_env_i32("SENGOO_MAX_ACCEPT_PER_TICK", 16);
    if (value < 1) {
        value = 1;
    } else if (value > 128) {
        value = 128;
    }
    return (long long)value;
}

static int sg_runtime_server_capacity(void) {
    int value = sg_parse_positive_env_i32("SENGOO_SERVER_CAPACITY", 100);
    if (value < 1) {
        value = 1;
    } else if (value > SG_MAX_NET_HANDLES) {
        value = SG_MAX_NET_HANDLES;
    }
    return value;
}

static int sg_auth_signup_timeout_ms(void) {
    int value = sg_parse_positive_env_i32("SENGOO_AUTH_SIGNUP_TIMEOUT_MS", 180000);
    if (value < 1000) {
        value = 1000;
    } else if (value > 3600000) {
        value = 3600000;
    }
    return value;
}

static const char* sg_server_detail_version(void) {
    const char* raw = getenv("SENGOO_SERVER_VERSION");
    if (raw == NULL || raw[0] == '\0') {
        return "0.5.19+";
    }
    return raw;
}

static const char* sg_server_detail_icon_url(void) {
    const char* raw = getenv("SENGOO_SERVER_ICON_URL");
    if (raw == NULL) {
        return "";
    }
    return raw;
}

static const char* sg_server_detail_description(void) {
    const char* raw = getenv("SENGOO_SERVER_DESCRIPTION");
    if (raw == NULL) {
        return "";
    }
    return raw;
}

static size_t sg_json_escape_copy(const char* input, char* out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }
    const char* src = (input == NULL ? "" : input);
    size_t out_len = 0;
    for (size_t i = 0; src[i] != '\0' && out_len + 1 < out_cap; i++) {
        unsigned char ch = (unsigned char)src[i];
        const char* replacement = NULL;
        char unicode_seq[7];
        if (ch == '"') {
            replacement = "\\\"";
        } else if (ch == '\\') {
            replacement = "\\\\";
        } else if (ch == '\n') {
            replacement = "\\n";
        } else if (ch == '\r') {
            replacement = "\\r";
        } else if (ch == '\t') {
            replacement = "\\t";
        } else if (ch < 0x20) {
            snprintf(unicode_seq, sizeof(unicode_seq), "\\u%04x", (unsigned int)ch);
            replacement = unicode_seq;
        }

        if (replacement != NULL) {
            size_t rep_len = strlen(replacement);
            if (out_len + rep_len >= out_cap) {
                break;
            }
            memcpy(out + out_len, replacement, rep_len);
            out_len += rep_len;
        } else {
            out[out_len++] = (char)ch;
        }
    }
    out[out_len] = '\0';
    return out_len;
}

static int sg_build_udp_detail_response(const char* request, char* out, size_t out_cap) {
    if (request == NULL || out == NULL || out_cap == 0) {
        return 0;
    }
    if (strncmp(request, "fkGetDetail,", 12) != 0) {
        return 0;
    }

    const char* requested_tag = request + 12;
    char escaped_version[96];
    char escaped_icon[768];
    char escaped_description[768];
    char escaped_tag[768];
    sg_json_escape_copy(sg_server_detail_version(), escaped_version, sizeof(escaped_version));
    sg_json_escape_copy(sg_server_detail_icon_url(), escaped_icon, sizeof(escaped_icon));
    sg_json_escape_copy(sg_server_detail_description(), escaped_description, sizeof(escaped_description));
    sg_json_escape_copy(requested_tag, escaped_tag, sizeof(escaped_tag));

    int capacity = sg_parse_positive_env_i32("SENGOO_SERVER_CAPACITY", 100);
    int online = sg_count_active_tcp_connections();
    int written = snprintf(
        out,
        out_cap,
        "[\"%s\",\"%s\",\"%s\",%d,%d,\"%s\"]",
        escaped_version,
        escaped_icon,
        escaped_description,
        capacity,
        online,
        escaped_tag
    );
    return written > 0 && written < (int)out_cap;
}

long long sengoo_sleep_ms(long long ms) {
    if (ms < 0) {
        ms = 0;
    }
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    struct timespec req;
    req.tv_sec = (time_t)(ms / 1000);
    req.tv_nsec = (long)((ms % 1000) * 1000000L);
    nanosleep(&req, NULL);
#endif
    return 1;
}

long long sengoo_tcp_listener_bind(long long port) {
    if (!sg_port_valid(port)) {
        sg_logf("ERROR", "NET", "tcp bind rejected invalid port=%lld", port);
        return 0;
    }
    if (!sg_net_init()) {
        sg_logf("ERROR", "NET", "tcp bind failed network init error");
        return 0;
    }

    sg_socket_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == SG_INVALID_SOCKET) {
        sg_logf("ERROR", "NET", "tcp socket create failed err=%d", sg_last_socket_error());
        return 0;
    }

    int reuse = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, (int)sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);

    if (bind(s, (struct sockaddr*)&addr, (int)sizeof(addr)) != 0) {
        int err = sg_last_socket_error();
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "tcp bind failed port=%lld err=%d", port, err);
        return 0;
    }

    if (listen(s, 128) != 0) {
        int err = sg_last_socket_error();
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "tcp listen failed port=%lld err=%d", port, err);
        return 0;
    }

    if (!sg_set_nonblocking(s)) {
        int err = sg_last_socket_error();
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "tcp set nonblocking failed port=%lld err=%d", port, err);
        return 0;
    }

    long long handle = 0;
    if (!sg_store_socket(g_tcp_listeners, s, &handle)) {
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "tcp listener table full port=%lld", port);
        return 0;
    }
    sg_logf("INFO", "NET", "server is ready to listen on [0.0.0.0]:%lld", port);
    sg_logf("INFO", "NET", "tcp listener bound port=%lld handle=%lld", port, handle);
    return handle;
}

long long sengoo_tcp_listener_accept(long long listener_handle) {
    sg_socket_entry* listener = sg_find_socket(g_tcp_listeners, listener_handle);
    if (listener == NULL) {
        sg_logf("WARN", "NET", "tcp accept invalid listener handle=%lld", listener_handle);
        return -2;
    }

    struct sockaddr_in peer_addr;
#ifdef _WIN32
    int peer_len = (int)sizeof(peer_addr);
#else
    socklen_t peer_len = (socklen_t)sizeof(peer_addr);
#endif

    sg_socket_t conn = accept(listener->socket, (struct sockaddr*)&peer_addr, &peer_len);
    if (conn == SG_INVALID_SOCKET) {
        if (sg_would_block()) {
            return 0;
        }
        sg_logf("WARN", "NET", "tcp accept failed listener=%lld err=%d", listener_handle, sg_last_socket_error());
        return -3;
    }

    char peer_ip[64];
    peer_ip[0] = '\0';
#ifdef _WIN32
    InetNtopA(AF_INET, &peer_addr.sin_addr, peer_ip, (DWORD)sizeof(peer_ip));
#else
    inet_ntop(AF_INET, &peer_addr.sin_addr, peer_ip, sizeof(peer_ip));
#endif
    if (peer_ip[0] == '\0') {
        strcpy(peer_ip, "unknown");
    }

    if (sg_is_ip_banned(peer_ip)) {
        sg_send_errordlg_and_close(conn, "you have been banned!");
        sg_close_socket(conn);
        sg_logf("INFO", "AUTH", "connection refused by ip ban %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
        return 0;
    }
    if (sg_is_ip_temp_banned(peer_ip)) {
        sg_send_errordlg_and_close(conn, "you have been temporarily banned!");
        sg_close_socket(conn);
        sg_logf("INFO", "AUTH", "connection refused by temp ip ban %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
        return 0;
    }

    int capacity = sg_runtime_server_capacity();
    int active_count = sg_count_active_tcp_connections();
    if (active_count >= capacity) {
        sg_send_errordlg_and_close(conn, "server is full!");
        sg_close_socket(conn);
        sg_logf(
            "INFO",
            "AUTH",
            "connection refused by capacity %s:%d active=%d capacity=%d",
            peer_ip,
            (int)ntohs(peer_addr.sin_port),
            active_count,
            capacity
        );
        return 0;
    }

    long long sync_bytes = sg_send_extension_sync_payload(conn);
    if (sync_bytes > 0) {
        sg_logf("INFO", "EXT", "extension sync -> %s:%d bytes=%lld", peer_ip, (int)ntohs(peer_addr.sin_port), sync_bytes);
    } else {
        sg_logf("WARN", "EXT", "extension sync send failed -> %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
    }
    int network_delay_sent = 0;
    if (sg_should_send_network_delay()) {
        if (!sg_send_network_delay_test(conn)) {
            sg_logf("WARN", "AUTH", "network delay test send failed -> %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
        } else {
            sg_logf("INFO", "AUTH", "network delay test -> %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
            network_delay_sent = 1;
        }
    }

    if (!sg_set_nonblocking(conn)) {
        int err = sg_last_socket_error();
        sg_close_socket(conn);
        sg_logf("WARN", "NET", "tcp accept set nonblocking failed listener=%lld err=%d", listener_handle, err);
        return -4;
    }

    long long handle = 0;
    if (!sg_store_socket(g_tcp_connections, conn, &handle)) {
        sg_close_socket(conn);
        sg_logf("WARN", "NET", "tcp connection table full listener=%lld", listener_handle);
        return -5;
    }
    if (!sg_tcp_stream_attach(handle)) {
        sg_auth_state_detach(handle);
        sg_remove_socket(g_tcp_connections, handle, 1);
        sg_logf("WARN", "NET", "tcp stream table full listener=%lld conn=%lld", listener_handle, handle);
        return -6;
    }
    if (!sg_auth_state_attach(handle)) {
        sg_tcp_stream_detach(handle);
        sg_remove_socket(g_tcp_connections, handle, 1);
        sg_logf("WARN", "AUTH", "auth state table full listener=%lld conn=%lld", listener_handle, handle);
        return -7;
    }
    sg_auth_state* auth_state = sg_auth_state_find(handle);
    if (auth_state != NULL) {
        auth_state->network_delay_sent = network_delay_sent;
    }

    sg_logf(
        "INFO",
        "NET",
        "client %s:%d connected (conn=%lld listener=%lld)",
        peer_ip,
        (int)ntohs(peer_addr.sin_port),
        handle,
        listener_handle
    );

    return handle;
}

long long sengoo_tcp_connection_echo_once(long long conn_handle, long long max_bytes) {
    sg_socket_entry* conn = sg_find_socket(g_tcp_connections, conn_handle);
    if (conn == NULL) {
        sg_logf("WARN", "NET", "tcp echo invalid connection handle=%lld", conn_handle);
        return -2;
    }

    size_t cap = sg_buffer_size(max_bytes);
    char* buffer = (char*)malloc(cap);
    if (buffer == NULL) {
        return -6;
    }

    int n = recv(conn->socket, buffer, (int)cap, 0);
    if (n == 0) {
        free(buffer);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        sg_logf("INFO", "NET", "client disconnected (conn=%lld)", conn_handle);
        return -3;
    }
    if (n < 0) {
        if (sg_would_block()) {
            free(buffer);
            return 0;
        }
        int err = sg_last_socket_error();
        free(buffer);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        sg_logf("WARN", "NET", "tcp recv failed handle=%lld err=%d", conn_handle, err);
        return -5;
    }

    sg_tcp_stream_state* stream = sg_tcp_stream_find(conn_handle);
    if (stream == NULL && !sg_tcp_stream_attach(conn_handle)) {
        int sent_total = 0;
        while (sent_total < n) {
            int sent = send(conn->socket, buffer + sent_total, n - sent_total, 0);
            if (sent <= 0) {
                int err = sg_last_socket_error();
                free(buffer);
                sg_tcp_stream_detach(conn_handle);
                sg_auth_state_detach(conn_handle);
                sg_remove_socket(g_tcp_connections, conn_handle, 1);
                sg_logf("WARN", "NET", "tcp send failed handle=%lld err=%d", conn_handle, err);
                return -4;
            }
            sent_total += sent;
        }
        free(buffer);
        sg_logf("INFO", "NET", "tcp echo fallback handle=%lld bytes=%d", conn_handle, n);
        return (long long)n;
    }
    stream = sg_tcp_stream_find(conn_handle);
    if (stream == NULL) {
        free(buffer);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        return -6;
    }

    int stream_was_empty = (stream->len == 0);
    if (stream->len + (size_t)n > SG_TCP_STREAM_BUFFER_MAX) {
        if (!stream_was_empty) {
            free(buffer);
            sg_logf("WARN", "PROTO", "tcp stream overflow handle=%lld buffered=%u incoming=%d", conn_handle, (unsigned)stream->len, n);
            sg_tcp_stream_detach(conn_handle);
            sg_auth_state_detach(conn_handle);
            sg_remove_socket(g_tcp_connections, conn_handle, 1);
            return -5;
        }
        stream->len = 0;
    }
    memcpy(stream->data + stream->len, buffer, (size_t)n);
    stream->len += (size_t)n;

    int parsed_count = 0;
    int parse_status = 0;
    int close_requested = 0;
    while (stream->len > 0) {
        sg_cbor_wire_packet packet;
        size_t consumed = 0;
        int parse_rc = sg_cbor_parse_wire_packet(stream->data, stream->len, &packet, &consumed);
        if (parse_rc == 1) {
            if (consumed == 0 || consumed > stream->len) {
                parse_status = -1;
                break;
            }
            int handle_rc = sg_handle_cbor_wire_packet(conn_handle, conn->socket, &packet);
            if (handle_rc == -2) {
                close_requested = 1;
                parse_status = -2;
                break;
            }
            if (handle_rc <= 0) {
                parse_status = -1;
                break;
            }
            if (consumed < stream->len) {
                memmove(stream->data, stream->data + consumed, stream->len - consumed);
                stream->len -= consumed;
            } else {
                stream->len = 0;
            }
            parsed_count += 1;
            continue;
        }
        if (parse_rc == 0) {
            parse_status = 1;
            break;
        }
        parse_status = -1;
        break;
    }

    if (parsed_count > 0) {
        free(buffer);
        return (long long)n;
    }

    if (parse_status == 1) {
        free(buffer);
        return 0;
    }

    if (close_requested || parse_status == -2) {
        free(buffer);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        sg_logf("INFO", "AUTH", "connection closed by auth policy handle=%lld", conn_handle);
        return -5;
    }

    if (!stream_was_empty) {
        free(buffer);
        sg_logf("WARN", "PROTO", "tcp stream malformed frame handle=%lld", conn_handle);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        return -5;
    }

    stream->len = 0;
    if (!sg_send_all(conn->socket, (const unsigned char*)buffer, (size_t)n)) {
        int err = sg_last_socket_error();
        free(buffer);
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        sg_logf("WARN", "NET", "tcp send failed handle=%lld err=%d", conn_handle, err);
        return -4;
    }

    free(buffer);
    sg_logf("INFO", "NET", "tcp echo handle=%lld bytes=%d", conn_handle, n);
    return (long long)n;
}

static long long sg_close_expired_auth_connections(void) {
    long long now_ms = sg_monotonic_ms();
    int timeout_ms = sg_auth_signup_timeout_ms();
    long long closed = 0;

    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!g_tcp_connections[i].used) {
            continue;
        }
        long long handle = g_tcp_connections[i].handle;
        sg_auth_state* auth_state = sg_auth_state_find(handle);
        if (auth_state == NULL || auth_state->auth_passed) {
            continue;
        }
        if (auth_state->accepted_at_ms <= 0) {
            continue;
        }
        long long age_ms = now_ms - auth_state->accepted_at_ms;
        if (age_ms < (long long)timeout_ms) {
            continue;
        }

        sg_remove_socket(g_tcp_connections, handle, 1);
        sg_tcp_stream_detach(handle);
        sg_auth_state_detach(handle);
        closed += 1;

        sg_logf(
            "INFO",
            "AUTH",
            "signup timeout close conn=%lld age_ms=%lld timeout_ms=%d",
            handle,
            age_ms,
            timeout_ms
        );
    }

    return closed;
}

long long sengoo_tcp_runtime_step(long long listener_handle, long long max_bytes, long long max_accept_per_tick) {
    sg_socket_entry* listener = sg_find_socket(g_tcp_listeners, listener_handle);
    if (listener == NULL) {
        sg_logf("WARN", "NET", "tcp runtime step invalid listener handle=%lld", listener_handle);
        return -2;
    }
    (void)listener;
    sg_tick_extension_sync_refresh();

    long long accept_budget = max_accept_per_tick;
    if (accept_budget <= 0) {
        accept_budget = 1;
    } else if (accept_budget > 128) {
        accept_budget = 128;
    }

    long long progress_count = 0;
    for (long long i = 0; i < accept_budget; i++) {
        long long accept_rc = sengoo_tcp_listener_accept(listener_handle);
        if (accept_rc > 0) {
            progress_count += 1;
            continue;
        }
        if (accept_rc == 0) {
            break;
        }
        if (accept_rc == -2) {
            return -2;
        }
        break;
    }

    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!g_tcp_connections[i].used) {
            continue;
        }
        long long conn_handle = g_tcp_connections[i].handle;
        long long io_rc = sengoo_tcp_connection_echo_once(conn_handle, max_bytes);
        if (io_rc > 0) {
            progress_count += 1;
        } else if (io_rc == -3 || io_rc == -4 || io_rc == -5 || io_rc == -6) {
            progress_count += 1;
        }
    }

    long long timeout_closed = sg_close_expired_auth_connections();
    if (timeout_closed > 0) {
        progress_count += timeout_closed;
    }

    return progress_count;
}

long long sengoo_tcp_connection_close_all(void) {
    sg_emit_extension_shutdown_hooks();
    long long closed = 0;
    for (int i = 0; i < SG_MAX_NET_HANDLES; i++) {
        if (!g_tcp_connections[i].used) {
            continue;
        }
        long long handle = g_tcp_connections[i].handle;
        if (sg_remove_socket(g_tcp_connections, handle, 1)) {
            sg_tcp_stream_detach(handle);
            sg_auth_state_detach(handle);
            closed += 1;
        }
    }
    sg_logf("INFO", "NET", "tcp close-all closed=%lld", closed);
    return closed;
}

long long sengoo_tcp_connection_close(long long conn_handle) {
    int ok = sg_remove_socket(g_tcp_connections, conn_handle, 1) ? 1 : 0;
    if (ok) {
        sg_tcp_stream_detach(conn_handle);
        sg_auth_state_detach(conn_handle);
        sg_logf("INFO", "NET", "tcp connection closed handle=%lld", conn_handle);
    } else {
        sg_logf("INFO", "NET", "tcp connection already closed handle=%lld", conn_handle);
    }
    return ok;
}

long long sengoo_tcp_listener_close(long long listener_handle) {
    int ok = sg_remove_socket(g_tcp_listeners, listener_handle, 1) ? 1 : 0;
    if (ok) {
        sg_logf("INFO", "NET", "tcp listener closed handle=%lld", listener_handle);
    } else {
        sg_logf("WARN", "NET", "tcp listener close miss handle=%lld", listener_handle);
    }
    return ok;
}

long long sengoo_udp_socket_bind(long long port) {
    if (!sg_port_valid(port)) {
        sg_logf("ERROR", "NET", "udp bind rejected invalid port=%lld", port);
        return 0;
    }
    if (!sg_net_init()) {
        sg_logf("ERROR", "NET", "udp bind failed network init error");
        return 0;
    }

    sg_socket_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == SG_INVALID_SOCKET) {
        sg_logf("ERROR", "NET", "udp socket create failed err=%d", sg_last_socket_error());
        return 0;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);

    if (bind(s, (struct sockaddr*)&addr, (int)sizeof(addr)) != 0) {
        int err = sg_last_socket_error();
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "udp bind failed port=%lld err=%d", port, err);
        return 0;
    }

    if (!sg_set_nonblocking(s)) {
        int err = sg_last_socket_error();
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "udp set nonblocking failed port=%lld err=%d", port, err);
        return 0;
    }

    long long handle = 0;
    if (!sg_store_socket(g_udp_sockets, s, &handle)) {
        sg_close_socket(s);
        sg_logf("ERROR", "NET", "udp socket table full port=%lld", port);
        return 0;
    }

    sg_logf("INFO", "NET", "udp is ready to listen on [0.0.0.0]:%lld", port);
    sg_logf("INFO", "NET", "udp socket bound port=%lld handle=%lld", port, handle);
    return handle;
}

long long sengoo_udp_socket_echo_once(long long socket_handle, long long max_bytes) {
    sg_socket_entry* sock = sg_find_socket(g_udp_sockets, socket_handle);
    if (sock == NULL) {
        sg_logf("WARN", "NET", "udp echo invalid socket handle=%lld", socket_handle);
        return -2;
    }

    size_t cap = sg_buffer_size(max_bytes);
    char* buffer = (char*)malloc(cap + 1);
    if (buffer == NULL) {
        return -5;
    }

    struct sockaddr_in peer_addr;
#ifdef _WIN32
    int peer_len = (int)sizeof(peer_addr);
#else
    socklen_t peer_len = (socklen_t)sizeof(peer_addr);
#endif

    int n = recvfrom(sock->socket, buffer, (int)cap, 0, (struct sockaddr*)&peer_addr, &peer_len);
    if (n < 0) {
        if (sg_would_block()) {
            free(buffer);
            return 0;
        }
        int err = sg_last_socket_error();
        free(buffer);
        sg_logf("WARN", "NET", "udp recv failed handle=%lld err=%d", socket_handle, err);
        return -4;
    }

    buffer[n] = '\0';
    int sent = 0;
    if (n == 14 && memcmp(buffer, "fkDetectServer", 14) == 0) {
        sent = sendto(sock->socket, "me", 2, 0, (struct sockaddr*)&peer_addr, peer_len);
        if (sent < 0) {
            int err = sg_last_socket_error();
            free(buffer);
            sg_logf("WARN", "NET", "udp detect reply failed handle=%lld err=%d", socket_handle, err);
            return -3;
        }
        free(buffer);
        sg_logf("INFO", "NET", "udp detect reply handle=%lld bytes=%d", socket_handle, sent);
        return (long long)sent;
    }

    char detail_json[2304];
    if (sg_build_udp_detail_response(buffer, detail_json, sizeof(detail_json))) {
        int detail_len = (int)strlen(detail_json);
        sent = sendto(sock->socket, detail_json, detail_len, 0, (struct sockaddr*)&peer_addr, peer_len);
        if (sent < 0) {
            int err = sg_last_socket_error();
            free(buffer);
            sg_logf("WARN", "NET", "udp detail reply failed handle=%lld err=%d", socket_handle, err);
            return -3;
        }
        free(buffer);
        sg_logf("INFO", "NET", "udp detail reply handle=%lld bytes=%d", socket_handle, sent);
        return (long long)sent;
    }

    sent = sendto(sock->socket, buffer, n, 0, (struct sockaddr*)&peer_addr, peer_len);
    free(buffer);
    if (sent < 0) {
        int err = sg_last_socket_error();
        sg_logf("WARN", "NET", "udp send failed handle=%lld err=%d", socket_handle, err);
        return -3;
    }
    sg_logf("INFO", "NET", "udp echo handle=%lld bytes=%d", socket_handle, n);
    return (long long)n;
}

long long sengoo_udp_socket_close(long long socket_handle) {
    int ok = sg_remove_socket(g_udp_sockets, socket_handle, 1) ? 1 : 0;
    if (ok) {
        sg_logf("INFO", "NET", "udp socket closed handle=%lld", socket_handle);
    } else {
        sg_logf("WARN", "NET", "udp socket close miss handle=%lld", socket_handle);
    }
    return ok;
}

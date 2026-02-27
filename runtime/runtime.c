#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <ctype.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET sg_socket_t;
#define SG_INVALID_SOCKET INVALID_SOCKET
#define sg_close_socket closesocket
#else
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
typedef int sg_socket_t;
#define SG_INVALID_SOCKET (-1)
#define sg_close_socket close
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

typedef struct {
    long long handle;
    sg_socket_t socket;
    int used;
} sg_socket_entry;

static sg_socket_entry g_tcp_listeners[SG_MAX_NET_HANDLES];
static sg_socket_entry g_tcp_connections[SG_MAX_NET_HANDLES];
static sg_socket_entry g_udp_sockets[SG_MAX_NET_HANDLES];
static long long g_next_handle = 1000000;
static int g_net_init_logged = 0;
static char g_extension_sync_payload[SG_EXTENSION_SYNC_PAYLOAD_MAX];
static int g_extension_sync_payload_ready = 0;

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

static void sg_fill_registry_fallback(char* registry_json, size_t cap) {
    const char* core_entry_path = getenv("SENGOO_EXTENSION_CORE_ENTRY");
    if (core_entry_path == NULL || core_entry_path[0] == '\0') {
        core_entry_path = "packages/freekill-core/lua/server/rpc/entry.lua";
    }
    if (sg_path_exists(core_entry_path)) {
        snprintf(registry_json, cap, "%s", SG_DEFAULT_EXTENSION_REGISTRY_JSON);
        sg_logf("INFO", "EXT", "extension registry fallback=freekill-core source=%s", core_entry_path);
        return;
    }
    snprintf(registry_json, cap, "[]");
    sg_logf("WARN", "EXT", "extension registry fallback empty-list; core entry missing path=%s", core_entry_path);
}

static void sg_prepare_extension_sync_payload(void) {
    if (g_extension_sync_payload_ready) {
        return;
    }
    g_extension_sync_payload_ready = 1;

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

    sg_logf(
        "INFO",
        "EXT",
        "prepared extension sync payload bytes=%u from=%s",
        (unsigned)strlen(g_extension_sync_payload),
        registry_path
    );
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

    long long sync_bytes = sg_send_extension_sync_payload(conn);
    if (sync_bytes > 0) {
        sg_logf("INFO", "EXT", "extension sync -> %s:%d bytes=%lld", peer_ip, (int)ntohs(peer_addr.sin_port), sync_bytes);
    } else {
        sg_logf("WARN", "EXT", "extension sync send failed -> %s:%d", peer_ip, (int)ntohs(peer_addr.sin_port));
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
        sg_remove_socket(g_tcp_connections, conn_handle, 1);
        sg_logf("WARN", "NET", "tcp recv failed handle=%lld err=%d", conn_handle, err);
        return -5;
    }

    int sent_total = 0;
    while (sent_total < n) {
        int sent = send(conn->socket, buffer + sent_total, n - sent_total, 0);
        if (sent <= 0) {
            int err = sg_last_socket_error();
            free(buffer);
            sg_remove_socket(g_tcp_connections, conn_handle, 1);
            sg_logf("WARN", "NET", "tcp send failed handle=%lld err=%d", conn_handle, err);
            return -4;
        }
        sent_total += sent;
    }

    free(buffer);
    sg_logf("INFO", "NET", "tcp echo handle=%lld bytes=%d", conn_handle, n);
    return (long long)n;
}

long long sengoo_tcp_connection_close(long long conn_handle) {
    int ok = sg_remove_socket(g_tcp_connections, conn_handle, 1) ? 1 : 0;
    if (ok) {
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
    char* buffer = (char*)malloc(cap);
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

    int sent = sendto(sock->socket, buffer, n, 0, (struct sockaddr*)&peer_addr, peer_len);
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

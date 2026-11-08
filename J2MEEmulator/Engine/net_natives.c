//
//  net_natives.c
//  JarBox Network Engine — TCP and UDP sockets for the Generic Connection Framework
//
//  POSIX sockets, driven from Java (org.jarbox.net). getaddrinfo with AF_UNSPEC
//  keeps connections working on IPv6-only mobile networks (iOS synthesizes
//  NAT64 addresses for IPv4 servers). Bytes are never altered: a game's
//  protocol stays exactly as written. Blocking calls mark the thread as
//  blocked so the garbage collector never waits for the network.
//

#include "jvm.h"
#include "jvm_util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__JVM_OS_MINGW__) || defined(__JVM_OS_VS__)
#include <winsock2.h>
#include <ws2tcpip.h>
#define CLOSE_SOCKET closesocket
#define SOCK_ERRNO WSAGetLastError()
#define IN_PROGRESS(e) ((e) == WSAEWOULDBLOCK || (e) == WSAEINPROGRESS)
#define WOULD_BLOCK(e) ((e) == WSAEWOULDBLOCK || (e) == WSAETIMEDOUT)
#define INTERRUPTED(e) ((e) == WSAEINTR)
#define POLL WSAPoll
typedef SOCKET sock_t;
#define HANDLE_INVALID INVALID_SOCKET
typedef int socklen_compat;
#else
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#define CLOSE_SOCKET close
#define SOCK_ERRNO errno
#define IN_PROGRESS(e) ((e) == EINPROGRESS)
#define WOULD_BLOCK(e) ((e) == EAGAIN || (e) == EWOULDBLOCK || (e) == ETIMEDOUT)
#define INTERRUPTED(e) ((e) == EINTR)
#define POLL poll
typedef int sock_t;
#define HANDLE_INVALID (-1)
typedef socklen_t socklen_compat;
#endif

#include "jvm_bridge_stop.h"

// Option identifiers shared with NetNative.java
enum { OPT_DELAY = 0, OPT_LINGER = 1, OPT_KEEPALIVE = 2, OPT_RCVBUF = 3, OPT_SNDBUF = 4, OPT_READ_TIMEOUT = 5 };

// Results shared with NetNative.java
enum { NET_EOF = -1, NET_TIMEOUT = -2, NET_ERROR = -3 };

static void set_blocking(sock_t s, int blocking) {
#if defined(__JVM_OS_MINGW__) || defined(__JVM_OS_VS__)
    u_long mode = blocking ? 0 : 1;
    ioctlsocket(s, FIONBIO, &mode);
#else
    int flags = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK));
#endif
}

static void configure_stream(sock_t s) {
#ifdef SO_NOSIGPIPE
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
    int keep = 1;
    setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char *)&keep, sizeof(keep));
#ifdef TCP_KEEPALIVE
    int idle = 60;
    setsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, (const char *)&idle, sizeof(idle));
#endif
}

static int jstring_to_cstr(Instance *jstr, char *out, size_t size, Runtime *runtime) {
    if (!jstr) return 0;
    Utf8String *u = utf8_create();
    jstring_2_utf8(jstr, u, runtime);
    snprintf(out, size, "%s", utf8_cstr(u));
    utf8_destroy(u);
    return 1;
}

/// Wait for one of the poll events; returns >0 ready, 0 timeout, <0 error or stop.
static int wait_socket(sock_t s, short events, int timeoutMs) {
    int waited = 0;
    for (;;) {
        struct pollfd pfd;
        pfd.fd = s;
        pfd.events = events;
        pfd.revents = 0;
        int slice = 200;
        if (timeoutMs >= 0 && timeoutMs - waited < slice) slice = timeoutMs - waited;
        int r = POLL(&pfd, 1, slice);
        if (r > 0) return r;
        if (r < 0 && !INTERRUPTED(SOCK_ERRNO)) return -1;
        if (jvm_bridge_is_stop_requested()) return -1;
        if (r == 0) {
            waited += slice;
            if (timeoutMs >= 0 && waited >= timeoutMs) return 0;
        }
    }
}

// tcpConnect(String host, int port, int timeoutMs) → handle, or a negative result
static s32 n_tcpConnect(Runtime *runtime, JClass *clazz) {
    char host[256], service[16];
    jstring_to_cstr(localvar_getRefer(runtime->localvar, 0), host, sizeof host, runtime);
    int port = localvar_getInt(runtime->localvar, 1), timeoutMs = localvar_getInt(runtime->localvar, 2);
    snprintf(service, sizeof service, "%d", port);

    jthread_block_enter(runtime);
    s64 result = NET_ERROR;
    struct addrinfo hints, *list = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
#ifdef AI_DEFAULT
    hints.ai_flags = AI_DEFAULT;
#endif
    if (getaddrinfo(host, service, &hints, &list) == 0) {
        for (struct addrinfo *a = list; a && result < 0; a = a->ai_next) {
            sock_t s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
            if (s == HANDLE_INVALID) continue;
            configure_stream(s);
            set_blocking(s, 0);
            int rc = connect(s, a->ai_addr, (socklen_compat)a->ai_addrlen);
            if (rc != 0 && IN_PROGRESS(SOCK_ERRNO)) {
                int ready = wait_socket(s, POLLOUT, timeoutMs);
                if (ready > 0) {
                    int err = 0;
                    socklen_compat len = sizeof err;
                    getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &len);
                    rc = err == 0 ? 0 : -1;
                } else {
                    rc = -1;
                    if (ready == 0) result = NET_TIMEOUT;
                }
            }
            if (rc == 0) {
                set_blocking(s, 1);
                result = (s64)s;
            } else {
                CLOSE_SOCKET(s);
            }
        }
        freeaddrinfo(list);
    }
    jthread_block_exit(runtime);
    push_long(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

static inline int array_range_ok(Instance *arr, int off, int len) {
    return arr && off >= 0 && len >= 0 && off <= arr->arr_length - len;
}

static s32 n_tcpRead(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    Instance *arr = localvar_getRefer(runtime->localvar, 2);
    int off = localvar_getInt(runtime->localvar, 3), len = localvar_getInt(runtime->localvar, 4);
    if (!array_range_ok(arr, off, len)) { push_int(runtime->stack, NET_ERROR); return RUNTIME_STATUS_NORMAL; }

    jthread_block_enter(runtime);
    int n;
    for (;;) {
        n = (int)recv(s, arr->arr_body + off, len, 0);
        if (n >= 0) break;
        int e = SOCK_ERRNO;
        if (INTERRUPTED(e)) continue;
        n = WOULD_BLOCK(e) ? NET_TIMEOUT : NET_ERROR;
        break;
    }
    jthread_block_exit(runtime);
    push_int(runtime->stack, n == 0 && len > 0 ? NET_EOF : n);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_tcpWrite(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    Instance *arr = localvar_getRefer(runtime->localvar, 2);
    int off = localvar_getInt(runtime->localvar, 3), len = localvar_getInt(runtime->localvar, 4);
    if (!array_range_ok(arr, off, len)) { push_int(runtime->stack, NET_ERROR); return RUNTIME_STATUS_NORMAL; }

    int flags = 0;
#ifdef MSG_NOSIGNAL
    flags = MSG_NOSIGNAL;
#endif
    jthread_block_enter(runtime);
    int total = 0;
    while (total < len) {
        int n = (int)send(s, arr->arr_body + off + total, len - total, flags);
        if (n < 0) {
            if (INTERRUPTED(SOCK_ERRNO)) continue;
            total = NET_ERROR;
            break;
        }
        total += n;
    }
    jthread_block_exit(runtime);
    push_int(runtime->stack, total);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_tcpAvailable(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
#if defined(__JVM_OS_MINGW__) || defined(__JVM_OS_VS__)
    u_long n = 0;
    int rc = ioctlsocket(s, FIONREAD, &n);
#else
    int n = 0;
    int rc = ioctl(s, FIONREAD, &n);
#endif
    push_int(runtime->stack, rc == 0 ? (s32)n : 0);
    return RUNTIME_STATUS_NORMAL;
}

/// Shuts the socket down first so a thread blocked in read wakes up at once.
static s32 n_close(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
#if defined(__JVM_OS_MINGW__) || defined(__JVM_OS_VS__)
    shutdown(s, SD_BOTH);
#else
    shutdown(s, SHUT_RDWR);
#endif
    CLOSE_SOCKET(s);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setOption(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    int opt = localvar_getInt(runtime->localvar, 2), value = localvar_getInt(runtime->localvar, 3);
    int rc = -1;
    switch (opt) {
        case OPT_DELAY: {
            int on = value ? 0 : 1;     // MIDP DELAY=0 means "send immediately"
            rc = setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&on, sizeof on);
            break;
        }
        case OPT_LINGER: {
            struct linger l;
            l.l_onoff = value > 0;
            l.l_linger = (unsigned short)value;
            rc = setsockopt(s, SOL_SOCKET, SO_LINGER, (const char *)&l, sizeof l);
            break;
        }
        case OPT_KEEPALIVE:
            rc = setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char *)&value, sizeof value);
            break;
        case OPT_RCVBUF:
            rc = setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&value, sizeof value);
            break;
        case OPT_SNDBUF:
            rc = setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&value, sizeof value);
            break;
        case OPT_READ_TIMEOUT: {
#if defined(__JVM_OS_MINGW__) || defined(__JVM_OS_VS__)
            DWORD ms = (DWORD)value;
            rc = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&ms, sizeof ms);
#else
            struct timeval tv;
            tv.tv_sec = value / 1000;
            tv.tv_usec = (value % 1000) * 1000;
            rc = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof tv);
#endif
            break;
        }
    }
    push_int(runtime->stack, rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getOption(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    int opt = localvar_getInt(runtime->localvar, 2);
    int value = -1;
    socklen_compat len = sizeof value;
    switch (opt) {
        case OPT_DELAY: {
            int nodelay = 0;
            if (getsockopt(s, IPPROTO_TCP, TCP_NODELAY, (char *)&nodelay, &len) == 0) value = nodelay ? 0 : 1;
            break;
        }
        case OPT_LINGER: {
            struct linger l;
            len = sizeof l;
            if (getsockopt(s, SOL_SOCKET, SO_LINGER, (char *)&l, &len) == 0) value = l.l_onoff ? l.l_linger : 0;
            break;
        }
        case OPT_KEEPALIVE: getsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (char *)&value, &len); break;
        case OPT_RCVBUF:    getsockopt(s, SOL_SOCKET, SO_RCVBUF, (char *)&value, &len); break;
        case OPT_SNDBUF:    getsockopt(s, SOL_SOCKET, SO_SNDBUF, (char *)&value, &len); break;
    }
    push_int(runtime->stack, value);
    return RUNTIME_STATUS_NORMAL;
}

/// Numeric address and port of the local (remote == 0) or remote end.
static void socket_endpoint(sock_t s, int remote, char *host, size_t hostSize, int *port) {
    struct sockaddr_storage ss;
    socklen_compat len = sizeof ss;
    host[0] = 0;
    *port = -1;
    int rc = remote ? getpeername(s, (struct sockaddr *)&ss, &len) : getsockname(s, (struct sockaddr *)&ss, &len);
    if (rc != 0) return;
    char service[16] = "";
    if (getnameinfo((struct sockaddr *)&ss, len, host, (socklen_compat)hostSize, service, sizeof service, NI_NUMERICHOST | NI_NUMERICSERV) == 0)
        *port = atoi(service);
}

static s32 n_address(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    int remote = localvar_getInt(runtime->localvar, 2);
    char host[128];
    int port;
    socket_endpoint(s, remote, host, sizeof host, &port);
    push_ref(runtime->stack, host[0] ? jstring_create_cstr(host, runtime) : NULL);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_port(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    int remote = localvar_getInt(runtime->localvar, 2);
    char host[128];
    int port;
    socket_endpoint(s, remote, host, sizeof host, &port);
    push_int(runtime->stack, port);
    return RUNTIME_STATUS_NORMAL;
}

// --- UDP ---------------------------------------------------------------------

static s32 n_udpOpen(Runtime *runtime, JClass *clazz) {
    int port = localvar_getInt(runtime->localvar, 0);
    sock_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    s64 result = NET_ERROR;
    if (s != HANDLE_INVALID) {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons((unsigned short)port);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, (struct sockaddr *)&addr, sizeof addr) == 0) result = (s64)s;
        else CLOSE_SOCKET(s);
    }
    push_long(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_udpSend(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    char host[256], service[16];
    jstring_to_cstr(localvar_getRefer(runtime->localvar, 2), host, sizeof host, runtime);
    int port = localvar_getInt(runtime->localvar, 3);
    Instance *arr = localvar_getRefer(runtime->localvar, 4);
    int off = localvar_getInt(runtime->localvar, 5), len = localvar_getInt(runtime->localvar, 6);
    snprintf(service, sizeof service, "%d", port);
    int result = NET_ERROR;
    if (array_range_ok(arr, off, len)) {
        jthread_block_enter(runtime);
        struct addrinfo hints, *list = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(host, service, &hints, &list) == 0) {
            int n = (int)sendto(s, arr->arr_body + off, len, 0, list->ai_addr, (socklen_compat)list->ai_addrlen);
            if (n >= 0) result = n;
            freeaddrinfo(list);
        }
        jthread_block_exit(runtime);
    }
    push_int(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

// udpReceive(handle, buffer, offset, length, int[2] port+address-out, byte[] addressText) → length
static s32 n_udpReceive(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    Instance *arr = localvar_getRefer(runtime->localvar, 2);
    int off = localvar_getInt(runtime->localvar, 3), len = localvar_getInt(runtime->localvar, 4);
    Instance *senderOut = localvar_getRefer(runtime->localvar, 5);
    int result = NET_ERROR;
    char sender[64] = "";
    if (array_range_ok(arr, off, len)) {
        jthread_block_enter(runtime);
        struct sockaddr_in from;
        socklen_compat fromLen = sizeof from;
        for (;;) {
            int n = (int)recvfrom(s, arr->arr_body + off, len, 0, (struct sockaddr *)&from, &fromLen);
            if (n >= 0) {
                result = n;
                snprintf(sender, sizeof sender, "%s:%d", inet_ntoa(from.sin_addr), ntohs(from.sin_port));
                break;
            }
            int e = SOCK_ERRNO;
            if (INTERRUPTED(e)) continue;
            result = WOULD_BLOCK(e) ? NET_TIMEOUT : NET_ERROR;
            break;
        }
        jthread_block_exit(runtime);
        if (senderOut && senderOut->arr_length > 0 && result >= 0) {
            jarray_set_field(senderOut, 0, (intptr_t)jstring_create_cstr(sender, runtime));
        }
    }
    push_int(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

// --- Server sockets -----------------------------------------------------------

static s32 n_serverOpen(Runtime *runtime, JClass *clazz) {
    int port = localvar_getInt(runtime->localvar, 0);
    sock_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    s64 result = NET_ERROR;
    if (s != HANDLE_INVALID) {
        int reuse = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof reuse);
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons((unsigned short)port);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(s, 8) == 0) result = (s64)s;
        else CLOSE_SOCKET(s);
    }
    push_long(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_serverAccept(Runtime *runtime, JClass *clazz) {
    sock_t s = (sock_t)localvar_getLong(runtime->localvar, 0);
    jthread_block_enter(runtime);
    s64 result = NET_ERROR;
    for (;;) {
        int ready = wait_socket(s, POLLIN, -1);
        if (ready <= 0) break;
        sock_t c = accept(s, NULL, NULL);
        if (c != HANDLE_INVALID) {
            configure_stream(c);
            result = (s64)c;
            break;
        }
        if (!INTERRUPTED(SOCK_ERRNO)) break;
    }
    jthread_block_exit(runtime);
    push_long(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

#define CLS "org/jarbox/net/NetNative"

static java_native_method net_methods[] = {
    {CLS, "tcpConnect",   "(Ljava/lang/String;II)J", n_tcpConnect},
    {CLS, "tcpRead",      "(J[BII)I",                n_tcpRead},
    {CLS, "tcpWrite",     "(J[BII)I",                n_tcpWrite},
    {CLS, "tcpAvailable", "(J)I",                    n_tcpAvailable},
    {CLS, "close",        "(J)V",                    n_close},
    {CLS, "setOption",    "(JII)I",                  n_setOption},
    {CLS, "getOption",    "(JI)I",                   n_getOption},
    {CLS, "address",      "(JI)Ljava/lang/String;",  n_address},
    {CLS, "port",         "(JI)I",                   n_port},
    {CLS, "udpOpen",      "(I)J",                    n_udpOpen},
    {CLS, "udpSend",      "(JLjava/lang/String;I[BII)I", n_udpSend},
    {CLS, "udpReceive",   "(J[BII[Ljava/lang/String;)I", n_udpReceive},
    {CLS, "serverOpen",   "(I)J",                    n_serverOpen},
    {CLS, "serverAccept", "(J)J",                    n_serverAccept},
};

#undef CLS

void net_natives_reg(MiniJVM *jvm) {
    native_reg_lib(jvm, net_methods, sizeof(net_methods) / sizeof(java_native_method));
}

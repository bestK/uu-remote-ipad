#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <arpa/inet.h>

static int read_all(int fd, void *buf, size_t len){ size_t d=0; while(d<len){ ssize_t n=read(fd,(char*)buf+d,len-d); if(n<=0) return 0; d+=n;} return 1; }
static int write_all(int fd, const void *buf, size_t len){ size_t d=0; while(d<len){ ssize_t n=write(fd,(const char*)buf+d,len-d); if(n<=0) return 0; d+=n;} return 1; }

int main(int argc, char **argv){
    if (argc < 3) { fprintf(stderr, "usage: %s <socket> <json>\n", argv[0]); return 2; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, argv[1], sizeof(addr.sun_path)-1);
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) { perror("connect"); return 1; }
    uint32_t len = htonl((uint32_t)strlen(argv[2]));
    write_all(fd, &len, 4); write_all(fd, argv[2], strlen(argv[2]));
    if (!read_all(fd, &len, 4)) { fprintf(stderr, "no response\n"); return 1; }
    len = ntohl(len);
    char *body = calloc(1, len+1);
    if (!read_all(fd, body, len)) { fprintf(stderr, "short response\n"); return 1; }
    printf("%s\n", body);
    if (strstr(body, "\"payload\":true")) {
        uint32_t m=0;
        if (read_all(fd, &m, 4)) {
            m = ntohl(m);
            void *data = malloc(m);
            if (read_all(fd, data, m)) {
                FILE *f = fopen("/tmp/uu_capture.jpg", "wb");
                if (f) { fwrite(data, 1, m, f); fclose(f); printf("saved /tmp/uu_capture.jpg %u bytes\n", m); }
            }
            free(data);
        }
    }
    close(fd);
    return 0;
}

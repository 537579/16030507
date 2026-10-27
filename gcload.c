/*
 * gcload.c - load generator and F2FS GC ioctl driver for the F2FS GC suite.
 *
 * Build for Android (arm64):  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang \
 *                               -O2 -static -o gcload gcload.c
 * Host syntax check:          gcc -Wall -Wextra -fsyntax-only gcload.c
 *
 * All commands print key=value lines on stdout so shell tests can grep them.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

/* F2FS ioctls (defined here so no kernel header dependency). */ 
#define F2FS_IOCTL_MAGIC 0xf5 
struct f2fs_gc_range {
    uint32_t sync;
    uint64_t start; /* block address */
    uint64_t len;   /* blocks */
};
#define F2FS_IOC_GARBAGE_COLLECT       _IOW(F2FS_IOCTL_MAGIC, 6, uint32_t)
#define F2FS_IOC_WRITE_CHECKPOINT      _IO(F2FS_IOCTL_MAGIC, 7)
#define F2FS_IOC_GARBAGE_COLLECT_RANGE _IOW(F2FS_IOCTL_MAGIC, 11, struct f2fs_gc_range)

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }

static uint64_t rng_s = 88172645463325252ull; static uint64_t rnd(void) {
    rng_s ^= rng_s << 13;
    rng_s ^= rng_s >> 7;
    rng_s ^= rng_s << 17;
    return rng_s;
}

static void set_seed(uint64_t s)
{
    rng_s ^= s * 0x9e3779b97f4a7c15ull;
    if (!rng_s)
        rng_s = 1;
    for (int i = 0; i < 16; i++)
        rnd();
}

static void die(const char *m)
{
    perror(m);
    exit(2);
}

static void usage(void)
{
    fprintf(stderr,
        "usage: gcload <cmd> ...\n"
        "  usedpct  <mnt>\n"
        "  fillto   <dir> <target_pct> <file_mb> <mnt> [max_mb]\n"
        "  delete   <dir> <pct> <seed>\n"
        "  churn    <dir> <secs> <io_kb> <fsync_every> <seed> [max_fds]\n"
        "  append   <dir> <total_mb> <chunk_kb> <fsync_every> <roll_mb>\n"
        "  gc       <path> <sync 0|1> <max_calls>\n"
        "  gcrange  <path> <start_blk> <len_blk> <sync 0|1>\n"
        "  ckpt     <path>\n");
    exit(1);
}

/* ---- latency collection ---- */
struct lat {
    uint32_t *v;
    size_t n, cap;
    uint32_t max;
};
static void lat_init(struct lat *l, size_t cap) {
    l->v = malloc(cap * sizeof(uint32_t));
    if (!l->v)
        die("malloc");
    l->n = 0;
    l->cap = cap;
    l->max = 0;
}

static void lat_add(struct lat *l, uint64_t ns) {
    uint64_t us = ns / 1000;
    if (us > 0xffffffffull)
        us = 0xffffffffull;
    if (us > l->max)
        l->max = (uint32_t)us;
    if (l->n < l->cap)
        l->v[l->n++] = (uint32_t)us;
}

static int cmp_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

static void lat_report(struct lat *l, const char *p) {
    if (!l->n) {
        printf("%s_n=0\n", p);
        return;
    }
    qsort(l->v, l->n, sizeof(uint32_t), cmp_u32);
    printf("%s_n=%zu\n%s_p50_us=%u\n%s_p99_us=%u\n%s_p999_us=%u\n%s_max_us=%u\n",
           p, l->n, p, l->v[l->n * 50 / 100], p, l->v[l->n * 99 / 100],
           p, l->v[l->n * 999 / 1000], p, l->max); 
}

static void fillbuf(char *b, size_t n)
{
    for (size_t i = 0; i + 8 <= n; i += 8) {
        uint64_t r = rnd();
        memcpy(b + i, &r, 8);
    }
}

static double used_pct(const char *mnt)
{
    struct statvfs s;
    if (statvfs(mnt, &s))
        die("statvfs");
    /* same definition as df: used / (used + avail) */
    double used = (double)(s.f_blocks - s.f_bfree);
    return 100.0 * used / (used + (double)s.f_bavail); 
}

static int list_files(const char *dir, char ***out) {
    DIR *d = opendir(dir);
    struct dirent *e;
    size_t cap = 1024, n = 0;
    char **v = malloc(cap * sizeof(*v));
    if (!d || !v)
        die(dir);
    while ((e = readdir(d))) {
        if (e->d_name[0] != 'f' && e->d_name[0] != 'a')
            continue;
        if (n == cap) {
            cap *= 2;
            v = realloc(v, cap * sizeof(*v));
            if (!v)
                die("realloc");
        }
        size_t len = strlen(dir) + strlen(e->d_name) + 2;
        v[n] = malloc(len);
        if (!v[n])
            die("malloc");
        snprintf(v[n], len, "%s/%s", dir, e->d_name);
        n++;
    }
    closedir(d);
    *out = v;
    return (int)n;
}

/* ---- commands ---- */
static int cmd_usedpct(int argc, char **argv) {
    if (argc < 1)
        usage();
    printf("used_pct=%.2f\n", used_pct(argv[0]));
    return 0;
}

/* Create files of <file_mb> MB until the filesystem is <target_pct>% used. */ 
static int cmd_fillto(int argc, char **argv) {
    if (argc < 4)
        usage();
    const char *dir = argv[0], *mnt = argv[3];
    double target = atof(argv[1]);
    size_t mb = (size_t)atol(argv[2]), bs = 1u << 20;
    char *buf = malloc(bs);
    long n = 0;
    uint64_t bytes = 0, t0 = now_ns();
    int enospc = 0;

    if (!buf)
        die("malloc");
    uint64_t cap = argc > 4 ? (uint64_t)atol(argv[4]) << 20 : 0; /* 0 = no cap */

    set_seed(1);
    while (!enospc && used_pct(mnt) < target && (!cap || bytes < cap)) {
        char p[512];
        snprintf(p, sizeof(p), "%s/f%06ld", dir, n);
        int fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0600);
        if (fd < 0)
            die(p);
        fillbuf(buf, bs);
        for (size_t i = 0; i < mb; i++) {
            if (write(fd, buf, bs) != (ssize_t)bs) {
                if (errno == ENOSPC) {
                    enospc = 1;
                    break;
                }
                die("write");
            }
            bytes += bs;
        }
        fsync(fd);
        close(fd);
        n++;
    }
    double el = (double)(now_ns() - t0) / 1e9;
    printf("files=%ld\nused_pct=%.2f\nenospc=%d\nelapsed_ms=%.0f\nmb_s=%.1f\n",
           n, used_pct(mnt), enospc, el * 1000, el > 0 ? bytes / 1048576.0 / el : 0);
    free(buf);
    return 0;
}

/* Unlink a random <pct>% of the files (creates fully-invalid segments). */ 
static int cmd_delete(int argc, char **argv) {
    if (argc < 3)
        usage();
    double pct = atof(argv[1]);
    char **v;
    int n, del = 0;

    set_seed(strtoull(argv[2], NULL, 0));
    n = list_files(argv[0], &v);
    for (int i = 0; i < n; i++)
        if ((double)(rnd() % 10000) < pct * 100.0 && unlink(v[i]) == 0)
            del++;
    printf("deleted=%d\nremaining=%d\n", del, n - del);
    return 0;
}

/* Random overwrites of existing files: fragments segments, creates victims. */ 
static int cmd_churn(int argc, char **argv) {
    if (argc < 5)
        usage();
    int secs = atoi(argv[1]);
    size_t iob = (size_t)atol(argv[2]) * 1024;
    long fse = atol(argv[3]);
    int maxfd = argc > 5 ? atoi(argv[5]) : 256, nfd = 0, enospc = 0;
    char **v, *buf;
    int n, *fds;
    off_t *sz;
    struct lat wl, sl;
    uint64_t ops = 0, bytes = 0, t0, tend;

    set_seed(strtoull(argv[4], NULL, 0));
    n = list_files(argv[0], &v);
    if (n == 0) {
        fprintf(stderr, "no files in %s\n", argv[0]);
        return 2;
    }
    fds = malloc(sizeof(int) * (size_t)maxfd);
    sz = malloc(sizeof(off_t) * (size_t)maxfd);
    buf = malloc(iob);
    if (!fds || !sz || !buf)
        die("malloc");
    fillbuf(buf, iob);
    for (int i = n - 1; i > 0; i--) {
        int j = (int)(rnd() % (uint64_t)(i + 1));
        char *t = v[i];
        v[i] = v[j];
        v[j] = t;
    }
    for (int i = 0; i < n && nfd < maxfd; i++) {
        struct stat st;
        int fd = open(v[i], O_RDWR);
        if (fd < 0)
            continue;
        if (fstat(fd, &st) || (size_t)st.st_size < iob) {
            close(fd);
            continue;
        }
        fds[nfd] = fd;
        sz[nfd] = st.st_size;
        nfd++;
    }
    if (!nfd) {
        fprintf(stderr, "no usable files\n");
        return 2;
    }
    lat_init(&wl, 4u << 20);
    lat_init(&sl, 1u << 20);
    t0 = now_ns();
    tend = t0 + (uint64_t)secs * 1000000000ull;
    while (now_ns() < tend) {
        int i = (int)(rnd() % (uint64_t)nfd);
        off_t off = (off_t)(rnd() % ((uint64_t)sz[i] / iob)) * (off_t)iob;
        uint64_t t = now_ns();
        uint64_t r = rnd();

        memcpy(buf, &r, 8);
        if (pwrite(fds[i], buf, iob, off) != (ssize_t)iob) {
            if (errno == ENOSPC) {
                enospc = 1;
                break;
            }
            die("pwrite");
        }
        lat_add(&wl, now_ns() - t);
        ops++;
        bytes += iob;
        if (fse && ops % (uint64_t)fse == 0) {
            t = now_ns();
            fdatasync(fds[i]);
            lat_add(&sl, now_ns() - t);
        }
    }
    double el = (double)(now_ns() - t0) / 1e9;
    printf("ops=%llu\nenospc=%d\nelapsed_ms=%.0f\nmb_s=%.1f\niops=%.0f\n",
           (unsigned long long)ops, enospc, el * 1000,
           bytes / 1048576.0 / el, ops / el);
    lat_report(&wl, "write");
    lat_report(&sl, "fsync");
    return 0;
}

/* Sequential append of new data; measures write stalls (foreground GC). */ 
static int cmd_append(int argc, char **argv) {
    if (argc < 5)
        usage();
    const char *dir = argv[0];
    uint64_t total = (uint64_t)atol(argv[1]) << 20;
    size_t cb = (size_t)atol(argv[2]) * 1024;
    long fse = atol(argv[3]);
    uint64_t roll = (uint64_t)atol(argv[4]) << 20, done = 0, in_file = 0, nw = 0;
    int fd = -1, nfile = 0, enospc = 0;
    char *buf = malloc(cb), p[512];
    struct lat wl;
    uint64_t t0 = now_ns();

    if (!buf)
        die("malloc");
    set_seed(7);
    fillbuf(buf, cb);
    lat_init(&wl, 4u << 20);
    while (done < total) {
        if (fd < 0) {
            snprintf(p, sizeof(p), "%s/a%06d", dir, nfile++);
            fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0600);
            if (fd < 0)
                die(p);
            in_file = 0;
        }
        uint64_t r = rnd(), t = now_ns();
        memcpy(buf, &r, 8);
        if (write(fd, buf, cb) != (ssize_t)cb) {
            if (errno == ENOSPC) {
                enospc = 1;
                break;
            }
            die("write");
        }
        lat_add(&wl, now_ns() - t);
        done += cb;
        in_file += cb;
        nw++;
        if (fse && nw % (uint64_t)fse == 0)
            fdatasync(fd);
        if (in_file >= roll) {
            fsync(fd);
            close(fd);
            fd = -1;
        }
    }
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    double el = (double)(now_ns() - t0) / 1e9;
    printf("written_mb=%llu\nenospc=%d\nelapsed_ms=%.0f\nmb_s=%.1f\n",
           (unsigned long long)(done >> 20), enospc, el * 1000,
           done / 1048576.0 / el);
    lat_report(&wl, "write");
    return 0;
}

/*
 * F2FS_IOC_GARBAGE_COLLECT: sync=1 runs a foreground-type GC, sync=0 a
 * background-type attempt (EBUSY if the GC lock is held). ENODATA means no
 * victim section is left. Requires root.
 */
static int cmd_gc(int argc, char **argv) {
    if (argc < 3)
        usage();
    int fd = open(argv[0], O_RDONLY), last = 0;
    uint32_t sync = (uint32_t)atoi(argv[1]);
    long maxc = atol(argv[2]), calls = 0, ok = 0, busy = 0;
    struct lat l;
    uint64_t t0 = now_ns();

    if (fd < 0)
        die(argv[0]);
    lat_init(&l, 1u << 20);
    while (calls < maxc) {
        uint32_t arg = sync;
        uint64_t t = now_ns();
        int r = ioctl(fd, F2FS_IOC_GARBAGE_COLLECT, &arg);
        uint64_t dt = now_ns() - t;

        calls++;
        if (r == 0) {
            ok++;
            lat_add(&l, dt);
            continue;
        }
        last = errno;
        if (errno == EBUSY && busy < 100) {
            busy++;
            usleep(10000);
            continue;
        }
        break; /* ENODATA: no victim; EPERM: not root */
    }
    printf("calls=%ld\nok=%ld\nbusy=%ld\nlast_errno=%d\nelapsed_ms=%.0f\n",
           calls, ok, busy, last, (double)(now_ns() - t0) / 1e6);
    lat_report(&l, "gc_call");
    return 0;
}

static int cmd_gcrange(int argc, char **argv) {
    if (argc < 4)
        usage();
    int fd = open(argv[0], O_RDONLY);
    struct f2fs_gc_range r;
    uint64_t t0;
    int ret;

    if (fd < 0)
        die(argv[0]);
    r.start = strtoull(argv[1], NULL, 0);
    r.len = strtoull(argv[2], NULL, 0);
    r.sync = (uint32_t)atoi(argv[3]);
    t0 = now_ns();
    ret = ioctl(fd, F2FS_IOC_GARBAGE_COLLECT_RANGE, &r);
    printf("ret=%d\nerrno=%d\nelapsed_ms=%.1f\n", ret, ret ? errno : 0,
           (double)(now_ns() - t0) / 1e6);
    return 0;
}

static int cmd_ckpt(int argc, char **argv) {
    if (argc < 1)
        usage();
    int fd = open(argv[0], O_RDONLY);
    uint64_t t0;
    int ret;

    if (fd < 0)
        die(argv[0]);
    t0 = now_ns();
    ret = ioctl(fd, F2FS_IOC_WRITE_CHECKPOINT);
    printf("ret=%d\nerrno=%d\nelapsed_ms=%.1f\n", ret, ret ? errno : 0,
           (double)(now_ns() - t0) / 1e6);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2)
        usage();
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (!strcmp(argv[1], "usedpct"))  return cmd_usedpct(argc - 2, argv + 2);
    if (!strcmp(argv[1], "fillto"))   return cmd_fillto(argc - 2, argv + 2);
    if (!strcmp(argv[1], "delete"))   return cmd_delete(argc - 2, argv + 2);
    if (!strcmp(argv[1], "churn"))    return cmd_churn(argc - 2, argv + 2);
    if (!strcmp(argv[1], "append"))   return cmd_append(argc - 2, argv + 2);
    if (!strcmp(argv[1], "gc"))       return cmd_gc(argc - 2, argv + 2);
    if (!strcmp(argv[1], "gcrange"))  return cmd_gcrange(argc - 2, argv + 2);
    if (!strcmp(argv[1], "ckpt"))     return cmd_ckpt(argc - 2, argv + 2);
    usage();
    return 1;
}

// SPDX-License-Identifier: GPL-2.0
/*
 * gcbench - deterministic F2FS foreground-GC copy benchmark.
 *
 *   gcbench prep   <dir> <nseg> <unit_kb> <keep> <pattern>
 *   gcbench run    <dir> <nseg> <moved_counter|-> <fgio 0|1>
 *   gcbench verify <dir> <nseg> <unit_kb> <keep> <pattern>
 *
 * A "segment group" is 2 MiB = (2048/unit_kb) files of unit_kb each. prep writes
 * every file with a deterministic pattern, then unlinks all but <keep> of them in
 * every group, so each victim segment has keep/units valid. pattern=contig keeps
 * the first <keep> units; pattern=alt spreads the kept units evenly (scattered
 * source ranges). run issues F2FS_IOC_GARBAGE_COLLECT (sync) calls and measures
 * wall time, CPU time of the calling thread (precise, not tick sampled) and
 * system-wide CPU, optionally with a concurrent foreground fsync-append writer.
 * verify re-reads every kept file and checks the pattern (data integrity).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/types.h>

#ifndef F2FS_IOCTL_MAGIC
#define F2FS_IOCTL_MAGIC 0xf5
#endif
#define F2FS_IOC_GARBAGE_COLLECT _IOW(F2FS_IOCTL_MAGIC, 6, __u32)
#define SEG_KB 2048

static uint64_t now_ns(clockid_t c)
{
	struct timespec t;
	clock_gettime(c, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}

static uint64_t mix(uint64_t x)
{
	x += 0x9e3779b97f4a7c15ull;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
	return x ^ (x >> 31);
}

static void fill(uint64_t *b, size_t words, uint64_t g)
{
	for (size_t i = 0; i < words; i++)
		b[i] = mix((g << 24) ^ i);
}

static int keep_unit(int u, int units, int keep, int alt)
{
	if (!alt)
		return u < keep;
	return ((u + 1) * keep) / units != (u * keep) / units;
}

static void fname(char *p, size_t n, const char *dir, uint64_t g)
{
	snprintf(p, n, "%s/d/f%llu", dir, (unsigned long long)g);
}

static int cmd_prep(const char *dir, int nseg, int ukb, int keep, int alt)
{
	int units = SEG_KB / ukb;
	size_t sz = (size_t)ukb * 1024, words = sz / 8;
	uint64_t *buf = malloc(sz);
	char p[512];
	char d[512];
	uint64_t kept = 0;

	snprintf(d, sizeof(d), "%s/d", dir);
	if (mkdir(d, 0777) && errno != EEXIST) { perror("mkdir"); return 1; }
	for (int s = 0; s < nseg; s++)
		for (int u = 0; u < units; u++) {
			uint64_t g = (uint64_t)s * units + u;
			int fd;

			fname(p, sizeof(p), dir, g);
			fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0666);
			if (fd < 0) { perror(p); return 1; }
			fill(buf, words, g);
			if (write(fd, buf, sz) != (ssize_t)sz) { perror("write"); return 1; }
			if (fsync(fd)) { perror("fsync"); return 1; }
			close(fd);
		}
	sync();
	for (int s = 0; s < nseg; s++)
		for (int u = 0; u < units; u++) {
			uint64_t g = (uint64_t)s * units + u;

			if (keep_unit(u, units, keep, alt)) { kept++; continue; }
			fname(p, sizeof(p), dir, g);
			if (unlink(p)) { perror(p); return 1; }
		}
	sync();
	printf("prep_ok kept_files=%llu kept_blocks=%llu\n", (unsigned long long)kept,
	       (unsigned long long)(kept * ukb / 4));
	free(buf);
	return 0;
}

static int cmd_verify(const char *dir, int nseg, int ukb, int keep, int alt)
{
	int units = SEG_KB / ukb;
	size_t sz = (size_t)ukb * 1024, words = sz / 8;
	uint64_t *exp = malloc(sz), *got = malloc(sz);
	uint64_t bad = 0, chk = 0;
	char p[512];

	for (int s = 0; s < nseg; s++)
		for (int u = 0; u < units; u++) {
			uint64_t g = (uint64_t)s * units + u;
			int fd;

			if (!keep_unit(u, units, keep, alt))
				continue;
			chk++;
			fname(p, sizeof(p), dir, g);
			fd = open(p, O_RDONLY);
			if (fd < 0) { bad++; continue; }
			fill(exp, words, g);
			if (read(fd, got, sz) != (ssize_t)sz || memcmp(exp, got, sz))
				bad++;
			close(fd);
		}
	printf("verify=%s checked=%llu bad=%llu\n", bad ? "FAIL" : "OK",
	       (unsigned long long)chk, (unsigned long long)bad);
	free(exp);
	free(got);
	return bad != 0;
}

static unsigned long long rd_ull(const char *path)
{
	unsigned long long v = 0;
	FILE *f;

	if (!path || !strcmp(path, "-"))
		return 0;
	f = fopen(path, "r");
	if (!f)
		return 0;
	if (fscanf(f, "%llu", &v) != 1)
		v = 0;
	fclose(f);
	return v;
}

static uint64_t sys_busy_ticks(void)
{
	unsigned long long u, n, s, i, w, irq, sirq, st;
	FILE *f = fopen("/proc/stat", "r");

	if (!f)
		return 0;
	if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &u, &n, &s,
		   &i, &w, &irq, &sirq, &st) != 8)
		u = n = s = irq = sirq = st = 0;
	fclose(f);
	return u + n + s + irq + sirq + st;
}

static int cmp64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;

	return x < y ? -1 : x > y;
}

static void pct(uint64_t *v, size_t n, uint64_t *p50, uint64_t *p99, uint64_t *mx)
{
	*p50 = *p99 = *mx = 0;
	if (!n)
		return;
	qsort(v, n, sizeof(*v), cmp64);
	*p50 = v[n / 2];
	*p99 = v[(n * 99) / 100 >= n ? n - 1 : (n * 99) / 100];
	*mx = v[n - 1];
}

static volatile int stop_fg;
static uint64_t *fg_lat;
static size_t fg_n, fg_cap = 4u << 20;
static const char *fg_dir;

static void *fg_thread(void *arg)
{
	char p[512];
	char buf[4096];
	int fd;
	off_t off = 0;

	(void)arg;
	snprintf(p, sizeof(p), "%s/fg.dat", fg_dir);
	fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0666);
	if (fd < 0)
		return NULL;
	memset(buf, 0x5a, sizeof(buf));
	while (!stop_fg && fg_n < fg_cap) {
		uint64_t t0 = now_ns(CLOCK_MONOTONIC);

		if (pwrite(fd, buf, sizeof(buf), off) != sizeof(buf))
			break;
		fdatasync(fd);
		fg_lat[fg_n++] = (now_ns(CLOCK_MONOTONIC) - t0) / 1000;
		off = (off + 4096) % (256ll << 20);
	}
	close(fd);
	return NULL;
}

static int cmd_run(const char *dir, int nseg, const char *moved_path, int fgio)
{
	uint64_t *lat = calloc((size_t)nseg * 2 + 16, sizeof(*lat));
	size_t calls = 0, ok = 0, busy = 0;
	unsigned long long m0 = rd_ull(moved_path), m1;
	uint32_t sync_arg = 1;
	pthread_t th;
	uint64_t w0, w1, c0, c1, s0, s1, p50, p99, mx;
	int fd = open(dir, O_RDONLY | O_DIRECTORY);
	int last_errno = 0;

	if (fd < 0) { perror(dir); return 1; }
	fg_dir = dir;
	if (fgio) {
		fg_lat = calloc(fg_cap, sizeof(*fg_lat));
		pthread_create(&th, NULL, fg_thread, NULL);
		usleep(200000);
	}
	s0 = sys_busy_ticks();
	c0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
	w0 = now_ns(CLOCK_MONOTONIC);
	while (calls < (size_t)nseg * 2) {
		uint64_t t0 = now_ns(CLOCK_MONOTONIC);
		int r = ioctl(fd, F2FS_IOC_GARBAGE_COLLECT, &sync_arg);
		uint64_t dt = (now_ns(CLOCK_MONOTONIC) - t0) / 1000;

		if (r < 0) {
			last_errno = errno;
			if (errno == EBUSY) { busy++; usleep(1000); continue; }
			break;
		}
		lat[calls++] = dt;
		ok++;
		if (ok >= (size_t)nseg)
			break;
	}
	w1 = now_ns(CLOCK_MONOTONIC);
	c1 = now_ns(CLOCK_THREAD_CPUTIME_ID);
	s1 = sys_busy_ticks();
	if (fgio) {
		stop_fg = 1;
		pthread_join(th, NULL);
	}
	m1 = rd_ull(moved_path);
	pct(lat, ok, &p50, &p99, &mx);
	printf("gc_calls=%zu gc_busy=%zu last_errno=%d wall_ms=%.2f thread_cpu_ms=%.2f "
	       "sys_cpu_ms=%llu moved_blks=%llu call_p50_us=%llu call_p99_us=%llu "
	       "call_max_us=%llu",
	       ok, busy, last_errno, (w1 - w0) / 1e6, (c1 - c0) / 1e6,
	       (unsigned long long)((s1 - s0) * 10), m1 - m0,
	       (unsigned long long)p50, (unsigned long long)p99,
	       (unsigned long long)mx);
	if (fgio) {
		uint64_t a, b, c;

		pct(fg_lat, fg_n, &a, &b, &c);
		printf(" fg_ops=%zu fg_p50_us=%llu fg_p99_us=%llu fg_max_us=%llu", fg_n,
		       (unsigned long long)a, (unsigned long long)b,
		       (unsigned long long)c);
	}
	printf("\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 7 && !strcmp(argv[1], "prep"))
		return cmd_prep(argv[2], atoi(argv[3]), atoi(argv[4]), atoi(argv[5]),
				!strcmp(argv[6], "alt"));
	if (argc >= 7 && !strcmp(argv[1], "verify"))
		return cmd_verify(argv[2], atoi(argv[3]), atoi(argv[4]), atoi(argv[5]),
				  !strcmp(argv[6], "alt"));
	if (argc >= 6 && !strcmp(argv[1], "run"))
		return cmd_run(argv[2], atoi(argv[3]), argv[4], atoi(argv[5]));
	fprintf(stderr, "usage: see header comment\n");
	return 2;
}

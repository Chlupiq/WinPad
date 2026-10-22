/* A 32-bit x86 Windows console program for the SIMD instructions FEX's NoJIT
 * interpreter has to run as its JIT does (patches/fex-wow64/0026): MMX, SSE
 * to SSE4.1 shifts by a register, packs, psadbw, pmulhrsw, psign, haddps,
 * dpps, rounding and conversions. Each instruction runs on inputs from a
 * fixed pseudo-random sequence, edge values among them (NaN, infinities,
 * values past the integer range, ties, shift counts past the element size and
 * with high bits set), and a hash of its results is printed per instruction:
 * "simd: NAME HASH". A run with FEX's JIT and a NoJIT run that interprets
 * every block of the program have to print the same lines. Ends with
 * "simd: done". kernel32 only, no CRT, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static HANDLE out;

/* A line goes out in one write at its newline, so that Wine's own messages,
 * which share the log, cannot land in the middle of it. */
static char line[128];
static DWORD used;
static void put(const char* s) {
  DWORD w;
  for (; *s; s++) {
    if (used < sizeof(line)) line[used++] = *s;
    if (*s == '\n') {
      WriteFile(out, line, used, &w, 0);
      used = 0;
    }
  }
}
static void hex(u32 v) {
  char b[9];
  int i;
  for (i = 0; i < 8; i++) b[i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
  b[8] = 0;
  put(b);
}

static u32 rng = 0x2545f491;
static u32 next(void) {
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return rng;
}

/* Floats and doubles worth testing: ties, fractions, edges of the 32-bit
 * range, NaN and the infinities; otherwise random ones of moderate size. */
static const u32 float_specials[] = {
  0x3f000000, /* 0.5 */ 0x3fc00000, /* 1.5 */ 0x40200000, /* 2.5 */ 0xc0200000, /* -2.5 */
  0x7fc00000, /* NaN */ 0x7f800000, /* inf */ 0xff800000, /* -inf */ 0x4f000000, /* 2^31 */
  0xcf000000, /* -2^31 */ 0x4f800000, /* 2^32 */ 0x60ad78ec, /* 1e20 */ 0x80000000, /* -0 */
};
static u32 rand_float(void) {
  u32 r = next();
  if ((r & 7) == 0) return float_specials[(r >> 3) % (sizeof(float_specials) / sizeof(float_specials[0]))];
  /* exponent 2^-4 .. 2^12, random sign and mantissa */
  return (r & 0x807fffff) | ((123 + (r >> 23) % 17) << 23);
}
static const u64 double_specials[] = {
  0x3fe0000000000000ull, /* 0.5 */ 0x3ff8000000000000ull, /* 1.5 */ 0x4004000000000000ull, /* 2.5 */
  0xc004000000000000ull, /* -2.5 */ 0x7ff8000000000000ull, /* NaN */ 0x7ff0000000000000ull, /* inf */
  0xfff0000000000000ull, /* -inf */ 0x41e0000000000000ull, /* 2^31 */ 0xc1e0000000200000ull, /* -2^31 - 1 */
  0x41dfffffffc00000ull, /* 2^31 - 1 */ 0x4415af1d78b58c40ull, /* 1e20 */ 0x416312d000000000ull, /* 1e7 */
};
static u64 rand_double(void) {
  u32 r = next();
  if ((r & 7) == 0) return double_specials[(r >> 3) % (sizeof(double_specials) / sizeof(double_specials[0]))];
  u64 m = ((u64)next() << 32 | next()) & 0x800fffffffffffffull;
  return m | ((u64)(1019 + (r >> 20) % 17) << 52);
}

enum Kind { INT, FLOAT, DOUBLE, SHIFT };
static void fill(u8* p, enum Kind k) {
  int i;
  for (i = 0; i < 16; i += 4) {
    u32 v;
    if (k == FLOAT) {
      v = rand_float();
    } else if (k == DOUBLE) {
      u64 d = rand_double();
      ((u32*)p)[i / 4] = (u32)d;
      ((u32*)p)[i / 4 + 1] = (u32)(d >> 32);
      i += 4;
      continue;
    } else {
      v = next();
      /* Some small elements, so that packs and psign also meet values in range. */
      if ((v & 3) == 0) v = (v >> 24) * 0x01010101u;
    }
    ((u32*)p)[i / 4] = v;
  }
  if (k == SHIFT) {
    u32 r = next();
    /* Counts below, at and past the element sizes; now and then high bits set. */
    ((u32*)p)[0] = r % 72;
    ((u32*)p)[1] = (r & 0x700) == 0x700 ? 1 : 0;
    if ((r & 0xf000) == 0xf000) ((u32*)p)[0] = 0x100 + r % 8;
  }
}

static u32 hash;
static void mix(const u8* p, int n) {
  int i;
  for (i = 0; i < n; i++) hash = (hash ^ p[i]) * 16777619u;
}

typedef void (*TestFn)(const u8* a, const u8* b, u8* o);
static void run(const char* name, TestFn f, enum Kind ka, enum Kind kb, int bytes) {
  u8 a[16] __attribute__((aligned(16))), b[16] __attribute__((aligned(16))), o[16] __attribute__((aligned(16)));
  int i, j;
  hash = 2166136261u;
  for (i = 0; i < 64; i++) {
    fill(a, ka);
    fill(b, kb);
    for (j = 0; j < 16; j++) o[j] = 0xcc;
    f(a, b, o);
    mix(o, bytes);
  }
  put("simd: ");
  put(name);
  put(" ");
  hex(hash);
  put("\n");
}

/* xmm0 = a, xmm1 = b; INSN; result from xmm0. */
#define XMM(fn, insn)                                                                                     \
  static void fn(const u8* a, const u8* b, u8* o) {                                                       \
    __asm__ volatile("movdqu (%0), %%xmm0\n movdqu (%1), %%xmm1\n " insn "\n movdqu %%xmm0, (%2)" ::"r"(a), \
                     "r"(b), "r"(o)                                                                       \
                     : "xmm0", "xmm1", "mm1", "memory");                                                         \
  }
/* mm0 = a, mm1 = b (low 8 bytes); INSN; result from mm0. */
#define MMX(fn, insn)                                                                                          \
  static void fn(const u8* a, const u8* b, u8* o) {                                                            \
    __asm__ volatile("movq (%0), %%mm0\n movq (%1), %%mm1\n " insn "\n movq %%mm0, (%2)\n emms" ::"r"(a), "r"(b), \
                     "r"(o)                                                                                    \
                     : "mm0", "mm1", "xmm1", "memory");                                                                \
  }
/* xmm1 = b; INSN leaves a 32-bit integer in eax. */
#define TOGPR(fn, insn)                                                                                     \
  static void fn(const u8* a, const u8* b, u8* o) {                                                         \
    (void)a;                                                                                                \
    __asm__ volatile("movdqu (%0), %%xmm1\n " insn "\n movl %%eax, (%1)" ::"r"(b), "r"(o) : "eax", "xmm1", \
                     "memory");                                                                             \
  }

XMM(psllw_x, "psllw %%xmm1, %%xmm0")
XMM(pslld_x, "pslld %%xmm1, %%xmm0")
XMM(psllq_x, "psllq %%xmm1, %%xmm0")
XMM(psrlw_x, "psrlw %%xmm1, %%xmm0")
XMM(psrld_x, "psrld %%xmm1, %%xmm0")
XMM(psrlq_x, "psrlq %%xmm1, %%xmm0")
XMM(psraw_x, "psraw %%xmm1, %%xmm0")
XMM(psrad_x, "psrad %%xmm1, %%xmm0")
MMX(psllw_m, "psllw %%mm1, %%mm0")
MMX(psrld_m, "psrld %%mm1, %%mm0")
MMX(psrlq_m, "psrlq %%mm1, %%mm0")
MMX(psraw_m, "psraw %%mm1, %%mm0")
XMM(packsswb_x, "packsswb %%xmm1, %%xmm0")
XMM(packssdw_x, "packssdw %%xmm1, %%xmm0")
XMM(packuswb_x, "packuswb %%xmm1, %%xmm0")
XMM(packusdw_x, "packusdw %%xmm1, %%xmm0")
MMX(packsswb_m, "packsswb %%mm1, %%mm0")
MMX(packssdw_m, "packssdw %%mm1, %%mm0")
MMX(packuswb_m, "packuswb %%mm1, %%mm0")
XMM(pmaddubsw_x, "pmaddubsw %%xmm1, %%xmm0")
MMX(pmaddubsw_m, "pmaddubsw %%mm1, %%mm0")
XMM(pmulhrsw_x, "pmulhrsw %%xmm1, %%xmm0")
MMX(pmulhrsw_m, "pmulhrsw %%mm1, %%mm0")
XMM(psadbw_x, "psadbw %%xmm1, %%xmm0")
MMX(psadbw_m, "psadbw %%mm1, %%mm0")
XMM(mpsadbw_x, "mpsadbw $5, %%xmm1, %%xmm0")
XMM(psignb_x, "psignb %%xmm1, %%xmm0")
XMM(psignw_x, "psignw %%xmm1, %%xmm0")
XMM(psignd_x, "psignd %%xmm1, %%xmm0")
MMX(psignw_m, "psignw %%mm1, %%mm0")
XMM(haddps_x, "haddps %%xmm1, %%xmm0")
XMM(haddpd_x, "haddpd %%xmm1, %%xmm0")
XMM(dpps_x, "dpps $0xf1, %%xmm1, %%xmm0")
XMM(dpps_x2, "dpps $0x7e, %%xmm1, %%xmm0")
XMM(dppd_x, "dppd $0x31, %%xmm1, %%xmm0")
XMM(roundps_0, "roundps $0, %%xmm1, %%xmm0")
XMM(roundps_1, "roundps $1, %%xmm1, %%xmm0")
XMM(roundps_2, "roundps $2, %%xmm1, %%xmm0")
XMM(roundps_3, "roundps $3, %%xmm1, %%xmm0")
XMM(roundps_4, "roundps $4, %%xmm1, %%xmm0")
XMM(roundpd_0, "roundpd $0, %%xmm1, %%xmm0")
XMM(roundpd_1, "roundpd $9, %%xmm1, %%xmm0")
XMM(roundss_2, "roundss $2, %%xmm1, %%xmm0")
XMM(roundsd_3, "roundsd $3, %%xmm1, %%xmm0")
XMM(cvtps2dq_x, "cvtps2dq %%xmm1, %%xmm0")
XMM(cvttps2dq_x, "cvttps2dq %%xmm1, %%xmm0")
XMM(cvtpd2dq_x, "cvtpd2dq %%xmm1, %%xmm0")
XMM(cvttpd2dq_x, "cvttpd2dq %%xmm1, %%xmm0")
MMX(cvtpd2pi_x, "movdqu (%1), %%xmm1\n cvtpd2pi %%xmm1, %%mm0")
MMX(cvttpd2pi_x, "movdqu (%1), %%xmm1\n cvttpd2pi %%xmm1, %%mm0")
XMM(cvtpi2ps_x, "movq (%1), %%mm1\n cvtpi2ps %%mm1, %%xmm0\n emms")
XMM(cvtpi2pd_x, "movq (%1), %%mm1\n cvtpi2pd %%mm1, %%xmm0\n emms")
XMM(cvtdq2ps_x, "cvtdq2ps %%xmm1, %%xmm0")
XMM(cvtdq2pd_x, "cvtdq2pd %%xmm1, %%xmm0")
XMM(cvtps2pd_x, "cvtps2pd %%xmm1, %%xmm0")
XMM(cvtpd2ps_x, "cvtpd2ps %%xmm1, %%xmm0")
XMM(cvtsi2ss_x, "cvtsi2ss (%1), %%xmm0")
XMM(cvtsi2sd_x, "cvtsi2sd (%1), %%xmm0")
TOGPR(cvtss2si_g, "cvtss2si %%xmm1, %%eax")
TOGPR(cvttss2si_g, "cvttss2si %%xmm1, %%eax")
TOGPR(cvtsd2si_g, "cvtsd2si %%xmm1, %%eax")
TOGPR(cvttsd2si_g, "cvttsd2si %%xmm1, %%eax")
XMM(rcpps_x, "rcpps %%xmm1, %%xmm0")
XMM(rsqrtps_x, "rsqrtps %%xmm1, %%xmm0")
XMM(sqrtps_x, "sqrtps %%xmm1, %%xmm0")
XMM(minps_x, "minps %%xmm1, %%xmm0")
XMM(cmpltps_x, "cmpltps %%xmm1, %%xmm0")

void start(void) {
  out = GetStdHandle(STD_OUTPUT_HANDLE);
  run("psllw", psllw_x, INT, SHIFT, 16);
  run("pslld", pslld_x, INT, SHIFT, 16);
  run("psllq", psllq_x, INT, SHIFT, 16);
  run("psrlw", psrlw_x, INT, SHIFT, 16);
  run("psrld", psrld_x, INT, SHIFT, 16);
  run("psrlq", psrlq_x, INT, SHIFT, 16);
  run("psraw", psraw_x, INT, SHIFT, 16);
  run("psrad", psrad_x, INT, SHIFT, 16);
  run("psllw-mmx", psllw_m, INT, SHIFT, 8);
  run("psrld-mmx", psrld_m, INT, SHIFT, 8);
  run("psrlq-mmx", psrlq_m, INT, SHIFT, 8);
  run("psraw-mmx", psraw_m, INT, SHIFT, 8);
  run("packsswb", packsswb_x, INT, INT, 16);
  run("packssdw", packssdw_x, INT, INT, 16);
  run("packuswb", packuswb_x, INT, INT, 16);
  run("packusdw", packusdw_x, INT, INT, 16);
  run("packsswb-mmx", packsswb_m, INT, INT, 8);
  run("packssdw-mmx", packssdw_m, INT, INT, 8);
  run("packuswb-mmx", packuswb_m, INT, INT, 8);
  run("pmaddubsw", pmaddubsw_x, INT, INT, 16);
  run("pmaddubsw-mmx", pmaddubsw_m, INT, INT, 8);
  run("pmulhrsw", pmulhrsw_x, INT, INT, 16);
  run("pmulhrsw-mmx", pmulhrsw_m, INT, INT, 8);
  run("psadbw", psadbw_x, INT, INT, 16);
  run("psadbw-mmx", psadbw_m, INT, INT, 8);
  run("mpsadbw", mpsadbw_x, INT, INT, 16);
  run("psignb", psignb_x, INT, INT, 16);
  run("psignw", psignw_x, INT, INT, 16);
  run("psignd", psignd_x, INT, INT, 16);
  run("psignw-mmx", psignw_m, INT, INT, 8);
  run("haddps", haddps_x, FLOAT, FLOAT, 16);
  run("haddpd", haddpd_x, DOUBLE, DOUBLE, 16);
  run("dpps-f1", dpps_x, FLOAT, FLOAT, 16);
  run("dpps-7e", dpps_x2, FLOAT, FLOAT, 16);
  run("dppd", dppd_x, DOUBLE, DOUBLE, 16);
  run("roundps-nearest", roundps_0, FLOAT, FLOAT, 16);
  run("roundps-down", roundps_1, FLOAT, FLOAT, 16);
  run("roundps-up", roundps_2, FLOAT, FLOAT, 16);
  run("roundps-zero", roundps_3, FLOAT, FLOAT, 16);
  run("roundps-mxcsr", roundps_4, FLOAT, FLOAT, 16);
  run("roundpd-nearest", roundpd_0, DOUBLE, DOUBLE, 16);
  run("roundpd-down", roundpd_1, DOUBLE, DOUBLE, 16);
  run("roundss-up", roundss_2, FLOAT, FLOAT, 16);
  run("roundsd-zero", roundsd_3, DOUBLE, DOUBLE, 16);
  run("cvtps2dq", cvtps2dq_x, FLOAT, FLOAT, 16);
  run("cvttps2dq", cvttps2dq_x, FLOAT, FLOAT, 16);
  run("cvtpd2dq", cvtpd2dq_x, DOUBLE, DOUBLE, 16);
  run("cvttpd2dq", cvttpd2dq_x, DOUBLE, DOUBLE, 16);
  run("cvtpd2pi", cvtpd2pi_x, INT, DOUBLE, 8);
  run("cvttpd2pi", cvttpd2pi_x, INT, DOUBLE, 8);
  run("cvtpi2ps", cvtpi2ps_x, FLOAT, INT, 16);
  run("cvtpi2pd", cvtpi2pd_x, DOUBLE, INT, 16);
  run("cvtdq2ps", cvtdq2ps_x, FLOAT, INT, 16);
  run("cvtdq2pd", cvtdq2pd_x, DOUBLE, INT, 16);
  run("cvtps2pd", cvtps2pd_x, DOUBLE, FLOAT, 16);
  run("cvtpd2ps", cvtpd2ps_x, FLOAT, DOUBLE, 16);
  run("cvtsi2ss", cvtsi2ss_x, FLOAT, INT, 16);
  run("cvtsi2sd", cvtsi2sd_x, DOUBLE, INT, 16);
  run("cvtss2si", cvtss2si_g, INT, FLOAT, 4);
  run("cvttss2si", cvttss2si_g, INT, FLOAT, 4);
  run("cvtsd2si", cvtsd2si_g, INT, DOUBLE, 4);
  run("cvttsd2si", cvttsd2si_g, INT, DOUBLE, 4);
  run("rcpps", rcpps_x, FLOAT, FLOAT, 16);
  run("rsqrtps", rsqrtps_x, FLOAT, FLOAT, 16);
  run("sqrtps", sqrtps_x, FLOAT, FLOAT, 16);
  run("minps", minps_x, FLOAT, FLOAT, 16);
  run("cmpltps", cmpltps_x, FLOAT, FLOAT, 16);
  put("simd: done\n");
  ExitProcess(0);
}

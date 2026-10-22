/* A 32-bit x86 Windows console program that reads and writes memory the way
 * a hook installer scans a game for byte patterns: 16- and 32-bit accesses at
 * every byte offset, many of them across a 16-byte boundary. FEX turns them
 * into acquire loads and release stores, which an iPad's CPU faults on when
 * they cross one; read-only AOT code then has to be compiled with plain ones
 * and half barriers instead (patches/fex-wow64/0030). It checks each access
 * against the bytes, prints "unaligned: done" and exits with 0 when all match.
 * kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static unsigned char buf[256 + 4] __attribute__((aligned(16)));

static DWORD put(const char* s) {
  DWORD n = 0, written;
  while (s[n]) {
    n++;
  }
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
  return n;
}

static unsigned bytes32(unsigned i) {
  return buf[i] | buf[i + 1] << 8 | buf[i + 2] << 16 | (unsigned)buf[i + 3] << 24;
}

void start(void) {
  int ok = 1;
  for (unsigned i = 0; i < sizeof(buf); i++) {
    buf[i] = (unsigned char)(i * 37 + 11);
  }
  for (int round = 0; round < 64; round++) {
    for (unsigned i = 0; i < 256; i++) {
      volatile unsigned* p32 = (volatile unsigned*)(buf + i);
      volatile unsigned short* p16 = (volatile unsigned short*)(buf + i);
      ok &= *p32 == bytes32(i);
      ok &= *p16 == (unsigned short)bytes32(i);
    }
    /* Stores across a boundary, then the bytes they wrote. */
    for (unsigned i = 13; i < 256; i += 16) {
      const unsigned v = 0x01020304u * (round + 1) + i;
      *(volatile unsigned*)(buf + i) = v;
      ok &= bytes32(i) == v;
      *(volatile unsigned short*)(buf + i + 2) = (unsigned short)~v;
      ok &= (unsigned short)(bytes32(i + 2)) == (unsigned short)~v;
    }
  }
  put(ok ? "unaligned: done\n" : "unaligned: FAIL\n");
  ExitProcess(ok ? 0 : 1);
}

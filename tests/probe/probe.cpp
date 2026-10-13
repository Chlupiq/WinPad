// SPDX-License-Identifier: MIT
// WinPad probe: the smallest FEXCore frontend that runs one x86-64 program
// (guest.S) without FEX's Linux emulation layer, so the same code can run in
// an iOS app. The guest is mapped at whatever address mmap returns and only
// needs the write syscall; it stops with HLT.
//
// Guest exceptions: the guest registers a handler (syscall 0x5750), and ud2,
// int3 and faulting memory reads continue there instead of killing the
// process, see OnHostSignal.
//
// Modes (each one process, as they would be on a build machine and a device):
//   record CODEMAP          run with the JIT and record the executed blocks
//   generate CODEMAP DIR    compile the recorded blocks into an AOT code cache
//                           in DIR and write FEX's dispatcher to DIR/dispatcher.bin,
//                           without executable memory (NoJIT)
//   run IMAGE               run from an AOT image built from the cache by
//                           tools/cache2macho, with NoJIT: no memory is ever
//                           made executable
//
// Code generation depends on the host CPU features, so the probe always uses
// one fixed baseline (an A14/M1-class core) instead of probing the machine:
// a cache made on a Linux ARM64 server then also fits an iPad.
#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/CodeCache.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Core/SignalDelegator.h>
#include <FEXCore/Core/X86Enums.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SourcecodeResolver.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/fextl/fmt.h>
#include <FEXCore/fextl/memory.h>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <fstream>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

#include "guest.h"

namespace {
// Identifies the guest in code maps, caches and image symbol names
// (fexaot_<FileId>_<ConfigId>_*). The code cache config id is 0 in this FEX.
constexpr uint64_t GuestFileId = 0x5750'5052'4f42'4501; // "WPPROBE\1"
constexpr uint64_t CodeCacheConfigId = 0;
constexpr size_t StackSize = 1024 * 1024;

std::string Output;

void MsgHandler(LogMan::DebugLevels Level, const char* Message) {
  fprintf(stderr, "[%s] %s\n", LogMan::DebugLevelStr(Level), Message);
}

void AssertHandler(const char* Message) {
  fprintf(stderr, "[A] %s\n", Message);
}

FEXCore::HostFeatures BaselineFeatures() {
  FEXCore::HostFeatures F {};
  F.DCacheLineLog2 = 4; // 64-byte lines
  F.SupportsAES = true;
  F.SupportsCRC = true;
  F.SupportsAtomics = true;
  F.SupportsRCPC = true;
  F.SupportsTSOImm9 = true;
  F.SupportsAVX = true;
  F.SupportsSHA = true;
  F.SupportsPMULL_128Bit = true;
  F.SupportsFCMA = true;
  F.SupportsFlagM = true;
  F.SupportsFlagM2 = true;
  F.SupportsAES256 = true;
  F.SupportsFRINTTS = true;
  F.Supports3DNow = true;
  F.SupportsDotProd = true;
  F.SupportsPreserveAllABI = FEX_HAS_PRESERVE_ALL_ATTR;
  F.HostType = FEXCore::HostFeatures::HostTypeEnum::Linux;
  // Only the count matters (CPUID core count); implementer 0x61 is Apple.
  F.CPUMIDRs.assign(4, 0x611f0220);
  return F;
}

class ProbeSignalDelegator final : public FEXCore::SignalDelegator {};

// The guest's exception handler (0: none) and what OnHostSignal needs to reach it.
uint64_t GuestExceptionHandler;
ProbeSignalDelegator* Signals;
FEXCore::Context::Context* ExceptionCTX;
FEXCore::Core::InternalThreadState* ExceptionThread;

// Host registers in a signal's ucontext.
#ifdef __APPLE__
uint64_t& HostPc(ucontext_t* U) {
  return U->uc_mcontext->__ss.__pc;
}
uint64_t& HostSp(ucontext_t* U) {
  return U->uc_mcontext->__ss.__sp;
}
uint64_t& HostX(ucontext_t* U, int N) {
  return N == 29 ? U->uc_mcontext->__ss.__fp : N == 30 ? U->uc_mcontext->__ss.__lr : U->uc_mcontext->__ss.__x[N];
}
const __uint128_t* HostV(ucontext_t* U) {
  return U->uc_mcontext->__ns.__v;
}
#else
uint64_t& HostPc(ucontext_t* U) {
  return reinterpret_cast<uint64_t&>(U->uc_mcontext.pc);
}
uint64_t& HostSp(ucontext_t* U) {
  return reinterpret_cast<uint64_t&>(U->uc_mcontext.sp);
}
uint64_t& HostX(ucontext_t* U, int N) {
  return reinterpret_cast<uint64_t&>(U->uc_mcontext.regs[N]);
}
const __uint128_t* HostV(ucontext_t* U) {
  // The kernel puts struct fpsimd_context (magic, size, fpsr, fpcr, vregs[32])
  // first in __reserved.
  auto* Reserved = reinterpret_cast<const uint8_t*>(U->uc_mcontext.__reserved);
  uint32_t Magic;
  memcpy(&Magic, Reserved, sizeof(Magic));
  return Magic == 0x46508001 ? reinterpret_cast<const __uint128_t*>(Reserved + 16) : nullptr;
}
#endif

// FEX raises guest exceptions as host signals:
// - ud2 and int3 jump to a dispatcher stub that stores all guest registers in
//   the thread's state, with rip already set, and traps: hlt #0 (SIGILL) or
//   brk #0 (SIGTRAP).
// - A guest memory access that faults traps inside the translated block
//   (SIGSEGV, SIGBUS on Darwin), with guest registers still in host registers.
// The probe then runs the guest's handler, a much simplified Windows exception
// dispatch: rip = handler, rdi = x86 trap number, rsi = guest rip (of the
// instruction, after it for int3), rdx = fault address, other registers as they
// were. The faulting code is never resumed, so the host continues at the
// dispatcher's loop top on its outermost stack frame.
void OnHostSignal(int Signal, siginfo_t* Info, void* UContext) {
  auto* U = static_cast<ucontext_t*>(UContext);
  auto* Frame = ExceptionThread ? ExceptionThread->CurrentFrame : nullptr;
  const auto& Config = Signals->GetConfig();
  const uint64_t PC = HostPc(U);
  uint64_t TrapNo;
  uint64_t FaultAddress = 0;
  if (!Frame || !GuestExceptionHandler) {
    TrapNo = ~uint64_t {0};
  } else if ((Signal == SIGILL || Signal == SIGTRAP) && Frame->SynchronousFaultData.FaultToTopAndGeneratedException &&
             PC >= Config.DispatcherBegin && PC < Config.DispatcherEnd) {
    TrapNo = Frame->SynchronousFaultData.TrapNo;
    Frame->SynchronousFaultData.FaultToTopAndGeneratedException = false;
  } else if ((Signal == SIGSEGV || Signal == SIGBUS) && ExceptionCTX->IsAddressInCodeBuffer(ExceptionThread, PC)) {
    auto& State = Frame->State;
    for (size_t i = 0; i < Config.SRAGPRCount; ++i) {
      State.gregs[i] = HostX(U, Config.SRAGPRMapping[i]);
    }
    if (const auto* V = HostV(U)) {
      for (size_t i = 0; i < Config.SRAFPRCount; ++i) {
        memcpy(&State.xmm.sse.data[i][0], &V[Config.SRAFPRMapping[i]], sizeof(__uint128_t));
      }
    }
    State.rip = ExceptionCTX->RestoreRIPFromHostPC(ExceptionThread, PC);
    TrapNo = 14; // #PF
    FaultAddress = reinterpret_cast<uint64_t>(Info->si_addr);
  } else {
    TrapNo = ~uint64_t {0};
  }
  if (TrapNo == ~uint64_t {0}) {
    // Not the guest's: crash the way the process would have without us.
    signal(Signal, SIG_DFL);
    return;
  }

  auto& State = Frame->State;
  State.gregs[FEXCore::X86State::REG_RDI] = TrapNo;
  State.gregs[FEXCore::X86State::REG_RSI] = State.rip;
  State.gregs[FEXCore::X86State::REG_RDX] = FaultAddress;
  State.rip = GuestExceptionHandler;
  HostPc(U) = Config.AbsoluteLoopTopAddressFillSRA;
  HostSp(U) = Frame->ReturningStackLocation;
  HostX(U, 1) = 0; // ENTRY_FILL_SRA_SINGLE_INST_REG: a normal block, not one instruction
}

bool InstallSignalHandlers() {
  struct sigaction Action {};
  Action.sa_sigaction = OnHostSignal;
  Action.sa_flags = SA_SIGINFO;
  sigemptyset(&Action.sa_mask);
  for (int Signal : {SIGILL, SIGTRAP, SIGSEGV, SIGBUS}) {
    if (sigaction(Signal, &Action, nullptr) != 0) {
      perror("sigaction");
      return false;
    }
  }
#ifdef __APPLE__
  // Under a debugger (Xcode) these faults stop in the debugger first. Hand
  // them straight to the signal handlers instead.
  task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_BREAKPOINT, MACH_PORT_NULL,
                           EXCEPTION_DEFAULT, THREAD_STATE_NONE);
#endif
  return true;
}

class ProbeSyscallHandler final : public FEXCore::HLE::SyscallHandler, public FEXCore::CodeMapOpener {
public:
  ProbeSyscallHandler(const FEXCore::ExecutableFileInfo& FileInfo, uintptr_t Base, size_t Size, const char* CodeMapPath)
    : FileInfo(FileInfo)
    , Base(Base)
    , Size(Size)
    , CodeMapPath(CodeMapPath) {}

  void HandleSyscall(FEXCore::Core::CpuStateFrame* Frame) override {
    auto& Regs = Frame->State.gregs;
    if (Regs[FEXCore::X86State::REG_RAX] == 1 && Regs[FEXCore::X86State::REG_RDI] == 1) {
      // write(1, buf, len); the buffer is guest memory, which is host memory here
      auto* Buf = reinterpret_cast<const char*>(Regs[FEXCore::X86State::REG_RSI]);
      Output.append(Buf, Regs[FEXCore::X86State::REG_RDX]);
      Regs[FEXCore::X86State::REG_RAX] = Regs[FEXCore::X86State::REG_RDX];
    } else if (Regs[FEXCore::X86State::REG_RAX] == 0x5750) {
      // WinPad probe: set the exception handler to rdi
      GuestExceptionHandler = Regs[FEXCore::X86State::REG_RDI];
      Regs[FEXCore::X86State::REG_RAX] = 0;
    } else {
      Regs[FEXCore::X86State::REG_RAX] = -ENOSYS;
    }
    // The handler moves the guest past its 2-byte syscall instruction.
    Frame->State.rip += 2;
  }

  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    if (Contains(Address)) {
      return {Base, Size, false};
    }
    return {0, 0, false};
  }

  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    if (!Contains(Address)) {
      return std::nullopt;
    }
    return Section();
  }

  FEXCore::ExecutableFileSectionInfo Section() const {
    return FEXCore::ExecutableFileSectionInfo {FileInfo, Base, Base, Base + Size};
  }

  int OpenCodeMapFile() override {
    return CodeMapPath ? open(CodeMapPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644) : -1;
  }

private:
  bool Contains(uint64_t Address) const {
    return Address >= Base && Address < Base + Size;
  }

  const FEXCore::ExecutableFileInfo& FileInfo;
  uintptr_t Base;
  size_t Size;
  const char* CodeMapPath;
};

// Same GDT setup as FEXOfflineCompiler's compile thread: flat 64-bit code segment.
FEXCore::Core::CPUState::gdt_segment GDT[32] {};

void SetupThreadState(FEXCore::Core::InternalThreadState* Thread) {
  auto& State = Thread->CurrentFrame->State;
  State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = &GDT[0];
  State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = &GDT[0];
  State.cs_idx = FEXCore::Core::CPUState::DEFAULT_USER_CS << 3;
  auto* CS = FEXCore::Core::CPUState::GetSegmentFromIndex(State, State.cs_idx);
  FEXCore::Core::CPUState::SetGDTBase(CS, 0);
  FEXCore::Core::CPUState::SetGDTLimit(CS, 0xFFFFFU);
  CS->L = 1;
  CS->D = 0;
  State.cs_cached = FEXCore::Core::CPUState::CalculateGDTBase(*CS);
}

uint8_t* MapGuest(uintptr_t Hint, size_t Size) {
  void* P = mmap(reinterpret_cast<void*>(Hint), Size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (P == MAP_FAILED) {
    perror("mmap");
    return nullptr;
  }
  if (reinterpret_cast<uintptr_t>(P) + Size > (uintptr_t {1} << 47)) {
    fprintf(stderr, "guest memory at %p is outside the x86-64 address space\n", P);
    return nullptr;
  }
  return static_cast<uint8_t*>(P);
}

// The JIT keeps a stack of guest return addresses next to the guest stack
// (State.callret_sp, x25 in JIT code), which a frontend has to provide, the
// way FEX's ThreadManager does: guard pages on both sides, starting a quarter
// in so that a few returns more than calls are harmless.
bool SetupCallRetStack(FEXCore::Core::InternalThreadState* Thread) {
  const size_t Page = sysconf(_SC_PAGESIZE);
  const size_t Size = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
  auto* Alloc = static_cast<uint8_t*>(mmap(nullptr, Size + 2 * Page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
  if (Alloc == MAP_FAILED || mprotect(Alloc + Page, Size, PROT_READ | PROT_WRITE) != 0) {
    perror("call-ret stack");
    return false;
  }
  Thread->CallRetStackBase = Alloc + Page;
  Thread->CurrentFrame->State.callret_sp = reinterpret_cast<uintptr_t>(Alloc + Page) + Size / 4;
  return true;
}

int Usage() {
  fprintf(stderr, "usage: winpad-probe record CODEMAP | generate CODEMAP DIR | run IMAGE\n");
  return 2;
}
} // namespace

// The iOS test app (tests/ios/app) links this file with WINPAD_PROBE_LIBRARY
// and calls WinPadProbeMain itself.
int WinPadProbeMain(int argc, char** argv) {
  if (argc < 3) {
    return Usage();
  }
  const std::string Mode = argv[1];
  const bool Record = Mode == "record";
  const bool Generate = Mode == "generate" && argc == 4;
  const bool Run = Mode == "run";
  if (!Record && !Generate && !Run) {
    return Usage();
  }

  LogMan::Throw::InstallHandler(AssertHandler);
  LogMan::Msg::InstallHandler(MsgHandler);

  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
  fextl::string DispatcherPath;
  if (Generate) {
    // NoJIT here too: compiling a cache needs no executable memory either
    // (patch 0010), so a Mac can make the image for an iPad.
    FEXCore::Config::Set(FEXCore::Config::CONFIG_NOJIT, "1");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_AOTCODECACHEWIP, "1");
    DispatcherPath = fextl::fmt::format("{}/dispatcher.bin", argv[3]);
    FEXCore::Config::Set(FEXCore::Config::CONFIG_DUMPDISPATCHER, DispatcherPath);
  }
  if (Run) {
    FEXCore::Config::Set(FEXCore::Config::CONFIG_ENABLECODECACHINGWIP, "1");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_AOTIMAGE, argv[2]);
    FEXCore::Config::Set(FEXCore::Config::CONFIG_NOJIT, "1");
  }

  // The guest: its bytes plus a stack. x86-64 addresses only have 47 bits, and
  // mmap on ARM64 Linux hands out addresses above that by default, so ask for
  // low ones; the hints are free on both Linux and iOS (above its 4 GB
  // page zero) and only a hint, so any address under the limit will do.
  const size_t GuestSize = (sizeof(GuestCode) + 4095) & ~size_t {4095};
  auto* Guest = MapGuest(0x2'0000'0000, GuestSize);
  auto* Stack = MapGuest(0x2'1000'0000, StackSize);
  if (!Guest || !Stack) {
    return 1;
  }
  memcpy(Guest, GuestCode, sizeof(GuestCode));
  const auto Base = reinterpret_cast<uintptr_t>(Guest);

  FEXCore::ExecutableFileInfo FileInfo {nullptr, GuestFileId, "winpad-probe-guest"};
  ProbeSyscallHandler Syscalls {FileInfo, Base, GuestSize, Record ? argv[2] : nullptr};
  ProbeSignalDelegator Delegator;
  Signals = &Delegator;

  auto CTX = FEXCore::Context::Context::CreateNewContext(BaselineFeatures());
  if (Generate) {
    CTX->GetCodeCache().InitiateCacheGeneration();
  }
  CTX->SetSignalDelegator(&Delegator);
  CTX->SetSyscallHandler(&Syscalls);
  CTX->EnableExitOnHLT();
  if (!CTX->InitCore()) {
    fprintf(stderr, "InitCore failed\n");
    return 1;
  }

  auto* Thread = CTX->CreateThread();
  SetupThreadState(Thread);
  if (!SetupCallRetStack(Thread)) {
    return 1;
  }

  if (Generate) {
    std::ifstream MapFile {argv[2], std::ios::binary};
    auto Maps = FEXCore::CodeMap::ParseCodeMap(MapFile);
    auto It = Maps.find(GuestFileId);
    if (It == Maps.end() || It->second.Blocks.empty()) {
      fprintf(stderr, "code map %s has no blocks of the guest\n", argv[2]);
      return 1;
    }
    FEX_CONFIG_OPT(MaxInst, MAXINST);
    size_t Compiled = 0;
    for (auto Offset : It->second.Blocks) {
      if (CTX->CheckIfBlockIsCacheable(*Thread, Base + Offset, MaxInst)) {
        CTX->CompileRIP(Thread, Base + Offset);
        ++Compiled;
      }
    }
    auto CachePath = fextl::fmt::format("{}/winpad-probe-guest-{:016x}-{:016x}", argv[3], GuestFileId, CodeCacheConfigId);
    int FD = open(CachePath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (FD == -1 || !CTX->GetCodeCache().SaveData(*Thread, FD, Syscalls.Section(), 0)) {
      fprintf(stderr, "failed to write %s\n", CachePath.c_str());
      return 1;
    }
    close(FD);
    printf("cached %zu of %zu blocks in %s\n", Compiled, It->second.Blocks.size(), CachePath.c_str());
    CTX->DestroyThread(Thread);
    return 0;
  }

  fextl::unique_ptr<FEXCore::MappedCodeCacheFile> Cache;
  if (Record) {
    CTX->SetCodeMapWriter(fextl::make_unique<FEXCore::CodeMapWriter>(Syscalls));
  } else {
    void* Image = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!Image) {
      fprintf(stderr, "dlopen %s: %s\n", argv[2], dlerror());
      return 1;
    }
    auto Prefix = fextl::fmt::format("fexaot_{:016x}_{:016x}", GuestFileId, CodeCacheConfigId);
    auto* Meta = dlsym(Image, (Prefix + "_meta").c_str());
    auto* Code = dlsym(Image, (Prefix + "_text").c_str());
    auto* Data = dlsym(Image, (Prefix + "_data").c_str());
    if (!Meta || !Code || !Data) {
      fprintf(stderr, "%s has no code for %s\n", argv[2], Prefix.c_str());
      return 1;
    }
    Cache = CTX->GetCodeCache().LoadLinkedCache(static_cast<const std::byte*>(Meta), static_cast<std::byte*>(Code),
                                                static_cast<std::byte*>(Data), FileInfo, Base);
    if (!Cache) {
      fprintf(stderr, "FEX did not accept the AOT image\n");
      return 1;
    }
    CTX->GetCodeCache().RegisterMappedCodeBuffer(*Cache);
    CTX->GetCodeCache().EnableLoadedSection(Thread, *Cache, Syscalls.Section());
  }

  ExceptionCTX = CTX.get();
  ExceptionThread = Thread;
  if (!InstallSignalHandlers()) {
    return 1;
  }
  auto& State = Thread->CurrentFrame->State;
  State.rip = Base;
  State.gregs[FEXCore::X86State::REG_RSP] = reinterpret_cast<uintptr_t>(Stack) + StackSize - 64;
  CTX->ExecuteThread(Thread);

  if (Record) {
    CTX->FlushAndCloseCodeMap();
  }
  const auto R12 = State.gregs[FEXCore::X86State::REG_R12];
  // r13: the guest's check that ran last (guest.S), 9 when all passed
  const auto R13 = State.gregs[FEXCore::X86State::REG_R13];
  printf("guest wrote \"%s\", r12=%llu, r13=%llu\n", Output == "ok\n" ? "ok\\n" : Output.c_str(),
         static_cast<unsigned long long>(R12), static_cast<unsigned long long>(R13));
  Cache.reset();
  CTX->DestroyThread(Thread);
  return Output == "ok\n" ? 0 : 1;
}

#ifndef WINPAD_PROBE_LIBRARY
int main(int argc, char** argv) {
  return WinPadProbeMain(argc, argv);
}
#endif

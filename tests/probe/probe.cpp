// SPDX-License-Identifier: MIT
// WinPad probe: the smallest FEXCore frontend that runs one x86-64 program
// (guest.S) without FEX's Linux emulation layer, so the same code can run in
// an iOS app. The guest is mapped at whatever address mmap returns and only
// needs the write syscall; it stops with HLT.
//
// Modes (each one process, as they would be on a build machine and a device):
//   record CODEMAP          run with the JIT and record the executed blocks
//   generate CODEMAP DIR    compile the recorded blocks into an AOT code cache
//                           in DIR and write FEX's dispatcher to DIR/dispatcher.bin
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
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <fstream>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

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
      return;
    }
    Regs[FEXCore::X86State::REG_RAX] = -ENOSYS;
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

int Usage() {
  fprintf(stderr, "usage: winpad-probe record CODEMAP | generate CODEMAP DIR | run IMAGE\n");
  return 2;
}
} // namespace

int main(int argc, char** argv) {
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
    FEXCore::Config::Set(FEXCore::Config::CONFIG_AOTCODECACHEWIP, "1");
    DispatcherPath = fextl::fmt::format("{}/dispatcher.bin", argv[3]);
    FEXCore::Config::Set(FEXCore::Config::CONFIG_DUMPDISPATCHER, DispatcherPath);
  }
  if (Run) {
    FEXCore::Config::Set(FEXCore::Config::CONFIG_ENABLECODECACHINGWIP, "1");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_AOTIMAGE, argv[2]);
    FEXCore::Config::Set(FEXCore::Config::CONFIG_NOJIT, "1");
  }

  // The guest: its bytes at an address the system picks, plus a stack.
  const size_t GuestSize = (sizeof(GuestCode) + 4095) & ~size_t {4095};
  auto* Guest = static_cast<uint8_t*>(mmap(nullptr, GuestSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
  auto* Stack = static_cast<uint8_t*>(mmap(nullptr, StackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
  if (Guest == MAP_FAILED || Stack == MAP_FAILED) {
    perror("mmap");
    return 1;
  }
  memcpy(Guest, GuestCode, sizeof(GuestCode));
  const auto Base = reinterpret_cast<uintptr_t>(Guest);

  FEXCore::ExecutableFileInfo FileInfo {nullptr, GuestFileId, "winpad-probe-guest"};
  ProbeSyscallHandler Syscalls {FileInfo, Base, GuestSize, Record ? argv[2] : nullptr};
  ProbeSignalDelegator Signals;

  auto CTX = FEXCore::Context::Context::CreateNewContext(BaselineFeatures());
  if (Generate) {
    CTX->GetCodeCache().InitiateCacheGeneration();
  }
  CTX->SetSignalDelegator(&Signals);
  CTX->SetSyscallHandler(&Syscalls);
  CTX->EnableExitOnHLT();
  if (!CTX->InitCore()) {
    fprintf(stderr, "InitCore failed\n");
    return 1;
  }

  auto* Thread = CTX->CreateThread();
  SetupThreadState(Thread);

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

  auto& State = Thread->CurrentFrame->State;
  State.rip = Base;
  State.gregs[FEXCore::X86State::REG_RSP] = reinterpret_cast<uintptr_t>(Stack) + StackSize - 64;
  CTX->ExecuteThread(Thread);

  if (Record) {
    CTX->FlushAndCloseCodeMap();
  }
  const auto R12 = State.gregs[FEXCore::X86State::REG_R12];
  printf("guest wrote \"%s\", r12=%llu\n", Output == "ok\n" ? "ok\\n" : Output.c_str(), static_cast<unsigned long long>(R12));
  Cache.reset();
  CTX->DestroyThread(Thread);
  return Output == "ok\n" ? 0 : 1;
}

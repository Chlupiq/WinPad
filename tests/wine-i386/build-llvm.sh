#!/bin/sh
# Builds LLVM 15.0.7 as static libraries for SDK, the LLVM that DXMT's shader
# compiler (airconv) links into the app: Madeira's docs/BUILDING.md recipe
# for toolchains/llvm-ios-build (no targets, no tools, no zlib), with the
# one-line AddLLVM.cmake edit of build/dxmt-ios/README.md (iOS links with
# -dead_strip like Darwin). llvm-tblgen is built for the Mac first and the
# iOS build reuses it. Only the libraries airconv links are built
# (dxmt/src/airconv/meson.build, llvm_deps).
#
# Usage: build-llvm.sh ROOT SDK   (SDK: iphoneos or iphonesimulator)
# Output: ROOT/toolchains/llvm-project (the sources, llvm/include is needed)
# and ROOT/toolchains/llvm-ios-build/{include,lib}, the layout Madeira's
# build/dxmt-ios/build.sh expects. Needs cmake and ninja.
set -eu

root=$1
sdk_name=$2
tc="$root/toolchains"
src="$tc/llvm-project"
out="$tc/llvm-ios-build"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
case $sdk_name in
    iphoneos) triple=arm64-apple-ios17.0 ;;
    iphonesimulator) triple=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac

libs="LLVMPasses LLVMTarget LLVMObjCARCOpts LLVMCoroutines LLVMipo LLVMInstrumentation
    LLVMVectorize LLVMLinker LLVMIRReader LLVMAsmParser LLVMFrontendOpenMP LLVMScalarOpts
    LLVMInstCombine LLVMAggressiveInstCombine LLVMTransformUtils LLVMBitWriter LLVMAnalysis
    LLVMProfileData LLVMSymbolize LLVMDebugInfoPDB LLVMDebugInfoMSF LLVMDebugInfoDWARF
    LLVMObject LLVMTextAPI LLVMMCParser LLVMMC LLVMDebugInfoCodeView LLVMBitReader LLVMCore
    LLVMRemarks LLVMBitstreamReader LLVMBinaryFormat LLVMSupport LLVMDemangle"

if [ -f "$out/lib/libLLVMSupport.a" ] && [ -f "$out/include/llvm/Config/llvm-config.h" ]; then
    echo "LLVM for $sdk_name already built: $out"
    exit 0
fi

mkdir -p "$tc"
if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" sparse-checkout set --no-cone /llvm/ '!/llvm/test/' '!/llvm/unittests/' /cmake/ /third-party/
    git -C "$src" fetch -q --depth 1 --filter=blob:none https://github.com/llvm/llvm-project.git \
        refs/tags/llvmorg-15.0.7
    git -C "$src" checkout -q FETCH_HEAD
fi
# The if() right above the -dead_strip flag (add_link_opts).
sed -i '' 's/^      if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin")$/      if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin|iOS")/' \
    "$src/llvm/cmake/modules/AddLLVM.cmake"

host="$tc/llvm-host-build"
if [ ! -x "$host/bin/llvm-tblgen" ]; then
    cmake -G Ninja -S "$src/llvm" -B "$host" -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_LIBXML2=Off >"$tc/llvm-host.log" 2>&1 &&
        ninja -C "$host" -j"$jobs" llvm-tblgen >>"$tc/llvm-host.log" 2>&1 ||
        { tail -40 "$tc/llvm-host.log" >&2; exit 1; }
fi

b="$tc/llvm-$sdk_name-objs"
cmake -G Ninja -S "$src/llvm" -B "$b" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$sdk_name" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DLLVM_HOST_TRIPLE="$triple" -DLLVM_DEFAULT_TARGET_TRIPLE="$triple" -DLLVM_TARGET_ARCH=host \
    -DLLVM_TABLEGEN="$host/bin/llvm-tblgen" \
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
    -DLLVM_INCLUDE_UTILS=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off \
    -DLLVM_ENABLE_LIBXML2=Off -DLLVM_ENABLE_TERMINFO=Off >"$tc/llvm-$sdk_name.log" 2>&1 ||
    { tail -40 "$tc/llvm-$sdk_name.log" >&2; exit 1; }
# shellcheck disable=SC2086 # a list of targets
ninja -C "$b" -j"$jobs" $libs >>"$tc/llvm-$sdk_name.log" 2>&1 || { tail -40 "$tc/llvm-$sdk_name.log" >&2; exit 1; }

# Only the generated headers and the libraries are kept (and the sources,
# for llvm/include).
rm -rf "$out"
mkdir -p "$out/lib"
cp -R "$b/include" "$out/include"
cp "$b"/lib/libLLVM*.a "$out/lib/"
rm -rf "$b" "$host"
ls "$out/lib"
echo "LLVM 15.0.7 for $sdk_name: $out"

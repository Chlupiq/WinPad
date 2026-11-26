# Sourced by the build scripts: the Apple platform an SDK name stands for.
# In: sdk_name (iphoneos, iphonesimulator or maccatalyst).
# Out: target (clang's), xcsdk (xcrun's SDK name), sdk (its path) and
# sdk_flags (what else that platform needs on clang's command line).
# Mac Catalyst is the iPad app as a Mac app: iOS code built against the
# macOS SDK with its iOSSupport frameworks (UIKit and the rest).
case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 xcsdk=iphoneos ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator xcsdk=iphonesimulator ;;
    maccatalyst) target=arm64-apple-ios17.0-macabi xcsdk=macosx ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$xcsdk" --show-sdk-path)
sdk_flags=
if [ "$sdk_name" = maccatalyst ]; then
    sdk_flags="-iframework $sdk/System/iOSSupport/System/Library/Frameworks -isystem $sdk/System/iOSSupport/usr/include"
fi

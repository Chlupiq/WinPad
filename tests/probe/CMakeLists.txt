# Built inside FEX's CMake project (patches/fex/0009): configure FEX with
# -DWINPAD_PROBE_DIR=<this directory> and build the winpad-probe target.
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/guest.o
  COMMAND ${CMAKE_C_COMPILER} --target=x86_64-linux-gnu -c -o ${CMAKE_CURRENT_BINARY_DIR}/guest.o ${CMAKE_CURRENT_SOURCE_DIR}/guest.S
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/guest.S
  VERBATIM)
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/guest.h
  COMMAND python3 -I ${CMAKE_CURRENT_SOURCE_DIR}/elf2h.py ${CMAKE_CURRENT_BINARY_DIR}/guest.o ${CMAKE_CURRENT_BINARY_DIR}/guest.h
  DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/guest.o ${CMAKE_CURRENT_SOURCE_DIR}/elf2h.py
  VERBATIM)

if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # The iPad test app's executable (tests/ios/app); tests/ios/build-app.sh
  # puts it in an app bundle.
  enable_language(OBJCXX)
  set(app ${CMAKE_CURRENT_SOURCE_DIR}/../ios/app)
  # The probe is its own library so tests/ios/build-xcode.sh can hand it,
  # with the FEXCore libraries, to an Xcode project.
  add_library(WinPadProbeCore STATIC probe.cpp ${CMAKE_CURRENT_BINARY_DIR}/guest.h)
  target_compile_definitions(WinPadProbeCore PRIVATE WINPAD_PROBE_LIBRARY)
  target_include_directories(WinPadProbeCore PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(WinPadProbeCore PUBLIC FEXCore FEXCore_Base JemallocDummy)
  add_executable(WinPadProbe ${app}/main.mm)
  target_compile_options(WinPadProbe PRIVATE -fobjc-arc)
  target_link_libraries(WinPadProbe PRIVATE WinPadProbeCore "-framework UIKit" "-framework Foundation")
else()
  add_executable(winpad-probe probe.cpp ${CMAKE_CURRENT_BINARY_DIR}/guest.h)
  target_include_directories(winpad-probe PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(winpad-probe PRIVATE FEXCore FEXCore_Base JemallocDummy ${CMAKE_DL_LIBS})
endif()

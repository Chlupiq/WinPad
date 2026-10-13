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

add_executable(winpad-probe probe.cpp ${CMAKE_CURRENT_BINARY_DIR}/guest.h)
target_include_directories(winpad-probe PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(winpad-probe PRIVATE FEXCore FEXCore_Base JemallocDummy ${CMAKE_DL_LIBS})

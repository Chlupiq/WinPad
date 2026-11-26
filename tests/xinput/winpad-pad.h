/* SPDX-License-Identifier: MIT
 * The controller state the app (tests/wine-app/main.m) writes for winpad-xinput.dll: the
 * first 64 bytes of a small file (WINPAD_PAD_FILE, its Windows path), rewritten whenever a
 * controller or the touch controller changes. seq is odd while the app writes and bumped
 * again after, so the DLL reads until it sees the same even seq before and after. */
#ifndef WINPAD_PAD_H
#define WINPAD_PAD_H

#include <stdint.h>

#define WINPAD_PAD_MAGIC 0x44505057u /* "WPPD" */

struct winpad_pad {
  uint32_t magic;
  uint32_t seq;       /* odd while being written */
  uint32_t connected; /* a controller (or the touch controller) is there */
  uint32_t packet;    /* XInput's dwPacketNumber: bumped on every change */
  uint16_t buttons;   /* XINPUT_GAMEPAD_* */
  uint8_t left_trigger, right_trigger;
  int16_t thumb_lx, thumb_ly, thumb_rx, thumb_ry;
  uint32_t seq_end;   /* = seq once written */
};

#endif

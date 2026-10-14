# Prints a 32-bit BMP that winehost wrote (a window's content) as text, so a
# CI log shows what the window drew: one character per cell, darker is denser.
# Usage: python3 bmp-preview.py FILE.bmp [COLUMNS]
import struct
import sys

data = open(sys.argv[1], "rb").read()
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 64
offset, = struct.unpack_from("<I", data, 10)
width, height = struct.unpack_from("<ii", data, 18)
top_down = height < 0
height = abs(height)


def pixel(x, y):
    row = y if top_down else height - 1 - y
    b, g, r = data[offset + (row * width + x) * 4:offset + (row * width + x) * 4 + 3]
    return r, g, b


colors = {pixel(x, y) for y in range(height) for x in range(width)}
print(f"{width}x{height}, {len(colors)} colors")
ramp = "@%#*+=-:. "
rows = max(1, cols * height // width // 2)
for j in range(rows):
    line = ""
    for i in range(cols):
        x0, x1 = i * width // cols, max(i * width // cols + 1, (i + 1) * width // cols)
        y0, y1 = j * height // rows, max(j * height // rows + 1, (j + 1) * height // rows)
        lum = [0.299 * r + 0.587 * g + 0.114 * b
               for y in range(y0, y1) for x in range(x0, x1) for r, g, b in [pixel(x, y)]]
        line += ramp[min(len(ramp) - 1, int(sum(lum) / len(lum) / 256 * len(ramp)))]
    print(line)

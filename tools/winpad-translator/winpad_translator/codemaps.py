"""Code maps: gathering them into a cache directory and making their image names open here.

A FEX code map names each image it holds blocks of by the path the run saw:
the iPad app's runs name the game's files under the app's Documents/FOLDER and
Wine's DLLs under C:\\windows\\syswow64. FEX's offline compiler opens the images by
those names, so before it runs every name has to point at the same file on
this computer: the game's folder here, and the i386 DLLs of the same WinPad
Wine build the iPad has (from its IPA). Format: tests/fex-wow64/codemap.py.
"""
import os
import re
import shutil
import struct

from . import paths  # noqa: F401  (puts tests/fex-wow64 on sys.path)
import codemap  # noqa: E402

ENTRY, LIBRARY, SET_MAIN, parse = codemap.ENTRY, codemap.LIBRARY, codemap.SET_MAIN, codemap.parse
HALF_BARRIER = codemap.HALF_BARRIER

IPAD_DOCUMENTS = re.compile(
    r"^\\\?\?\\Z:\\(?:private\\)?var\\mobile\\Containers\\Data\\Application\\[^\\]+\\Documents\\([^\\]+)\\(.+)$",
    re.IGNORECASE)
SYSTEM_PATH = re.compile(r"\\windows\\(?:syswow64|system32)\\|\\i386-windows\\", re.IGNORECASE)


def slug(folder):
    """The name the app's game library gives a game folder's image: fexaot-<slug>.dylib (Library.m)."""
    out, dash = [], False
    for c in folder.lower():
        if "a" <= c <= "z" or "0" <= c <= "9":
            if dash and out:
                out.append("-")
            dash = False
            out.append(c)
        else:
            dash = True
    return "".join(out)


# A new code map is ID.TIME.bin (ImageTracker); a ready one, merged by the offline
# compiler, is named after its image: NAME-FILEID.
READY_MAP = re.compile(r"-[0-9a-f]{16}$")


def map_files(folder):
    """Every non-empty code map under FOLDER, new or ready (the runtime/ code ranges are not maps)."""
    found = []
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames[:] = sorted(d for d in dirnames if d != "runtime" and not d.startswith("."))
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if ((name.endswith(".bin") or READY_MAP.search(name)) and not name.startswith(".")
                    and os.path.getsize(path) > 0):
                found.append(path)
    return found


def import_maps(source, cache_dir, tag):
    """Copies the code maps under SOURCE (an iPad's codemap/new, copied off it) and the
    runtime code ranges next to them into CACHE_DIR/codemap/new. Returns how many maps."""
    new = os.path.join(cache_dir, "codemap", "new")
    os.makedirs(new, exist_ok=True)
    maps = map_files(source)
    for i, path in enumerate(maps):
        # The compiler only takes *.bin from codemap/new.
        name = os.path.basename(path)
        name = name if name.endswith(".bin") else name + ".bin"
        shutil.copyfile(path, os.path.join(new, f"{tag}-{i:04d}-{name}"))
    # The bytes of code the game made at run time, which those maps hold blocks of
    # (patches/fex-wow64/0036).
    for dirpath, _, filenames in os.walk(source):
        if os.path.basename(dirpath) != "runtime":
            continue
        os.makedirs(os.path.join(new, "runtime"), exist_ok=True)
        for name in filenames:
            shutil.copyfile(os.path.join(dirpath, name), os.path.join(new, "runtime", name))
    return len(maps)


def records(data):
    """Yields (kind, start, end, value) for each record of a map: kind "image" with
    (file id, name), "main" with the file id, "block" with (file id, offset)."""
    pos = 0
    while pos + ENTRY.size <= len(data):
        entry = ENTRY.unpack_from(data, pos)
        if entry == LIBRARY:
            (file_id,) = struct.unpack_from("<Q", data, pos + ENTRY.size)
            start = pos + ENTRY.size + 8
            end = data.index(b"\0", start)
            nxt = (end + 1 + 3) & ~3
            yield "image", pos, nxt, (file_id, data[start:end].decode("utf-8", "replace"))
            pos = nxt
        elif entry == SET_MAIN:
            (file_id,) = struct.unpack_from("<Q", data, pos + ENTRY.size)
            yield "main", pos, pos + ENTRY.size + 8, file_id
            pos += ENTRY.size + 8
        else:
            yield "block", pos, pos + ENTRY.size, entry
            pos += ENTRY.size


def image_record(file_id, name):
    record = ENTRY.pack(*LIBRARY) + struct.pack("<Q", file_id) + name.encode("utf-8") + b"\0"
    return record + b"\0" * (-len(record) % 4)


def summary(maps):
    """(image names by file id, blocks per file id, main executable's file id or None)."""
    names, blocks, main = {}, {}, None
    for path in maps:
        with open(path, "rb") as f:
            n, b, m, _ = parse(f.read())
        names.update(n)
        for file_id, offsets in b.items():
            blocks.setdefault(file_id, set()).update(o & ~HALF_BARRIER for o in offsets)
        main = main if m is None else m
    return names, blocks, main


def ipad_folders(names):
    """The Documents folders of the iPad app the maps' images came from."""
    return sorted({m.group(1) for m in (IPAD_DOCUMENTS.match(n) for n in names) if m})


def basename(name):
    return name.replace("/", "\\").rsplit("\\", 1)[-1]


def pe_file_id(path):
    """FEX's code map file id of a PE file (ImageTracker's ComputeCodeMapId), or None
    without the xxhash package or for a file that is no PE image."""
    try:
        import xxhash
    except ImportError:
        return None
    with open(path, "rb") as f:
        head = f.read(4096)
    if len(head) < 64 or head[:2] != b"MZ":
        return None
    nt = struct.unpack_from("<I", head, 0x3C)[0]
    if nt + 0x58 > len(head) or head[nt:nt + 4] != b"PE\0\0":
        return None
    stamp = struct.unpack_from("<I", head, nt + 8)[0]
    size_of_image = struct.unpack_from("<I", head, nt + 24 + 56)[0]
    return xxhash.xxh3_64_intdigest(os.path.basename(path).lower().encode("utf-8")) ^ (size_of_image << 32 | stamp)


def find_ci(folder, relative):
    """FOLDER/RELATIVE with each component matched without regard to case (the iPad's
    volume is case-sensitive, a Mac's or a PC's usually not), or None."""
    path = folder
    for part in relative.replace("\\", "/").split("/"):
        if not part:
            continue
        exact = os.path.join(path, part)
        if os.path.exists(exact):
            path = exact
            continue
        try:
            hit = [n for n in os.listdir(path) if n.lower() == part.lower()]
        except OSError:
            return None
        if not hit:
            return None
        path = os.path.join(path, hit[0])
    return path


class Resolver:
    """Finds the file on this computer each image name of a code map stands for."""

    def __init__(self, game_dir, ipad_folder=None, system_dir=None):
        self.game_dir = game_dir
        self.ipad_folder = ipad_folder or os.path.basename(os.path.normpath(game_dir))
        self.system_dir = system_dir
        self._game_files = None

    def _in_game(self, base):
        if self._game_files is None:
            self._game_files = {}
            for dirpath, _, filenames in os.walk(self.game_dir):
                for n in filenames:
                    self._game_files.setdefault(n.lower(), []).append(os.path.join(dirpath, n))
        hits = self._game_files.get(base.lower(), [])
        return hits[0] if len(hits) == 1 else None

    def _in_system(self, base):
        return find_ci(self.system_dir, base) if self.system_dir else None

    @staticmethod
    def local_path(name):
        """The path a Wine or Windows name means here, if this computer has it."""
        n = name[4:] if name.startswith("\\??\\") else name
        if os.name == "nt":
            return n if re.match(r"^[A-Za-z]:\\", n) and os.path.exists(n) else None
        if n[:3].upper() == "Z:\\":
            p = "/" + n[3:].replace("\\", "/")
            return p if os.path.exists(p) else None
        return None

    def resolve(self, name):
        """Returns (local path or None, how it was found)."""
        m = IPAD_DOCUMENTS.match(name)
        if m and m.group(1).lower() == self.ipad_folder.lower():
            hit = find_ci(self.game_dir, m.group(2))
            return (hit, "game folder") if hit else (None, f"not in the game folder: {m.group(2)}")
        base = basename(name)
        # Before the name itself: on a Windows PC C:\windows\syswow64 holds Microsoft's DLLs,
        # not the Wine ones the iPad ran.
        if SYSTEM_PATH.search(name):
            hit = self._in_system(base)
            if hit:
                return hit, "WinPad Wine's i386 DLLs"
        local = self.local_path(name)
        if local:
            return local, "as named"
        hit = self._in_game(base)
        if hit:
            return hit, "game folder"
        hit = self._in_system(base)
        if hit:
            return hit, "WinPad Wine's i386 DLLs"
        return None, "not found"


def rehome(maps, resolver, to_name, keep=None, log=print):
    """Renames each image in MAPS to to_name(local path) of the file RESOLVER finds for it.
    keep(name) True leaves a name as it is (images the compiler's own Wine prefix has).
    Returns (renamed, missing names, file id mismatches)."""
    renamed, missing, mismatched, seen = 0, set(), set(), {}
    for path in maps:
        with open(path, "rb") as f:
            data = f.read()
        out, changed = bytearray(), False
        for kind, start, end, value in records(data):
            if kind != "image":
                out += data[start:end]
                continue
            file_id, name = value
            if name.endswith(".fexrc") or (keep and keep(name)):
                out += data[start:end]
                continue
            if name not in seen:
                seen[name] = resolver.resolve(name)
                local, how = seen[name]
                if local:
                    fid = pe_file_id(local)
                    if fid is not None and fid != file_id:
                        mismatched.add(name)
                        log(f"  ! {basename(name)}: {local} is not the file the run had (file id differs)")
                    else:
                        log(f"  {basename(name)} -> {local} ({how})")
                else:
                    missing.add(name)
                    log(f"  ! {name}: {how}")
            local = seen[name][0]
            new = to_name(local) if local else name
            if new != name:
                changed = True
                renamed += 1
            out += image_record(file_id, new)
        if changed:
            with open(path, "wb") as f:
                f.write(out + tail(data))
    return renamed, missing, mismatched


def tail(data):
    """Bytes after a map's last whole record (none in a clean map)."""
    last = 0
    for _, _, end, _ in records(data):
        last = end
    return data[last:]


def name_main(maps, main_name):
    """Puts MAIN_NAME's image record at the start of each map that sets the main
    executable without naming it (a run whose executable came wholly from caches;
    tests/fex-wow64/codemap-name-main.py)."""
    named = 0
    for path in maps:
        with open(path, "rb") as f:
            data = f.read()
        names, _, main_id, _ = parse(data)
        if main_id is None or main_id in names:
            continue
        with open(path, "wb") as f:
            f.write(image_record(main_id, main_name) + data)
        named += 1
    return named


def mark_half_barrier(maps):
    """Marks every block for a compile with plain loads and stores and half barriers
    (patches/fex-wow64/0030): an iPad faults on unaligned atomics the image would
    otherwise take, once per access."""
    marked = 0
    for path in maps:
        with open(path, "rb") as f:
            data = f.read()
        out = bytearray()
        for kind, start, end, value in records(data):
            if kind == "block":
                out += ENTRY.pack(value[0], value[1] | HALF_BARRIER)
                marked += 1
            else:
                out += data[start:end]
        with open(path, "wb") as f:
            f.write(out + tail(data))
    return marked

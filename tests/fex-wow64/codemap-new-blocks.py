"""Says which blocks of new FEX code maps the ready code maps lack yet.

A run with code caches loaded writes a new code map of the blocks it had to
compile. FEX's offline compiler merges those into the ready code maps
(codemap/ready/<image>) and builds caches from them. If every block of the
new maps is in the ready maps already, compiling again changes nothing: the
caches had those blocks and the run did not take them from there (or the
offline compiler left them out). This lists such blocks, with whether the
image's cache file (cache/<image>-<config id>) holds each one.

Usage: codemap-new-blocks.py CACHE_DIR NEW_MAP...   (CACHE_DIR holds codemap/
and cache/). Exits with 0 if the new maps have blocks the ready maps lack,
and with 1 if they do not.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
from codemap import parse  # noqa: E402

HEADER = struct.Struct("<4sI20sIIIIIQ")  # CodeCacheHeader, 56 bytes


def read_map(path):
    with open(path, "rb") as f:
        return parse(f.read())


def cached_blocks(path):
    """Guest offsets in a cache file's block list, or None if it does not parse."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        magic, _, _, num_blocks, *_ = HEADER.unpack_from(data, 0)
        if magic != b"FXCC":
            return None
        pos, found = HEADER.size, set()
        for _ in range(num_blocks):
            guest, _, pages = struct.unpack_from("<QQQ", data, pos)
            found.add(guest)
            pos += 24 + 8 * pages
        return found
    except (OSError, struct.error):
        return None


def main():
    cache_dir, new_maps = sys.argv[1], sys.argv[2:]
    ready_dir = os.path.join(cache_dir, "codemap", "ready")
    ready = {}  # file id -> (ready map name, blocks)
    for name in sorted(os.listdir(ready_dir)) if os.path.isdir(ready_dir) else []:
        _, blocks, _, _ = read_map(os.path.join(ready_dir, name))
        for file_id, offsets in blocks.items():
            ready[file_id] = (name, offsets)

    names, taken = {}, {}
    for path in new_maps:
        map_names, blocks, _, _ = read_map(path)
        names.update(map_names)
        for file_id, offsets in blocks.items():
            taken.setdefault(file_id, set()).update(offsets)

    new_total = 0
    for file_id, offsets in sorted(taken.items()):
        fresh = offsets - ready.get(file_id, ("", set()))[1]
        if fresh:
            new_total += len(fresh)
            print(f"  {len(fresh)} new blocks of {names.get(file_id, '?')} [{file_id:016x}]")
    if new_total:
        return 0

    print("error: the run compiled blocks that the ready code maps have already;"
          " compiling the caches again would not add them:")
    cache = os.path.join(cache_dir, "cache")
    for file_id, offsets in sorted(taken.items()):
        ready_name = ready[file_id][0]
        files = [f for f in (sorted(os.listdir(cache)) if os.path.isdir(cache) else [])
                 if f.startswith(ready_name + "-")]
        in_cache = cached_blocks(os.path.join(cache, files[0])) if files else None
        where = f"cache {files[0]}" if files else "no cache file"
        print(f"  {names.get(file_id, ready_name)} [{file_id:016x}], {where}:")
        for off in sorted(offsets):
            if in_cache is None:
                state = "cache file missing or unreadable"
            elif off in in_cache:
                state = "in the cache, so the run lost it (look for [code-inval] / [aot-miss])"
            else:
                state = "not in the cache, so the offline compiler left it out (look for [aot-gen])"
            print(f"    {off:#x}: {state}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

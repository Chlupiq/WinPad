"""Compares the code caches FEX's offline compiler made on two computers, file by file.

Usage: compare_caches.py REFERENCE_CACHE_DIR OTHER_CACHE_DIR
(each FEX's cache directory, the caches in its cache/). Exits with 1 unless
both hold the same caches with the same bytes.
"""
import hashlib
import os
import sys


def caches(cache_dir):
    folder = os.path.join(cache_dir, "cache")
    out = {}
    for name in sorted(os.listdir(folder)):
        with open(os.path.join(folder, name), "rb") as f:
            data = f.read()
        out[name] = (len(data), hashlib.sha256(data).hexdigest())
    return out


def main(argv):
    ref, other = caches(argv[0]), caches(argv[1])
    same = 0
    for name in sorted(set(ref) | set(other)):
        a, b = ref.get(name), other.get(name)
        if a == b:
            same += 1
            print(f"  same       {name} ({a[0]} bytes)")
        elif a and b:
            print(f"  DIFFERENT  {name} ({a[0]} vs {b[0]} bytes)")
        else:
            print(f"  ONLY IN {'reference' if a else 'other'}  {name}")
    print(f"{same} of {len(set(ref) | set(other))} code caches identical")
    return 0 if ref and ref == other else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A local copy of the GOG servers the app talks to (GOG.m), for CI (build-xcode.sh).

Writes into OUT the files a plain HTTP server (python3 -m http.server) serves at
http://127.0.0.1:PORT/<host>/<path>, which the app asks with the "gogAPIBase" setting:
the token, the account's games, a game's builds, its build manifest and depot manifests
(zlib-compressed, as GOG's content system has them), the secure links and the chunks.

The game, PRODUCT_ID, has: a program split into two chunks, files of a language depot for
English and one for German (only the English one is to be installed), a depot of an owned DLC,
small files in a depot's container, a directory, an empty file and a support file (which stays
out); and depots the app must not download: a DLC the account does not own and the 64-bit one
of a 32/64-bit pair (neither is served, so fetching one fails). OUT/expected.txt has the lines
the app's report (Documents/gog.txt) must have.

A second game, OLD_ID, GOG has only in generation 1 (older games never repacked for Galaxy): its
repository.json lists depots, each depot's manifest lists files as ranges of one main.bin,
fetched with Range requests (the server here answers those, as GOG's CDN does); its Neutral and
English depots go in, the German one and the DirectX redistributable stay out.

Usage: gog-fixture.py OUT PORT PROGRAM.EXE
       gog-fixture.py --serve OUT PORT   (an HTTP server for OUT that answers Range requests)
"""
import hashlib
import json
import os
import sys
import zlib

PRODUCT_ID = 1207658999
DLC_ID = 1207659000
NOT_OWNED_ID = 1207659777
OLD_ID = 1207650001


def md5(b):
    return hashlib.md5(b).hexdigest()


def galaxy(h):
    return f"{h[:2]}/{h[2:4]}/{h}"


def main():
    out, port, program = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    base = f"http://127.0.0.1:{port}"

    def put(rel, data):
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data if isinstance(data, bytes) else json.dumps(data).encode())

    store = "content-system/v2/store"

    def chunks(data, product, size=None):
        """DATA as chunks on the CDN, each zlib-compressed and named by its MD5."""
        size = size or max(len(data), 1)
        out_chunks = []
        for i in range(0, len(data), size):
            part = data[i:i + size]
            packed = zlib.compress(part, 9)
            out_chunks.append({"md5": md5(part), "size": len(part), "compressedMd5": md5(packed),
                               "compressedSize": len(packed)})
            put(f"cdn/token=t/{store}/{product}/{galaxy(md5(packed))}", packed)
        return out_chunks

    expected = []

    def depot_file(path, data, product, size=None, flags=None):
        item = {"type": "DepotFile", "path": path, "chunks": chunks(data, product, size)}
        if flags:
            item["flags"] = flags
        return item

    def expect(path, data):
        expected.append(f"file: {path} | {len(data)} | {md5(data)}")

    exe = open(program, "rb").read()
    level = b"level one\n" * 100
    small_a, small_b = b"small file a\n", b"small file b, a bit longer\n"
    english, german = b"Hello\n", b"Hallo\n"
    bonus = b"bonus content\n" * 50

    # The base game's depot for every language: the program in two chunks, a container of
    # small files, a directory, an empty file, a support file.
    container = small_a + small_b
    main_items = [
        depot_file("GAME.EXE", exe, PRODUCT_ID, size=len(exe) // 2 + 1),
        depot_file("DATA\\level1.dat", level, PRODUCT_ID),
        {"type": "DepotFile", "path": "small\\a.txt", "chunks": [], "sfcRef": {"offset": 0, "size": len(small_a)}},
        {"type": "DepotFile", "path": "small\\b.txt", "chunks": [],
         "sfcRef": {"offset": len(small_a), "size": len(small_b)}},
        {"type": "DepotDirectory", "path": "SAVES"},
        {"type": "DepotFile", "path": "empty.cfg", "chunks": []},
        depot_file("__redist\\vcredist.exe", b"redist", PRODUCT_ID, flags=["support"]),
        {"type": "DepotFile", "path": "..\\outside.txt", "chunks": []},
    ]
    for p, d in (("GAME.EXE", exe), ("DATA/level1.dat", level), ("small/a.txt", small_a), ("small/b.txt", small_b),
                 ("LANG/english.txt", english), ("DLC/bonus.dat", bonus), ("empty.cfg", b"")):
        expect(p, d)
    expected.append("dir: SAVES")
    expected.append(f"file: goggame-{PRODUCT_ID}.info")
    expected.append("language en-US")
    expected.append("installed: WinPad GOG Test |")
    expected.append(f"installed folder found: WinPad GOG Test")
    expected.append(f"game: {PRODUCT_ID} | WinPad GOG Test")
    expected.append("signed in after sign out: NO")

    depots = {
        "main": {"depot": {"items": main_items, "smallFilesContainer": {"chunks": chunks(container, PRODUCT_ID)}}},
        "en": {"depot": {"items": [depot_file("LANG\\english.txt", english, PRODUCT_ID)]}},
        "de": {"depot": {"items": [depot_file("LANG\\german.txt", german, PRODUCT_ID)]}},
        "dlc": {"depot": {"items": [depot_file("DLC\\bonus.dat", bonus, DLC_ID)]}},
    }
    hashes = {}
    for name, depot in depots.items():
        packed = zlib.compress(json.dumps(depot).encode())
        h = md5(name.encode())
        hashes[name] = h
        put(f"gog-cdn-fastly.gog.com/content-system/v2/meta/{galaxy(h)}", packed)
    missing = md5(b"not served")

    manifest = {
        "version": 2,
        "baseProductId": str(PRODUCT_ID),
        "installDirectory": "WinPad GOG Test",
        "depots": [
            {"productId": str(PRODUCT_ID), "languages": ["*"], "osBitness": ["32"], "manifest": hashes["main"]},
            {"productId": str(PRODUCT_ID), "languages": ["*"], "osBitness": ["64"], "manifest": missing},
            {"productId": str(PRODUCT_ID), "languages": ["en-US"], "manifest": hashes["en"]},
            {"productId": str(PRODUCT_ID), "languages": ["de-DE"], "manifest": hashes["de"]},
            {"productId": str(DLC_ID), "languages": ["*"], "manifest": hashes["dlc"]},
            {"productId": str(NOT_OWNED_ID), "languages": ["*"], "manifest": missing},
        ],
    }
    put("cdn/manifest/build555", zlib.compress(json.dumps(manifest).encode()))
    put(f"content-system.gog.com/products/{PRODUCT_ID}/os/windows/builds", {
        "total_count": 2,
        "items": [
            {"build_id": "999", "generation": 2, "branch": "beta", "link": f"{base}/cdn/manifest/beta"},
            {"build_id": "555", "generation": 2, "branch": None, "link": f"{base}/cdn/manifest/build555"},
        ],
    })
    for product in (PRODUCT_ID, DLC_ID):
        put(f"content-system.gog.com/products/{product}/secure_link", {"urls": [
            # A worse endpoint that has nothing: tried only after the best one.
            {"endpoint_name": "empty", "url_format": "{base_url}/nothing{path}",
             "parameters": {"base_url": f"{base}/cdn", "path": f"/{store}/{product}"}, "priority": 1},
            {"endpoint_name": "local", "url_format": "{base_url}/token={token}{path}",
             "parameters": {"base_url": f"{base}/cdn", "path": f"/{store}/{product}/", "token": "t"}, "priority": 100},
        ]})

    # The generation 1 game: one main.bin with every file's bytes, at offsets.
    legacy = "24680"
    old_files = {"neutral": [("/OLD.EXE", exe), ("/data/readme.txt", b"read me\n" * 40)],
                 "english": [("/lang/english.txt", english)], "german": [("/lang/german.txt", german)]}
    main_bin = b""
    v1_dir = f"cdn/content-system/v1/manifests/{OLD_ID}/windows/{legacy}"
    for name, entries in old_files.items():
        listed = []
        for path, data in entries:
            listed.append({"url": f"{OLD_ID}/main.bin", "path": path, "size": len(data), "offset": len(main_bin),
                           "hash": md5(data)})
            main_bin += data
        if name == "neutral":
            listed.append({"directory": True, "path": "/saves"})
            listed.append({"url": f"{OLD_ID}/main.bin", "path": "/support/old-redist.exe", "size": 3,
                           "offset": 0, "hash": md5(main_bin[:3]), "support": True})
        put(f"{v1_dir}/{name}.json", {"version": 1, "depot": {"name": name, "files": listed}})
    put(f"cdn/token=t/content-system/v1/depots/{OLD_ID}/windows/{legacy}/main.bin", main_bin)
    put(f"{v1_dir}/repository.json", {"version": 1, "product": {
        "rootGameID": str(OLD_ID), "installDirectory": "WinPad GOG Old", "name": "WinPad GOG Old",
        "gameIDs": [{"gameID": str(OLD_ID), "name": {"en": "WinPad GOG Old"}}],
        "depots": [
            {"languages": ["Neutral"], "gameIDs": [str(OLD_ID)], "systems": ["Windows"], "manifest": "neutral.json",
             "size": "1"},
            {"languages": ["English"], "gameIDs": [str(OLD_ID)], "systems": ["Windows"], "manifest": "english.json",
             "size": "1"},
            {"languages": ["German"], "gameIDs": [str(OLD_ID)], "systems": ["Windows"], "manifest": "german.json",
             "size": "1"},
            {"redist": "DirectX", "executable": "/__redist/DirectX/DXSETUP.exe", "argument": "/silent", "size": "1"},
        ]}})
    put(f"content-system.gog.com/products/{OLD_ID}/os/windows/builds", {"total_count": 1, "items": [
        {"build_id": "5550001", "legacy_build_id": legacy, "generation": 1, "branch": None,
         "link": f"{base}/{v1_dir}/repository.json"}]})
    put(f"content-system.gog.com/products/{OLD_ID}/secure_link", {"urls": [
        {"endpoint_name": "local", "url_format": "{base_url}/token={token}{path}",
         "parameters": {"base_url": f"{base}/cdn", "path": f"/content-system/v1/depots/{OLD_ID}/windows/{legacy}",
                        "token": "t"}, "priority": 100}]})
    for path, data in old_files["neutral"] + old_files["english"]:
        expect(path.lstrip("/"), data)
    expected.append("dir: saves")
    expected.append("installed: WinPad GOG Old |")
    expected.append("installed folder found: WinPad GOG Old")
    expected.append("language English")

    put("auth.gog.com/token", {"access_token": "test-access", "expires_in": 3600, "token_type": "bearer",
                               "refresh_token": "test-refresh", "user_id": "42"})
    put("embed.gog.com/user/data/games", {"owned": [PRODUCT_ID, DLC_ID, OLD_ID]})
    put("embed.gog.com/account/getFilteredProducts", {"page": 1, "totalPages": 1, "products": [
        {"id": PRODUCT_ID, "title": "WinPad GOG Test", "worksOn": {"Windows": True, "Mac": False, "Linux": False}},
        {"id": OLD_ID, "title": "WinPad GOG Old", "worksOn": {"Windows": True, "Mac": False, "Linux": False}},
        {"id": 5, "title": "Mac Only", "worksOn": {"Windows": False, "Mac": True, "Linux": False}},
    ]})
    with open(os.path.join(out, "expected.txt"), "w") as f:
        f.write("\n".join(expected) + "\n")
    with open(os.path.join(out, "unexpected.txt"), "w") as f:
        f.write("german.txt\nvcredist\noutside.txt\nMac Only\n.winpad-sfc\n.winpad-part\nold-redist\nfailed:\n")


def serve(root, port):
    """Plain files under ROOT, with single Range requests answered by 206 (as GOG's CDN)."""
    import http.server
    import re

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=root, **k)

        def send_head(self):
            m = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
            path = self.translate_path(self.path)
            if not m or not os.path.isfile(path):
                return super().send_head()
            start, end = int(m.group(1)), int(m.group(2))
            f = open(path, "rb")
            size = os.fstat(f.fileno()).st_size
            if start >= size or end < start:
                f.close()
                self.send_error(416)
                return None
            end = min(end, size - 1)
            f.seek(start)
            data = f.read(end - start + 1)
            f.close()
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            import io
            return io.BytesIO(data)

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    if sys.argv[1] == "--serve":
        serve(sys.argv[2], int(sys.argv[3]))
    else:
        main()

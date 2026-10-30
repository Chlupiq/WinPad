"""The WinPad Wine app as an IPA (tests/wine-app/make-ipa.sh): its i386 DLLs, and adding images to it.

The i386 Wine DLLs a game's code maps name have to be the very files the iPad
runs (FEX's file id hashes each DLL's name, size and link time), so they come
out of the same IPA the iPad has. The AOT image goes back into a copy of it,
in WinPadWine.app/Frameworks, for AltStore, SideStore or Sideloadly to sign and
install.
"""
import os
import plistlib
import shutil
import zipfile


class IpaError(Exception):
    pass


def app_prefix(names):
    """Payload/NAME.app/ of the app in an IPA's file list."""
    for n in names:
        parts = n.split("/")
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            return f"Payload/{parts[1]}/"
    raise IpaError("no Payload/*.app in the IPA")


def extract_system_dlls(ipa, folder):
    """Writes the app's i386-windows/*.dll to FOLDER. Returns how many."""
    with zipfile.ZipFile(ipa) as z:
        prefix = app_prefix(z.namelist()) + "i386-windows/"
        os.makedirs(folder, exist_ok=True)
        count = 0
        for info in z.infolist():
            rest = info.filename[len(prefix):]
            if not info.filename.startswith(prefix) or not rest or "/" in rest or info.is_dir():
                continue
            with z.open(info) as src, open(os.path.join(folder, rest), "wb") as dst:
                shutil.copyfileobj(src, dst)
            count += 1
    if not count:
        raise IpaError(f"{ipa} has no i386-windows DLLs (is it a WinPad Wine IPA?)")
    return count


def renamed_plist(data, app_name):
    """Info.plist DATA (XML or binary) with APP_NAME as the name under the app's icon."""
    info = plistlib.loads(data)
    info["CFBundleDisplayName"] = app_name
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML)


def rename_app(info_plist, app_name):
    """Sets the name under the app's icon in an Info.plist file (of a WinPadWine-xcode project)."""
    with open(info_plist, "rb") as f:
        data = renamed_plist(f.read(), app_name)
    with open(info_plist, "wb") as f:
        f.write(data)


def add_images(ipa, out, images, app_name=""):
    """Copies IPA to OUT with each of IMAGES (paths) in the app's Frameworks, replacing a
    file of the same name, and APP_NAME, if given, under its icon. The installer signs
    them with the rest of the app."""
    names = {os.path.basename(p) for p in images}
    with zipfile.ZipFile(ipa) as src:
        app = app_prefix(src.namelist())
        prefix = app + "Frameworks/"
        tmp = out + ".tmp"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
            for info in src.infolist():
                if info.filename.startswith(prefix) and info.filename[len(prefix):] in names:
                    continue
                with src.open(info) as f:
                    data = f.read()
                if app_name and info.filename == app + "Info.plist":
                    data = renamed_plist(data, app_name)
                dst.writestr(info, data)
            for p in images:
                info = zipfile.ZipInfo(prefix + os.path.basename(p))
                info.external_attr = 0o100755 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(p, "rb") as f:
                    dst.writestr(info, f.read())
    os.replace(tmp, out)

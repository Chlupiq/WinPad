"""Signs the WinPad Wine app (an IPA or WinPadWine.app) for an iPad with your own Apple
certificate and provisioning profile, so it installs without AltStore or Sideloadly.

Two signers:
- codesign, on a Mac, with an identity of the keychain (Xcode puts the Apple Development
  one there when you sign in with your Apple ID);
- rcodesign (apple-codesign, github.com/indygreg/apple-platform-rs), anywhere, with the
  certificate as a .p12 file: on a Windows PC, on Linux, and in the cloud signing job
  (data/cloud-sign/winpad-sign.yml), which runs this file on its own.

It only uses the standard library, so the cloud job can run it without the rest of the
translator: python3 signipa.py IN.ipa OUT.ipa --profile X.mobileprovision --p12 X.p12
--p12-password-file PW.
"""
import argparse
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")


class SignError(Exception):
    pass


# ---- provisioning profiles ----------------------------------------------------------

def profile_plist(data):
    """The property list inside a .mobileprovision (a CMS envelope around an XML plist)."""
    start, end = data.find(b"<?xml"), data.rfind(b"</plist>")
    if start < 0 or end < 0:
        raise SignError("not a provisioning profile (no property list in it)")
    return plistlib.loads(data[start:end + len(b"</plist>")])


class Profile:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        info = profile_plist(self.data)
        self.name = info.get("Name", os.path.basename(path))
        self.team = (info.get("TeamIdentifier") or [""])[0]
        self.entitlements = dict(info.get("Entitlements") or {})
        app_id = self.entitlements.get("application-identifier", "")
        # "TEAM.com.example.app", "TEAM.com.example.*" or "TEAM.*".
        self.app_id = app_id.split(".", 1)[1] if "." in app_id else app_id
        self.devices = [d.lower() for d in info.get("ProvisionedDevices") or []]
        self.all_devices = bool(info.get("ProvisionsAllDevices"))
        self.expires = info.get("ExpirationDate")
        self.certificates = [hashlib.sha1(c).hexdigest().upper() for c in info.get("DeveloperCertificates") or []]
        self.platforms = info.get("Platform") or []

    def __str__(self):
        return f"{self.name} ({self.team}, {self.app_id})"

    def expired(self, now=None):
        if not self.expires:
            return False
        now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        expires = self.expires.replace(tzinfo=None) if self.expires.tzinfo else self.expires
        return expires <= now

    def matches(self, bundle_id):
        if self.app_id == "*":
            return True
        if self.app_id.endswith(".*"):
            return bundle_id.startswith(self.app_id[:-1])
        return self.app_id == bundle_id

    def bundle_id(self, current):
        """The bundle identifier the app gets: CURRENT if the profile allows it, else the profile's."""
        if self.matches(current):
            return current
        if self.app_id.endswith("*"):
            # A wildcard for another prefix: the app's own name under it.
            return self.app_id[:-1] + current.rsplit(".", 1)[-1]
        return self.app_id

    def has_device(self, udid):
        return self.all_devices or (udid or "").lower() in self.devices

    def app_entitlements(self, bundle_id):
        """The profile's entitlements for BUNDLE_ID: the app may have no more than these."""
        ent = dict(self.entitlements)
        ent["application-identifier"] = f"{self.team}.{bundle_id}"
        if "com.apple.developer.team-identifier" not in ent and self.team:
            ent["com.apple.developer.team-identifier"] = self.team
        groups = ent.get("keychain-access-groups")
        if isinstance(groups, list):
            ent["keychain-access-groups"] = [g.replace("*", bundle_id) if g.endswith(".*") else g for g in groups]
        return ent


def profile_folders():
    home = os.path.expanduser("~")
    return [os.path.join(home, "Library", "Developer", "Xcode", "UserData", "Provisioning Profiles"),
            os.path.join(home, "Library", "MobileDevice", "Provisioning Profiles")]


def find_profile(bundle_id, team=None, certificate=None, folders=None):
    """The newest unexpired profile on this Mac (Xcode keeps them) for BUNDLE_ID, of TEAM
    and with CERTIFICATE (SHA-1) in it, if given. An exact app id beats a wildcard."""
    found = []
    for folder in folders or profile_folders():
        if not os.path.isdir(folder):
            continue
        for name in os.listdir(folder):
            if not name.endswith((".mobileprovision", ".provisionprofile")):
                continue
            try:
                p = Profile(os.path.join(folder, name))
            except (OSError, SignError, ValueError):
                continue
            if p.expired() or not p.matches(bundle_id) or (team and p.team != team):
                continue
            if certificate and p.certificates and certificate.upper() not in p.certificates:
                continue
            if p.platforms and "iOS" not in p.platforms:
                continue
            found.append(p)
    if not found:
        return None
    found.sort(key=lambda p: (p.app_id == bundle_id, p.expires or datetime.datetime.min))
    return found[-1]


# ---- the app ------------------------------------------------------------------------

def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def main_executable(app):
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        name = plistlib.load(f).get("CFBundleExecutable")
    if not name or not os.path.isfile(os.path.join(app, name)):
        raise SignError(f"{app} has no main executable")
    return os.path.join(app, name)


def nested_code(app):
    """The Mach-O files in APP other than its executable, deepest first (signed before what holds them)."""
    main = os.path.normcase(os.path.abspath(main_executable(app)))
    found = []
    for folder, dirs, files in os.walk(app):
        dirs[:] = [d for d in dirs if d != "_CodeSignature"]
        for name in files:
            path = os.path.join(folder, name)
            if os.path.normcase(os.path.abspath(path)) != main and not os.path.islink(path) and is_macho(path):
                found.append(path)
    return sorted(found, key=lambda p: (-p.count(os.sep), p))


def read_info(app):
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        data = f.read()
    return plistlib.loads(data), data.startswith(b"bplist")


def write_info(app, info, binary):
    with open(os.path.join(app, "Info.plist"), "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)


def prepare(app, profile, bundle_id=None, app_name=None, log=print):
    """Puts PROFILE into APP, sets its bundle identifier (BUNDLE_ID, else what the profile
    allows) and name, removes old signatures. Returns (bundle id, entitlements)."""
    info, binary = read_info(app)
    current = info.get("CFBundleIdentifier", "")
    want = bundle_id or profile.bundle_id(current)
    if not profile.matches(want):
        raise SignError(f"the profile {profile} is not for the bundle identifier {want}")
    if want != current:
        log(f"  bundle identifier {current} -> {want} (the profile's): iOS takes it for another app, "
            "with its own Documents")
        info["CFBundleIdentifier"] = want
    if app_name:
        info["CFBundleDisplayName"] = app_name
    write_info(app, info, binary)
    for folder, dirs, _ in os.walk(app, topdown=False):
        for d in dirs:
            if d == "_CodeSignature":
                shutil.rmtree(os.path.join(folder, d))
    shutil.copyfile(profile.path, os.path.join(app, "embedded.mobileprovision"))
    return want, profile.app_entitlements(want)


def write_entitlements(ent, folder):
    path = os.path.join(folder, "entitlements.plist")
    with open(path, "wb") as f:
        plistlib.dump(ent, f, fmt=plistlib.FMT_XML)
    return path


def _run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if r.returncode:
        raise SignError(f"{what} failed:\n{(r.stderr or r.stdout).strip()}")
    return r


class Codesign:
    """Apple's codesign with an identity of the keychain (a Mac)."""
    name = "codesign"

    def __init__(self, identity):
        self.identity = identity

    def sign(self, app, entitlements, log):
        nested = nested_code(app)
        for path in nested:
            _run(["codesign", "--force", "--sign", self.identity, "--timestamp=none", path], f"codesign {path}")
        _run(["codesign", "--force", "--sign", self.identity, "--timestamp=none", "--entitlements", entitlements,
              "--generate-entitlement-der", app], f"codesign {app}")
        log(f"  signed {len(nested)} libraries and the app with {self.identity}")


def find_rcodesign(extra=()):
    """rcodesign: given, next to this program (the packaged translator brings it), or on the PATH."""
    here = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, "frozen", False) else __file__))
    for d in list(extra) + [os.path.join(getattr(sys, "_MEIPASS", here), "toolkit"), os.path.join(here, "toolkit"),
                            here, os.path.join(here, "..", "toolkit")]:
        for n in ("rcodesign", "rcodesign.exe"):
            if os.path.isfile(os.path.join(d, n)):
                return os.path.join(d, n)
    return shutil.which("rcodesign") or ""


class Rcodesign:
    """apple-codesign's rcodesign with the certificate and its key as a .p12 file (any computer)."""
    name = "rcodesign"

    def __init__(self, p12, password="", tool=""):
        self.p12 = p12
        self.password = password
        self.tool = tool or find_rcodesign()
        if not self.tool:
            raise SignError("rcodesign was not found: it comes with the packaged WinPad Translator, or install "
                            "apple-codesign (github.com/indygreg/apple-platform-rs/releases, or cargo install "
                            "apple-codesign)")
        if not os.path.isfile(p12):
            raise SignError(f"no certificate file {p12}")

    def sign(self, app, entitlements, log):
        with tempfile.TemporaryDirectory() as tmp:
            pw = os.path.join(tmp, "password")
            with open(pw, "w") as f:
                f.write(self.password)
            # The entitlements only for the app's executable (scoped by its path in the
            # bundle; a Windows path's own colon comes after it). rcodesign signs every
            # Mach-O file in the bundle and seals the rest.
            # No time stamp: iOS does not need one (Xcode signs without), and it needs Apple's server.
            _run([self.tool, "sign", "--p12-file", self.p12, "--p12-password-file", pw, "--timestamp-url", "none",
                  "--entitlements-xml-file", f"{os.path.basename(main_executable(app))}:{entitlements}", app],
                 "rcodesign")
        log(f"  signed {len(nested_code(app))} libraries and the app with {os.path.basename(self.p12)}")


def certificate_sha1(p12, password):
    """SHA-1 of the certificate in a .p12 (as profiles list them), or None without a way to read it."""
    try:
        from cryptography.hazmat.primitives.serialization import Encoding, pkcs12
    except ImportError:
        pkcs12 = None
    with open(p12, "rb") as f:
        data = f.read()
    if pkcs12:
        try:
            _, cert, _ = pkcs12.load_key_and_certificates(data, password.encode() if password else None)
        except ValueError as e:
            raise SignError(f"{p12}: {e} (wrong password?)")
        return hashlib.sha1(cert.public_bytes(Encoding.DER)).hexdigest().upper() if cert else None
    if not shutil.which("openssl"):
        return None
    for legacy in ([], ["-legacy"]):
        r = subprocess.run(["openssl", "pkcs12", "-in", p12, "-nokeys", "-clcerts", "-passin", "env:WINPAD_P12_PW"]
                           + legacy, capture_output=True, env=dict(os.environ, WINPAD_P12_PW=password))
        m = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", r.stdout, re.S)
        if r.returncode == 0 and m:
            der = subprocess.run(["openssl", "x509", "-outform", "DER"], input=m.group(0), capture_output=True).stdout
            return hashlib.sha1(der).hexdigest().upper() if der else None
    return None


def check_certificate(profile, sha1):
    if sha1 and profile.certificates and sha1.upper() not in profile.certificates:
        raise SignError(f"the profile {profile} was not made for this certificate: make a profile with it "
                        "(developer.apple.com > Profiles) or give its own certificate")


def sign_app(app, profile, signer, bundle_id=None, app_name=None, log=print):
    """Signs the app folder APP in place. Returns its bundle identifier."""
    if profile.expired():
        raise SignError(f"the profile {profile} expired on {profile.expires:%Y-%m-%d}: make a new one")
    bundle, ent = prepare(app, profile, bundle_id, app_name, log)
    with tempfile.TemporaryDirectory() as tmp:
        signer.sign(app, write_entitlements(ent, tmp), log)
    return bundle


def unpack(ipa, folder):
    """Unzips IPA into FOLDER; returns the path of its .app."""
    with zipfile.ZipFile(ipa) as z:
        for info in z.infolist():
            target = os.path.realpath(os.path.join(folder, info.filename))
            if not target.startswith(os.path.realpath(folder) + os.sep):
                raise SignError(f"{ipa}: {info.filename} points outside the IPA")
            z.extract(info, folder)
            mode = info.external_attr >> 16
            if mode and not info.is_dir():
                os.chmod(target, (mode & 0o777) | 0o600)
    payload = os.path.join(folder, "Payload")
    apps = [n for n in os.listdir(payload) if n.endswith(".app")] if os.path.isdir(payload) else []
    if len(apps) != 1:
        raise SignError(f"{ipa} has no single Payload/*.app")
    return os.path.join(payload, apps[0])


def pack(folder, ipa):
    """Zips FOLDER's Payload into IPA, keeping each file's permissions."""
    tmp = ipa + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in os.walk(os.path.join(folder, "Payload")):
            dirs.sort()
            rel = os.path.relpath(base, folder).replace(os.sep, "/")
            z.write(base, rel + "/")
            for name in sorted(files):
                path = os.path.join(base, name)
                info = zipfile.ZipInfo.from_file(path, f"{rel}/{name}")
                info.compress_type = zipfile.ZIP_DEFLATED
                mode = os.stat(path).st_mode & 0o777
                if is_macho(path):
                    mode |= 0o755
                info.external_attr = (0o100000 | mode) << 16
                with open(path, "rb") as f:
                    z.writestr(info, f.read())
    os.replace(tmp, ipa)


def sign_ipa(ipa, out, profile, signer, bundle_id=None, app_name=None, keep_app=None, log=print):
    """Writes OUT, IPA signed. With KEEP_APP (a folder), the signed .app stays there too
    (for devicectl, which installs an app folder). Returns (bundle id, the .app or None)."""
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(ipa, tmp)
        bundle = sign_app(app, profile, signer, bundle_id, app_name, log)
        pack(tmp, out)
        kept = None
        if keep_app:
            kept = os.path.join(keep_app, os.path.basename(app))
            shutil.rmtree(kept, ignore_errors=True)
            os.makedirs(keep_app, exist_ok=True)
            shutil.copytree(app, kept, symlinks=True)
    log(f"=== {out}: signed for {profile.team} ({bundle})")
    return bundle, kept


def main(argv=None):
    ap = argparse.ArgumentParser(description="Signs a WinPad Wine IPA with a .p12 certificate (rcodesign) or "
                                 "a keychain identity (codesign) and a provisioning profile.")
    ap.add_argument("ipa")
    ap.add_argument("out")
    ap.add_argument("--profile", required=True, help="the .mobileprovision")
    ap.add_argument("--p12", help="certificate and key (.p12): sign with rcodesign")
    ap.add_argument("--p12-password-file", help="file with the .p12's password")
    ap.add_argument("--identity", help="or a keychain identity: sign with codesign (Mac)")
    ap.add_argument("--rcodesign", help="rcodesign's path")
    ap.add_argument("--bundle-id")
    ap.add_argument("--app-name")
    args = ap.parse_args(argv)
    try:
        profile = Profile(args.profile)
        if args.identity:
            signer = Codesign(args.identity)
        elif args.p12:
            password = ""
            if args.p12_password_file:
                with open(args.p12_password_file) as f:
                    password = f.read().rstrip("\r\n")
            check_certificate(profile, certificate_sha1(args.p12, password))
            signer = Rcodesign(args.p12, password, args.rcodesign or "")
        else:
            raise SignError("give --p12 or --identity")
        sign_ipa(args.ipa, args.out, profile, signer, args.bundle_id, args.app_name)
    except (SignError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

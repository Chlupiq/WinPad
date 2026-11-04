"""Sign and install: the app with the game's image goes onto the iPad in one step.

Executable code on an iPad must be signed for it, so the translated image can only run
from an app signed with your Apple certificate. How that happens depends on the computer:

- A Mac with Xcode and a WinPadWine-xcode project: xcodebuild builds the app with your
  team (Xcode makes the certificate and profile itself, -allowProvisioningUpdates), and
  devicectl installs it on the iPad connected by cable or on the same Wi-Fi.
- A Mac with only the IPA: codesign signs it with your Apple Development identity and the
  profile Xcode made for the app (from a run of WinPadWine from Xcode), devicectl installs it.
- Any computer with your certificate as a .p12 and a profile from developer.apple.com:
  rcodesign signs the IPA.
- A Windows PC without anything: a GitHub Actions job in your private repository signs it
  (cloud.py).

A signed IPA goes onto the iPad with ideviceinstaller (libimobiledevice) when it is
installed, else you install the file with Sideloadly (or Apple Configurator) yourself.
"""
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from . import signipa


class InstallError(Exception):
    pass


@dataclasses.dataclass
class Device:
    name: str
    identifier: str  # devicectl's (a UUID), or the UDID for ideviceinstaller
    udid: str = ""
    kind: str = ""  # iPad, iPhone
    connected: bool = False

    def __str__(self):
        return f"{self.name} ({self.kind or 'device'}, {self.udid or self.identifier})"


# ---- Mac: identity, team, Xcode, devicectl -----------------------------------------

def identities(run=subprocess.run):
    """[(SHA-1, name)] of the keychain's code signing identities."""
    out = run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    return re.findall(r'\)\s+([0-9A-F]{40})\s+"([^"]+)"', out)


def pick_identity(name="auto", run=subprocess.run):
    """(SHA-1, name) of NAME, or with "auto"/"" the first Apple Development identity."""
    found = identities(run)
    for sha1, ident in found:
        if (name in ("", "auto") and ident.startswith("Apple Development:")) or name in (ident, sha1):
            return sha1, ident
    if name in ("", "auto"):
        raise InstallError("no Apple Development identity in the keychain: open Xcode, Settings > Accounts, "
                           "add your Apple ID and Manage Certificates > + > Apple Development")
    raise InstallError(f"no code signing identity {name} in the keychain")


def team_of(identity, run=subprocess.run):
    """The team ID of a keychain identity: its certificate's organizational unit."""
    pem = run(["security", "find-certificate", "-c", identity, "-p"], capture_output=True, text=True).stdout
    if "BEGIN CERTIFICATE" not in pem:
        raise InstallError(f"no certificate {identity} in the keychain")
    subject = run(["openssl", "x509", "-noout", "-subject", "-nameopt", "multiline"], input=pem,
                  capture_output=True, text=True).stdout
    m = re.search(r"organizationalUnitName\s*=\s*([A-Z0-9]{10})", subject)
    if not m:
        m = re.search(r"\(([A-Z0-9]{10})\)\s*$", identity)
    if not m:
        raise InstallError(f"the team of {identity} was not found: give it (--team, Xcode > Settings > Accounts)")
    return m.group(1)


def devicectl_devices(run=subprocess.run):
    """The iPads and iPhones paired with this Mac (Xcode's devicectl)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "devices.json")
        r = run(["xcrun", "devicectl", "list", "devices", "--json-output", out], capture_output=True, text=True)
        if r.returncode or not os.path.isfile(out):
            raise InstallError(f"xcrun devicectl failed (Xcode 15 or newer needed): {(r.stderr or r.stdout).strip()}")
        with open(out) as f:
            data = json.load(f)
    found = []
    for d in (data.get("result") or {}).get("devices") or []:
        hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
        if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
            continue
        if conn.get("pairingState") not in (None, "paired"):
            continue
        found.append(Device(props.get("name") or hw.get("marketingName") or "device", d.get("identifier", ""),
                            hw.get("udid", ""), hw.get("deviceType", ""),
                            conn.get("tunnelState") == "connected" or bool(props.get("ddiServicesAvailable"))))
    return found


def ideviceinstaller_devices(run=subprocess.run):
    """The devices libimobiledevice sees (Windows, Linux; on Windows it needs Apple's device drivers)."""
    if not shutil.which("idevice_id"):
        return []
    out = run(["idevice_id", "-l"], capture_output=True, text=True).stdout
    found = []
    for udid in out.split():
        name = ""
        if shutil.which("ideviceinfo"):
            name = run(["ideviceinfo", "-u", udid, "-k", "DeviceName"], capture_output=True, text=True).stdout.strip()
        found.append(Device(name or udid, udid, udid, "", True))
    return found


def choose_device(devices, want=""):
    """The device named WANT (name, UDID or identifier), else the only connected one (an iPad before an iPhone)."""
    if want:
        for d in devices:
            if want.lower() in (d.name.lower(), d.udid.lower(), d.identifier.lower()):
                return d
        raise InstallError(f"no device {want}; these are: {', '.join(map(str, devices)) or 'none'}")
    if not devices:
        raise InstallError("no iPad found: connect it by cable (unlocked, Trust this computer) or pair it "
                           "in Xcode > Window > Devices and Simulators")
    ready = [d for d in devices if d.connected] or devices
    ipads = [d for d in ready if d.kind == "iPad"]
    pick = ipads if len(ipads) == 1 else ready
    if len(pick) > 1:
        raise InstallError(f"several devices: {', '.join(map(str, pick))}; say which one (--device)")
    return pick[0]


def xcode_build(xcode_project, team, derived, bundle_id="", log=print, run=subprocess.run):
    """Builds WinPadWine-xcode for the iPad, signed by TEAM (Xcode makes or updates the
    profile, and registers a new device). Returns the .app."""
    proj = os.path.join(xcode_project, "WinPadWine.xcodeproj")
    if not os.path.isdir(proj):
        raise InstallError(f"{xcode_project} has no WinPadWine.xcodeproj")
    cmd = ["xcodebuild", "-project", proj, "-scheme", "WinPadWine", "-configuration", "Debug",
           "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
           "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
           f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic"]
    if bundle_id:
        cmd.append(f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}")
    log(f"=== building the app for team {team} (xcodebuild)")
    os.makedirs(derived, exist_ok=True)
    logfile = os.path.join(derived, "xcodebuild.log")
    with open(logfile, "w") as f:
        r = run(cmd + ["build"], stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        with open(logfile, errors="replace") as f:
            tail = f.read().splitlines()[-25:]
        hint = ""
        text = "\n".join(tail)
        if "No Account for Team" in text or "No profiles for" in text or "Signing for" in text:
            hint = ("\n  Xcode needs your Apple ID: Xcode > Settings > Accounts. With a free account the "
                    "bundle identifier must be one nobody else has: give your own (--bundle-id).")
        raise InstallError(f"xcodebuild failed (whole log: {logfile}):\n" + text + hint)
    app = os.path.join(derived, "Build", "Products", "Debug-iphoneos", "WinPadWine.app")
    if not os.path.isdir(app):
        raise InstallError(f"xcodebuild made no {app}")
    return app


def devicectl_install(app, device, log=print, run=subprocess.run):
    log(f"=== installing on {device} (devicectl)")
    r = run(["xcrun", "devicectl", "device", "install", "app", "--device", device.identifier, app],
            capture_output=True, text=True)
    if r.returncode:
        text = (r.stderr or r.stdout).strip()
        hint = ""
        if "Developer Mode" in text:
            hint = "\n  Turn on Developer Mode on the iPad: Settings > Privacy & Security > Developer Mode."
        elif "profile" in text.lower() and "device" in text.lower():
            hint = "\n  The profile does not list this iPad: register it (developer.apple.com > Devices) and make the profile again."
        raise InstallError(f"devicectl could not install the app:\n{text}{hint}")
    log("  installed. First start from a free or new certificate: Settings > General > VPN & Device "
        "Management > trust your Apple ID")


def ideviceinstaller_install(ipa, device, log=print, run=subprocess.run):
    log(f"=== installing on {device} (ideviceinstaller)")
    r = run(["ideviceinstaller", "-u", device.udid, "-i", ipa], capture_output=True, text=True)
    if r.returncode or "ERROR" in (r.stdout or ""):
        raise InstallError(f"ideviceinstaller could not install the app:\n{(r.stderr or r.stdout).strip()}")
    log("  installed")


# ---- the whole step ----------------------------------------------------------------

@dataclasses.dataclass
class Settings:
    """What sign-and-install needs (from Project or Library)."""
    # Mac: the keychain identity (auto: Apple Development), the team (empty: the identity's).
    identity: str = "auto"
    team: str = ""
    # Elsewhere (or a Mac without Xcode's profile): certificate .p12, its password, a profile.
    p12: str = ""
    p12_password: str = ""
    profile: str = ""
    # Sign in GitHub Actions of this private repository (owner/name) instead.
    cloud_repo: str = ""
    github_token: str = ""
    # Which iPad (name or UDID); empty: the only one connected.
    device: str = ""
    bundle_id: str = ""
    # Only sign (write the signed IPA), do not install.
    sign_only: bool = False


# The settings of Project and Library (install_*, cloud_repo) and the Settings field each fills.
FIELDS = {"install_identity": "identity", "install_team": "team", "install_p12": "p12", "install_profile": "profile",
          "cloud_repo": "cloud_repo", "install_device": "device", "install_bundle_id": "bundle_id",
          "sign_only": "sign_only"}


def settings_from(values):
    """Settings from a Project (attributes) or a library's settings (a dict)."""
    get = values.get if isinstance(values, dict) else (lambda k, d=None: getattr(values, k, d))
    s = Settings()
    for key, field in FIELDS.items():
        v = get(key)
        if v not in (None, ""):
            setattr(s, field, v)
    s.identity = s.identity or "auto"
    return s


def p12_password(value):
    """The .p12 password: VALUE, else WINPAD_P12_PASSWORD."""
    return value or os.environ.get("WINPAD_P12_PASSWORD", "")


def signed_name(ipa):
    base, ext = os.path.splitext(ipa)
    return base + "-signed" + (ext or ".ipa")


def install(s, xcode_project="", ipa="", app_name="", work="", log=print, run=subprocess.run):
    """Signs the app (the WinPadWine-xcode project with the images in it, or the IPA written
    with them) and installs it on the iPad. Returns the signed IPA or app."""
    work = work or tempfile.mkdtemp(prefix="winpad-install-")
    mac = sys.platform == "darwin"
    if s.cloud_repo:
        from . import cloud
        if not ipa:
            raise InstallError("cloud signing signs an IPA: write one (--out-ipa)")
        out = signed_name(ipa)
        cloud.Cloud(s.cloud_repo, cloud.token(s.github_token)).sign(ipa, out, s.bundle_id, app_name, log=log)
        return _install_ipa(out, s, log, run)
    if s.p12 or (s.profile and not mac):
        if not (s.p12 and s.profile):
            raise InstallError("signing with a certificate file needs both the .p12 and the profile (.mobileprovision)")
        if not ipa:
            raise InstallError("signing with a certificate file signs an IPA: write one (--out-ipa)")
        profile = signipa.Profile(s.profile)
        password = p12_password(s.p12_password)
        signipa.check_certificate(profile, signipa.certificate_sha1(s.p12, password))
        out = signed_name(ipa)
        log(f"=== signing {os.path.basename(ipa)} with {os.path.basename(s.p12)} and the profile {profile}")
        signipa.sign_ipa(ipa, out, profile, signipa.Rcodesign(s.p12, password), s.bundle_id or None,
                         app_name or None, log=log)
        return _install_ipa(out, s, log, run)
    if not mac:
        raise InstallError("signing needs your Apple certificate: on a Mac Xcode's, elsewhere a .p12 file and "
                           "a profile (--p12, --profile), or a GitHub repository to sign in (--cloud-sign)")
    sha1, identity = pick_identity(s.identity, run)
    team = s.team or team_of(identity, run)
    devices = [] if s.sign_only else devicectl_devices(run)
    device = None if s.sign_only else choose_device(devices, s.device)
    if xcode_project:
        app = xcode_build(xcode_project, team, os.path.join(work, "xcode-derived"), s.bundle_id, log, run)
        if not s.sign_only:
            devicectl_install(app, device, log, run)
        return app
    if not ipa:
        raise InstallError("nothing to install: give the WinPadWine-xcode project or write an IPA")
    bundle = s.bundle_id or bundle_id_of(ipa)
    profile = signipa.Profile(s.profile) if s.profile else signipa.find_profile(bundle, team, sha1)
    if not profile:
        raise InstallError(f"no provisioning profile of team {team} for {bundle} with {identity} on this Mac: "
                           "open the WinPadWine-xcode project, pick your team and Run once (Xcode makes it), "
                           "or give the project here (--xcode-project), or a profile (--profile)")
    if device and not profile.has_device(device.udid):
        raise InstallError(f"the profile {profile} does not list {device}: run WinPadWine on it from Xcode once "
                           "(Xcode adds it), or register it at developer.apple.com and make the profile again")
    out = signed_name(ipa)
    log(f"=== signing {os.path.basename(ipa)} with {identity} and the profile {profile}")
    _, app = signipa.sign_ipa(ipa, out, profile, signipa.Codesign(sha1), s.bundle_id or None, app_name or None,
                              keep_app=os.path.join(work, "signed"), log=log)
    if not s.sign_only:
        devicectl_install(app, device, log, run)
    return out


def bundle_id_of(ipa):
    """The IPA's CFBundleIdentifier."""
    import plistlib
    import zipfile
    from . import ipa as ipamod
    with zipfile.ZipFile(ipa) as z:
        data = z.read(ipamod.app_prefix(z.namelist()) + "Info.plist")
    return plistlib.loads(data).get("CFBundleIdentifier", "")


def _install_ipa(ipa, s, log, run):
    """Installs a signed IPA: devicectl on a Mac, ideviceinstaller elsewhere, else says how."""
    if s.sign_only:
        return ipa
    if sys.platform == "darwin" and shutil.which("xcrun"):
        device = choose_device(devicectl_devices(run), s.device)
        with tempfile.TemporaryDirectory() as tmp:
            devicectl_install(signipa.unpack(ipa, tmp), device, log, run)
        return ipa
    if shutil.which("ideviceinstaller"):
        device = choose_device(ideviceinstaller_devices(run), s.device)
        ideviceinstaller_install(ipa, device, log, run)
        return ipa
    log(f"=== {ipa} is signed for your iPad. Install it: Sideloadly (Advanced options > Signing mode: "
        "Normal install, so it keeps this signature), Apple Configurator, or ideviceinstaller -i "
        "(libimobiledevice) for this step next time")
    return ipa

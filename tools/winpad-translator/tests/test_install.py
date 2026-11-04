"""Tests of sign and install (install.py, signipa.py, cloud.py, applecert.py): profiles, signing
an IPA with rcodesign and a certificate made by applecert, the Mac steps with stand-ins for
Xcode's tools, and the cloud signing against a stand-in for GitHub's API."""
import base64
import datetime
import http.server
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from unittest import mock

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
from winpad_translator import cli, cloud, install, library, link, project, signipa  # noqa: E402

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    from winpad_translator import applecert
except ImportError:
    applecert = None

TEAM = "AB12CD34EF"
UDID = "00008103-000A1B2C3D4E5F6A"


def write_profile(path, app_id=f"{TEAM}.com.chlupiq.winpad.wine", devices=(UDID,), certs=(), days=300, name="Test"):
    info = {"Name": name, "TeamIdentifier": [TEAM], "Platform": ["iOS"],
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=days),
            "ProvisionedDevices": list(devices), "DeveloperCertificates": list(certs),
            "Entitlements": {"application-identifier": app_id, "com.apple.developer.team-identifier": TEAM,
                             "get-task-allow": True, "keychain-access-groups": [f"{TEAM}.*"]}}
    # A CMS envelope's bytes around the plist, as in a real .mobileprovision.
    with open(path, "wb") as f:
        f.write(b"\x30\x82\x10\x00junk" + plistlib.dumps(info) + b"\x00\x00sig")
    return path


def write_app_ipa(path, files, bundle="com.chlupiq.winpad.wine"):
    """An IPA of WinPadWine.app with FILES {relative path: bytes}."""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/WinPadWine.app/Info.plist", plistlib.dumps(
            {"CFBundleIdentifier": bundle, "CFBundleExecutable": "WinPadWine", "CFBundleName": "WinPadWine"}))
        for rel, data in files.items():
            info = zipfile.ZipInfo("Payload/WinPadWine.app/" + rel)
            info.external_attr = 0o100755 << 16
            z.writestr(info, data)
    return path


def rcodesign():
    return signipa.find_rcodesign([os.path.join(os.path.expanduser("~"), ".cargo", "bin")])


def macho(tc, folder, name, kind):
    """A tiny arm64 iOS executable or dylib, made with LLVM."""
    src = os.path.join(folder, name + ".s")
    with open(src, "w") as f:
        f.write(".text\n.globl _main\n_main:\n  ret\n" if kind == "exe" else ".text\n.globl _f\n_f:\n  ret\n")
    obj = src + ".o"
    link._assemble(tc, "iphoneos", src, obj, print)
    out = os.path.join(folder, name)
    flag = ["-execute"] if kind == "exe" else ["-dylib", "-install_name", "@rpath/" + name]
    subprocess.run(tc.linker + ["-arch", "arm64", "-platform_version", "ios", "17.4", "17.4"] + flag +
                   ["-o", out, obj, link._libsystem_stub("iphoneos", folder)], check=True)
    with open(out, "rb") as f:
        return f.read()


def importlib_has(name):
    import importlib.util
    return importlib.util.find_spec(name) is not None


def toolchain():
    try:
        return link.find_toolchain("llvm")
    except link.LinkError:
        return None


class ProfileTest(unittest.TestCase):
    def test_bundle_ids(self):
        with tempfile.TemporaryDirectory() as t:
            exact = signipa.Profile(write_profile(os.path.join(t, "a.mobileprovision")))
            self.assertEqual(exact.team, TEAM)
            self.assertEqual(exact.app_id, "com.chlupiq.winpad.wine")
            self.assertEqual(exact.bundle_id("com.chlupiq.winpad.wine"), "com.chlupiq.winpad.wine")
            self.assertEqual(exact.bundle_id("com.other.app"), "com.chlupiq.winpad.wine")
            wild = signipa.Profile(write_profile(os.path.join(t, "b.mobileprovision"), app_id=f"{TEAM}.*"))
            self.assertEqual(wild.bundle_id("com.chlupiq.winpad.wine"), "com.chlupiq.winpad.wine")
            ent = wild.app_entitlements("com.chlupiq.winpad.wine")
            self.assertEqual(ent["application-identifier"], f"{TEAM}.com.chlupiq.winpad.wine")
            self.assertEqual(ent["keychain-access-groups"], [f"{TEAM}.com.chlupiq.winpad.wine"])
            prefix = signipa.Profile(write_profile(os.path.join(t, "c.mobileprovision"), app_id=f"{TEAM}.me.games.*"))
            self.assertEqual(prefix.bundle_id("com.chlupiq.winpad.wine"), "me.games.wine")
            self.assertTrue(exact.has_device(UDID.lower()))
            self.assertFalse(exact.has_device("other"))

    def test_expired_and_found(self):
        with tempfile.TemporaryDirectory() as t:
            write_profile(os.path.join(t, "old.mobileprovision"), days=-1, name="old")
            write_profile(os.path.join(t, "wild.mobileprovision"), app_id=f"{TEAM}.*", name="wild")
            write_profile(os.path.join(t, "exact.mobileprovision"), name="exact", certs=[b"cert"])
            found = signipa.find_profile("com.chlupiq.winpad.wine", TEAM, folders=[t])
            self.assertEqual(found.name, "exact")
            sha1 = signipa.hashlib.sha1(b"other").hexdigest()
            self.assertEqual(signipa.find_profile("com.chlupiq.winpad.wine", TEAM, sha1, folders=[t]).name, "wild")
            self.assertIsNone(signipa.find_profile("com.chlupiq.winpad.wine", "ZZZZZZZZZZ", folders=[t]))
            self.assertTrue(signipa.Profile(os.path.join(t, "old.mobileprovision")).expired())


# CI has all of them; there a missing one is a failure.
REQUIRED = bool(os.environ.get("WINPAD_REQUIRE_SIGNING"))


@unittest.skipUnless(REQUIRED or (applecert and rcodesign() and toolchain()), "needs cryptography, rcodesign and LLVM")
class RcodesignTest(unittest.TestCase):
    def test_certificate_request_to_signed_ipa(self):
        with tempfile.TemporaryDirectory() as t:
            # The user's side: a key and a request; "Apple" (a test CA here) makes the certificate.
            folder = os.path.join(t, "certificate")
            with open(applecert.request(folder, "me@example.com"), "rb") as f:
                csr = x509.load_pem_x509_csr(f.read())
            ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            ca = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test WWDR")])
            now = datetime.datetime.now(datetime.timezone.utc)
            cert = (x509.CertificateBuilder().subject_name(x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, f"Apple Development: Me ({TEAM})"),
                x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM)]))
                .issuer_name(ca).public_key(csr.public_key()).serial_number(7)
                .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=30))
                .sign(ca_key, hashes.SHA256()))
            cer = os.path.join(t, "development.cer")
            with open(cer, "wb") as f:
                f.write(cert.public_bytes(serialization.Encoding.DER))
            p12 = os.path.join(t, "me.p12")
            self.assertIn("Apple Development", applecert.make_p12(folder, cer, p12, "secret"))
            der = cert.public_bytes(serialization.Encoding.DER)
            self.assertEqual(signipa.certificate_sha1(p12, "secret"), signipa.hashlib.sha1(der).hexdigest().upper())
            profile = signipa.Profile(write_profile(os.path.join(t, "p.mobileprovision"), certs=[der]))
            other = signipa.Profile(write_profile(os.path.join(t, "o.mobileprovision"), certs=[b"x"]))
            with self.assertRaises(signipa.SignError):
                signipa.check_certificate(other, signipa.certificate_sha1(p12, "secret"))

            tc = toolchain()
            bins = os.path.join(t, "bins")
            os.makedirs(bins)
            ipa = write_app_ipa(os.path.join(t, "WinPadWine.ipa"), {
                "WinPadWine": macho(tc, bins, "WinPadWine", "exe"),
                "Frameworks/fexaot-nfsu2.dylib": macho(tc, bins, "fexaot-nfsu2.dylib", "dylib"),
                "aarch64-windows/ntdll.dll.dylib": macho(tc, bins, "ntdll.dll.dylib", "dylib"),
                "i386-windows/ntdll.dll": b"MZ not mach-o",
                "_CodeSignature/CodeResources": b"stale"}, bundle="com.example.other")
            out = os.path.join(t, "signed.ipa")
            # The same command line the cloud job runs.
            pw = os.path.join(t, "pw")
            with open(pw, "w") as f:
                f.write("secret")
            self.assertEqual(signipa.main([ipa, out, "--profile", profile.path, "--p12", p12, "--p12-password-file", pw,
                                           "--rcodesign", rcodesign(), "--app-name", "NFSU2"]), 0)
            check = os.path.join(t, "check")
            app = signipa.unpack(out, check)
            info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
            self.assertEqual(info["CFBundleIdentifier"], "com.chlupiq.winpad.wine")
            self.assertEqual(info["CFBundleDisplayName"], "NFSU2")
            self.assertTrue(os.path.isfile(os.path.join(app, "embedded.mobileprovision")))
            resources = open(os.path.join(app, "_CodeSignature", "CodeResources"), "rb").read()
            self.assertIn(b"fexaot-nfsu2.dylib", resources)
            self.assertIn(b"embedded.mobileprovision", resources)
            main = self.signature(os.path.join(app, "WinPadWine"))
            self.assertIn(f"{TEAM}.com.chlupiq.winpad.wine", main)
            self.assertIn("Apple Development: Me", main)
            for rel in ("Frameworks/fexaot-nfsu2.dylib", "aarch64-windows/ntdll.dll.dylib"):
                lib_sig = self.signature(os.path.join(app, rel))
                self.assertIn("Apple Development: Me", lib_sig)
                self.assertNotIn("application-identifier", lib_sig)
            self.assertTrue(os.access(os.path.join(app, "WinPadWine"), os.X_OK))

    def signature(self, path):
        r = subprocess.run([rcodesign(), "print-signature-info", path], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout


class FakeRun:
    """Stands in for subprocess.run: Xcode's tools on a Mac."""

    def __init__(self, devices=None, fail=None):
        self.calls = []
        self.devices = devices if devices is not None else [
            {"identifier": "UUID-IPAD", "hardwareProperties": {"platform": "iOS", "udid": UDID, "deviceType": "iPad"},
             "deviceProperties": {"name": "Martin's iPad", "ddiServicesAvailable": True},
             "connectionProperties": {"pairingState": "paired", "tunnelState": "connected"}},
            {"identifier": "UUID-PHONE", "hardwareProperties": {"platform": "iOS", "udid": "PHONE", "deviceType": "iPhone"},
             "deviceProperties": {"name": "iPhone"}, "connectionProperties": {"pairingState": "paired",
                                                                              "tunnelState": "disconnected"}},
            {"identifier": "UUID-WATCH", "hardwareProperties": {"platform": "watchOS"}, "deviceProperties": {"name": "W"}}]
        self.fail = fail

    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        out = ""
        if cmd[:2] == ["security", "find-identity"]:
            out = ('  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Me (XYZ)"\n'
                   '     1 valid identities found\n')
        elif cmd[:2] == ["security", "find-certificate"]:
            out = "-----BEGIN CERTIFICATE-----\nMII\n-----END CERTIFICATE-----\n"
        elif cmd[0] == "openssl":
            out = f"subject=\n    organizationalUnitName    = {TEAM}\n    commonName = Apple Development: Me (XYZ)\n"
        elif cmd[:3] == ["xcrun", "devicectl", "list"]:
            with open(cmd[cmd.index("--json-output") + 1], "w") as f:
                json.dump({"result": {"devices": self.devices}}, f)
        elif cmd[0] == "xcodebuild":
            derived = cmd[cmd.index("-derivedDataPath") + 1]
            os.makedirs(os.path.join(derived, "Build", "Products", "Debug-iphoneos", "WinPadWine.app"), exist_ok=True)
        elif cmd[0] == "codesign":
            pass
        code = 1 if self.fail and self.fail in cmd else 0
        return subprocess.CompletedProcess(cmd, code, out, "failed" if code else "")


class MacInstallTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(install.sys, "platform", "darwin")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_xcode_project_built_for_team_and_installed(self):
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(os.path.join(t, "WinPadWine-xcode", "WinPadWine.xcodeproj"))
            run = FakeRun()
            app = install.install(install.Settings(), xcode_project=os.path.join(t, "WinPadWine-xcode"),
                                  work=t, log=lambda *_: None, run=run)
            build = next(c for c in run.calls if c[0] == "xcodebuild")
            self.assertIn(f"DEVELOPMENT_TEAM={TEAM}", build)
            self.assertIn("-allowProvisioningUpdates", build)
            self.assertIn("generic/platform=iOS", build)
            self.assertEqual(run.calls[-1], ["xcrun", "devicectl", "device", "install", "app", "--device", "UUID-IPAD", app])

    def test_ipa_signed_with_xcodes_profile(self):
        with tempfile.TemporaryDirectory() as t:
            profiles = os.path.join(t, "profiles")
            os.makedirs(profiles)
            write_profile(os.path.join(profiles, "x.mobileprovision"), certs=[])
            ipa = write_app_ipa(os.path.join(t, "WinPad.ipa"), {"WinPadWine": b"\xcf\xfa\xed\xfe" + b"\0" * 28,
                                                                 "Frameworks/fexaot-a.dylib": b"\xcf\xfa\xed\xfe" + b"\0" * 28})
            run = FakeRun()
            with mock.patch.object(signipa, "profile_folders", lambda: [profiles]), \
                    mock.patch.object(signipa.subprocess, "run", run):
                out = install.install(install.Settings(), ipa=ipa, work=t, log=lambda *_: None, run=run)
            self.assertTrue(out.endswith("WinPad-signed.ipa"))
            signs = [c for c in run.calls if c[0] == "codesign"]
            self.assertEqual(len(signs), 2)
            self.assertTrue(signs[0][-1].endswith("fexaot-a.dylib"))
            self.assertIn("--entitlements", signs[1])
            self.assertEqual(run.calls[-1][:7], ["xcrun", "devicectl", "device", "install", "app", "--device", "UUID-IPAD"])
            with zipfile.ZipFile(out) as z:
                self.assertIn("Payload/WinPadWine.app/embedded.mobileprovision", z.namelist())

    def test_no_profile_says_how(self):
        with tempfile.TemporaryDirectory() as t:
            ipa = write_app_ipa(os.path.join(t, "WinPad.ipa"), {"WinPadWine": b"\xcf\xfa\xed\xfe"})
            with mock.patch.object(signipa, "profile_folders", lambda: [t]):
                with self.assertRaisesRegex(install.InstallError, "Run once"):
                    install.install(install.Settings(), ipa=ipa, work=t, log=lambda *_: None, run=FakeRun())

    def test_device_choice(self):
        devices = install.devicectl_devices(FakeRun())
        self.assertEqual([d.name for d in devices], ["Martin's iPad", "iPhone"])
        self.assertEqual(install.choose_device(devices).identifier, "UUID-IPAD")
        self.assertEqual(install.choose_device(devices, "iphone").identifier, "UUID-PHONE")
        with self.assertRaises(install.InstallError):
            install.choose_device([])
        with self.assertRaisesRegex(install.InstallError, "several"):
            install.choose_device([install.Device("a", "1", kind="iPhone", connected=True),
                                   install.Device("b", "2", kind="iPhone", connected=True)])

    def test_project_run_installs(self):
        # project.run hands the Xcode project, with the image in it, to install.
        with tempfile.TemporaryDirectory() as t:
            p = project.Project(game_dir=t, work_dir=t, xcode_project=os.path.join(t, "x"), install=True,
                                install_device="iPad")
            with mock.patch.object(project.installmod, "install") as inst:
                project.sign_and_install(p, "", log=lambda *_: None)
            s = inst.call_args.args[0]
            self.assertEqual(s.device, "iPad")
            self.assertEqual(inst.call_args.kwargs["xcode_project"], os.path.join(t, "x"))


class OtherComputerTest(unittest.TestCase):
    def test_needs_certificate(self):
        with mock.patch.object(install.sys, "platform", "win32"):
            with self.assertRaisesRegex(install.InstallError, "p12"):
                install.install(install.Settings(), ipa="x.ipa", log=lambda *_: None)

    def test_settings_from_library(self):
        s = install.settings_from({"install_p12": "c.p12", "install_profile": "p", "cloud_repo": "me/sign"})
        self.assertEqual((s.p12, s.profile, s.cloud_repo, s.identity), ("c.p12", "p", "me/sign", "auto"))

    def test_library_installs_once(self):
        with tempfile.TemporaryDirectory() as t:
            lib = library.Library(ipa=os.path.join(t, "in.ipa"), settings={"install": True, "install_p12": "c.p12"})
            lib.games = []
            with self.assertRaises(project.TranslateError):
                library.build(lib)  # no games: nothing to install

    def test_cli_flags(self):
        args = cli.parser().parse_args(["--game", "g", "--install", "--p12", "c.p12", "--provisioning-profile", "p.mobileprovision",
                                        "--cloud-sign", "me/sign", "--device", "iPad"])
        self.assertTrue(args.install)
        self.assertEqual((args.install_p12, args.install_profile, args.cloud_repo, args.install_device),
                         ("c.p12", "p.mobileprovision", "me/sign", "iPad"))


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    """Releases, assets, a workflow that "signs" by appending a marker, secrets, contents."""
    state = None

    def log_message(self, *a):
        pass

    def reply(self, code, body=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n)

    def do_GET(self):
        s, path = self.state, self.path.split("?")[0]
        if path == "/repos/me/sign":
            return self.reply(200, {"private": s["private"], "default_branch": "main"})
        if path == "/user":
            return self.reply(200, {"login": "me"})
        if path.startswith("/repos/me/sign/contents/"):
            return self.reply(404, {"message": "Not Found"})
        if path == "/repos/me/sign/actions/secrets/public-key":
            return self.reply(200, {"key": s["public_key"], "key_id": "k1"})
        if path == "/repos/me/sign/actions/secrets":
            return self.reply(200, {"secrets": [{"name": n} for n in s["secrets"]]})
        if path.endswith("/runs"):
            runs = [{"id": 5, "display_title": f"WinPad sign {r}", "status": "completed", "conclusion": "success",
                     "html_url": "https://github.com/me/sign/actions/runs/5"} for r in s["dispatched"]]
            return self.reply(200, {"workflow_runs": runs})
        if path == "/repos/me/sign/releases/1/assets":
            return self.reply(200, [{"id": i, "name": n} for i, n in enumerate(s["assets"])])
        if path.startswith("/repos/me/sign/releases/assets/"):
            name = list(s["assets"])[int(path.rsplit("/", 1)[1])]
            # Like GitHub: off to storage, which must not get the token.
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/storage/{name}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path.startswith("/storage/"):
            s["storage_auth"] = self.headers.get("Authorization")
            return self.reply(200, raw=s["assets"][path.rsplit("/", 1)[1]])
        self.reply(404, {"message": path})

    def do_POST(self):
        s, path = self.state, self.path.split("?")[0]
        base = f"http://127.0.0.1:{self.server.server_port}"
        if path == "/repos/me/sign/releases":
            s["release"] = json.loads(self.body())
            return self.reply(201, {"id": 1, "upload_url": base + "/upload/releases/1/assets{?name,label}"})
        if path == "/upload/releases/1/assets":
            s["assets"][self.path.split("name=")[1]] = self.body()
            return self.reply(201, {})
        if path.endswith("/dispatches"):
            inputs = json.loads(self.body())["inputs"]
            s["dispatched"].append(inputs["release_id"])
            s["inputs"] = inputs
            s["assets"]["signed.ipa"] = s["assets"]["unsigned.ipa"] + b"signed"
            return self.reply(204)
        self.reply(404, {"message": path})

    def do_PUT(self):
        s, path = self.state, self.path
        if "/actions/secrets/" in path:
            s["secrets"][path.rsplit("/", 1)[1]] = json.loads(self.body())
            return self.reply(201, {})
        if "/contents/" in path:
            s["files"][path.split("/contents/")[1]] = base64.b64decode(json.loads(self.body())["content"])
            return self.reply(201, {})
        self.reply(404, {"message": path})

    def do_DELETE(self):
        self.state["deleted"].append(self.path)
        self.reply(204)


class CloudTest(unittest.TestCase):
    def setUp(self):
        self.state = {"private": True, "assets": {}, "dispatched": [], "secrets": {}, "files": {}, "deleted": [],
                      "public_key": base64.b64encode(b"\1" * 32).decode()}
        handler = type("H", (FakeGitHub,), {"state": self.state})
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.api = f"http://127.0.0.1:{self.server.server_port}"

    def cloud(self):
        return cloud.Cloud("me/sign", "tok", api=self.api, sleep=lambda s: None)

    def test_sign_round_trip(self):
        with tempfile.TemporaryDirectory() as t:
            ipa = os.path.join(t, "WinPad.ipa")
            with open(ipa, "wb") as f:
                f.write(b"IPA")
            out = self.cloud().sign(ipa, os.path.join(t, "WinPad-signed.ipa"), app_name="NFSU2", log=lambda *_: None)
            self.assertEqual(open(out, "rb").read(), b"IPAsigned")
            self.assertTrue(self.state["release"]["draft"])
            self.assertEqual(self.state["inputs"]["app_name"], "NFSU2")
            self.assertIsNone(self.state["storage_auth"])
            self.assertIn("/repos/me/sign/releases/1", self.state["deleted"])

    def test_public_repository_refused(self):
        self.state["private"] = False
        with self.assertRaisesRegex(cloud.CloudError, "public"):
            self.cloud().sign(__file__, "x", log=lambda *_: None)
        with self.assertRaisesRegex(cloud.CloudError, "public"):
            self.cloud().setup(log=lambda *_: None)

    def test_setup_puts_job_and_says_what_is_missing(self):
        lines = []
        self.assertFalse(self.cloud().setup(log=lines.append))
        self.assertIn(".github/workflows/winpad-sign.yml", self.state["files"])
        self.assertIn(b"def sign_ipa", self.state["files"]["winpad-sign/signipa.py"])
        self.assertIn("WINPAD_P12", "\n".join(lines))

    @unittest.skipUnless(REQUIRED or importlib_has("nacl"), "needs PyNaCl")
    def test_setup_stores_secrets_sealed(self):
        from nacl import encoding, public
        key = public.PrivateKey.generate()
        self.state["public_key"] = key.public_key.encode(encoding.Base64Encoder()).decode()
        with tempfile.TemporaryDirectory() as t:
            p12 = os.path.join(t, "c.p12")
            with open(p12, "wb") as f:
                f.write(b"P12DATA")
            prof = write_profile(os.path.join(t, "p.mobileprovision"))
            self.assertTrue(self.cloud().setup(p12, "pw", prof, log=lambda *_: None))
        box = public.SealedBox(key)
        secret = self.state["secrets"]["WINPAD_P12"]
        self.assertEqual(base64.b64decode(box.decrypt(base64.b64decode(secret["encrypted_value"]))), b"P12DATA")
        self.assertEqual(box.decrypt(base64.b64decode(self.state["secrets"]["WINPAD_P12_PASSWORD"]["encrypted_value"])),
                         b"pw")


if __name__ == "__main__":
    unittest.main()

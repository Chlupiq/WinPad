"""Command line of WinPad Translator; without arguments it opens the window (gui.py)."""
import argparse
import os
import sys

from . import __version__, compile as fexcompile, library, profiles, project


def parser():
    ap = argparse.ArgumentParser(
        prog="winpad-translator",
        description="Turns a game's FEX code maps (from the iPad, PC drcov logs or a static walk) into the "
                    "AOT image fexaot-<game>.dylib the WinPad Wine iPad app runs.")
    ap.add_argument("--version", action="version", version=__version__)
    ap.add_argument("--settings", help=f"read the settings from this file ({project.SETTINGS} in a work folder)")
    ap.add_argument("--game", dest="game_dir", help="the game's folder, as it is on the iPad")
    ap.add_argument("--work", dest="work_dir", help="where maps, caches and images are kept (default ~/WinPadTranslator/<game>)")
    ap.add_argument("--ipad-maps", action="append", default=[], metavar="FOLDER",
                    help="Documents/fexcache/<game> (or all of fexcache) copied off the iPad, or the zip the app's "
                         "\"Exportovat pro převodník\" shared (may be repeated)")
    ap.add_argument("--drcov", dest="drcov_logs", action="append", default=[], metavar="LOG",
                    help="DynamoRIO drcov log of the game run on a PC (may be repeated)")
    ap.add_argument("--discover", action="store_true", help="also find the .exe's code statically")
    ap.add_argument("--exe", help="the game's program, relative to its folder (default: from the maps or winpad.json)")
    ap.add_argument("--ipad-folder", help="the game folder's name on the iPad, if it differs")
    ap.add_argument("--ipa", help="the WinPad Wine IPA the iPad runs")
    ap.add_argument("--system-dir", help="or its i386-windows folder")
    ap.add_argument("--compiler", help="FEXOfflineCompiler.exe (default: from the toolkit)")
    ap.add_argument("--dispatcher", help="dispatcher.bin (default: from the toolkit)")
    ap.add_argument("--backend", choices=fexcompile.BACKENDS,
                    help=f"how the compiler runs (default here: {fexcompile.default_backend()})")
    ap.add_argument("--wine", help="the Wine command for --backend wine")
    ap.add_argument("--sim-work-dir", help="tests/wine-loader's work directory, for --backend simulator")
    ap.add_argument("--winpad-repo", help="a WinPad checkout, for --backend simulator")
    ap.add_argument("--compile-only", dest="link", action="store_false", default=None,
                    help="stop after compiling the code caches")
    ap.add_argument("--host-features", help="the iPad's CPU features as FEX_MADEIRA_HOSTPROBE "
                    "(default: hostprobe.txt next to the iPad's code maps)")
    ap.add_argument("--caches-per-run", type=int, help="caches one compiler process makes (default 8)")
    ap.add_argument("--compile-timeout", type=int, help="seconds one compiler process may take")
    ap.add_argument("--no-half-barrier", dest="half_barrier", action="store_false", default=None,
                    help="compile new blocks with ordered atomics (an iPad faults on unaligned ones)")
    ap.add_argument("--rebuild", action="store_true", default=None, help="generate every cache again")
    ap.add_argument("--simulator-image", action="store_true", default=None, help="also link an image for the iPad simulator")
    ap.add_argument("--out", dest="output_dir", help="folder to put the image in")
    ap.add_argument("--out-ipa", dest="output_ipa", help="write a copy of --ipa with the image in it")
    ap.add_argument("--app-name", help="the name under the app's icon on the iPad, e.g. the game's (default: WinPad Wine)")
    ap.add_argument("--xcode-project", help="put the image into this WinPadWine-xcode project's Frameworks")
    ap.add_argument("--sign-identity", help="Mac: also sign the image with this identity (auto: your Apple Development "
                    "one) into the game folder as fexaot.dylib, which the app loads without a new install")
    ap.add_argument("--package", metavar="FILE", help="also write the game as one .winpad file (FILE, or a folder for "
                    "<game>.winpad) to open on the iPad from AirDrop or Files")
    ap.add_argument("--package-no-game", dest="package_game", action="store_false", default=None,
                    help="the package holds only the game's settings, cover and signed image, not its files")
    ap.add_argument("--package-only", action="store_true",
                    help="only write the --package of the game folder as it is, translate nothing")
    rec = ap.add_argument_group("play and record: the game runs here and its code is recorded (record.py)")
    rec.add_argument("--record", action="store_true",
                     help="start the game and record the code it runs while you play, then translate with it: "
                     "Windows under DynamoRIO (downloaded the first time), a Mac in an iPad simulator "
                     "(needs --xcode-project)")
    rec.add_argument("--record-only", action="store_true", help="only record (the next translation takes it)")
    rec.add_argument("--dynamorio", help="Windows: DynamoRIO's folder (default: found, else downloaded)")
    prof = ap.add_argument_group("game profiles: settings a known game needs, put into its winpad.json")
    prof.add_argument("--profile", metavar="ID",
                      help="auto: find the game's profile by its files or Steam app (default); none: take it out; "
                      "or a profile's id")
    prof.add_argument("--list-profiles", action="store_true", help="list the game profiles there are")
    prof.add_argument("--profile-only", action="store_true",
                      help="only put the profile into --game's winpad.json, translate nothing")
    inst = ap.add_argument_group("sign and install: the app goes onto the iPad in one step (install.py)")
    inst.add_argument("--install", action="store_true", default=None,
                      help="sign the app and install it on the iPad: on a Mac with Xcode's Apple ID (with "
                      "--xcode-project Xcode builds it for your team), elsewhere with --p12 and --provisioning-profile or --cloud-sign")
    inst.add_argument("--sign-only", action="store_true", default=None, help="only write the signed IPA, do not install")
    inst.add_argument("--device", dest="install_device", help="the iPad's name or UDID (default: the one connected)")
    inst.add_argument("--team", dest="install_team", help="Mac: your team ID (default: the identity's)")
    inst.add_argument("--identity", dest="install_identity",
                      help="Mac: the keychain identity to sign with (default: your Apple Development one)")
    inst.add_argument("--p12", dest="install_p12", help="your certificate with its key (.p12): sign with rcodesign")
    inst.add_argument("--p12-password", help="its password (or the WINPAD_P12_PASSWORD variable); not saved")
    inst.add_argument("--provisioning-profile", "--mobileprovision", dest="install_profile",
                      help="the provisioning profile (.mobileprovision); --profile is the game profile")
    inst.add_argument("--bundle-id", dest="install_bundle_id",
                      help="the app's bundle identifier (default: as it is, or what the profile allows)")
    inst.add_argument("--cloud-sign", dest="cloud_repo", metavar="OWNER/REPO",
                      help="sign in GitHub Actions of this private repository (set up with --cloud-setup)")
    inst.add_argument("--github-token", help="for --cloud-sign/--cloud-setup (or GITHUB_TOKEN); --cloud-setup saves it")
    inst.add_argument("--cloud-setup", metavar="OWNER/REPO",
                      help="make the private repository (if needed), put the signing job into it and store --p12, "
                      "its password and --provisioning-profile as its secrets; then stop")
    inst.add_argument("--cert-request", metavar="EMAIL",
                      help="without a Mac: make a key and a certificate request for developer.apple.com, then stop")
    inst.add_argument("--cert-p12", metavar="CER",
                      help="then: the certificate (.cer) Apple gave for it -> a .p12 (--p12, default "
                      "~/WinPadTranslator/certificate/winpad.p12, password --p12-password); then stop")
    lib = ap.add_argument_group("a library of games: several games in one app")
    lib.add_argument("--library", nargs="?", const=library.default_path(), metavar="FILE",
                     help=f"work on the library in FILE (default {library.default_path()}); --ipa, --out-ipa, "
                     "--xcode-project, --app-name and the compiler settings are kept in it")
    lib.add_argument("--add-game", action="append", default=[], metavar="FOLDER",
                     help="add a game folder (--exe, --ipad-folder apply to it)")
    lib.add_argument("--remove-game", action="append", default=[], metavar="NAME", help="take a game off the list")
    lib.add_argument("--list-games", action="store_true", help="list the games")
    lib.add_argument("--build", action="store_true",
                     help="translate the games with new code maps in --ipad-maps and write the app with all of them")
    lib.add_argument("--package-dir", metavar="FOLDER",
                     help="with --build: also write a .winpad package of each game translated into FOLDER")
    return ap


PATH_KEYS = ("dynamorio", "winpad_repo", "ipa", "compiler", "dispatcher", "output_ipa", "xcode_project", "package", "install_p12",
             "install_profile", "cert_p12")
# Arguments that are not settings of a game.
NOT_SETTINGS = ("settings", "library", "add_game", "remove_game", "list_games", "build", "p12_password",
                "github_token", "cloud_setup", "cert_request", "cert_p12", "package_dir", "package_only",
                "list_profiles", "profile_only", "record", "record_only")


def certificate_main(args):
    """--cert-request, --cert-p12: the certificate as a .p12 without a Mac (applecert.py)."""
    from . import applecert
    folder = os.path.join(os.path.expanduser("~"), "WinPadTranslator", "certificate")
    if args.cert_request:
        req = applecert.request(folder, args.cert_request)
        print(f"{req}: upload it at https://developer.apple.com/account/resources/certificates/add "
              "(Apple Development), download the certificate and run again with --cert-p12 FILE.cer. "
              f"Keep {os.path.join(folder, 'winpad-key.pem')}: it is your certificate's private key.")
    if args.cert_p12:
        if not args.p12_password:
            raise SystemExit("error: give the .p12 a password (--p12-password)")
        out = args.install_p12 or os.path.join(folder, "winpad.p12")
        name = applecert.make_p12(folder, args.cert_p12, out, args.p12_password)
        print(f"{out}: {name}. Make a profile with it: https://developer.apple.com/account/resources/profiles/add "
              "(iOS App Development, the app's identifier, this certificate, your iPad)")


def cloud_setup_main(args):
    from . import cloud, install
    tok = cloud.token(args.github_token)
    c = cloud.Cloud(args.cloud_setup, tok)
    ready = c.setup(args.install_p12, install.p12_password(args.p12_password) if args.install_p12 else None,
                    args.install_profile)
    if args.github_token:
        print(f"token saved to {cloud.save_token(args.github_token)} (only you can read it)")
    print(f"{args.cloud_setup} is " + ("ready: translate with --cloud-sign " + args.cloud_setup if ready
                                       else "set up, but its secrets are missing"))


def library_main(args):
    path = os.path.abspath(args.library)
    lib = library.Library.load(path)
    for key in ("ipa", "output_ipa", "xcode_project", "app_name", "package_dir", "package_game"):
        if getattr(args, key) is not None:
            setattr(lib, key, getattr(args, key))
    for key in library.SHARED + library.INSTALL:
        value = getattr(args, key, None)
        if value is not None:
            lib.settings[key] = value
    for folder in args.add_game:
        p = lib.add(folder, exe=args.exe or "", ipad_folder=args.ipad_folder or "", profile=args.profile or "")
        print(f"added {p.folder_name()} (image {p.image_name()}, work folder {p.work_dir})")
        profiles.apply(p.game_dir, p.profile)
    for name in args.remove_game:
        print(f"removed {lib.remove(name).folder_name()}")
    lib.save(path)
    if args.list_games or not (args.add_game or args.remove_game or args.build):
        for p in lib.projects():
            state = "image ready" if os.path.isfile(library.image_of(p)) else "no image yet"
            print(f"{p.folder_name()}: {p.game_dir} ({p.image_name()}, {state})")
    if args.build:
        library.build(lib, args.ipad_maps, rebuild=bool(args.rebuild))
        lib.save(path)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    # A Windows console's code page (cp1252...) lacks letters of the profiles' Czech notes:
    # print what it can instead of failing.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    if not argv:
        from . import gui
        return gui.main()
    args = parser().parse_args(argv)
    if args.list_profiles:
        for prof in profiles.load_all().values():
            how = ", ".join(f"Steam {r['steamAppId']}" if "steamAppId" in r else
                            " + ".join([r["exe"]] + r.get("files", [])) for r in prof["match"])
            print(f"{prof['id']} v{prof['version']}: {prof.get('title', '')} ({how})")
        return 0
    for key, value in vars(args).items():
        if key in ("remove_game", "library", "cloud_setup", "cloud_repo", "github_token", "p12_password",
                   "cert_request") or value in (None, []):
            continue
        if isinstance(value, list):
            setattr(args, key, [os.path.abspath(v) for v in value])
        elif key.endswith("_dir") or key in PATH_KEYS:
            # A trailing separator says "a folder" (package.write); keep it.
            sep = os.sep if isinstance(value, str) and value.endswith(("/", os.sep)) else ""
            setattr(args, key, os.path.abspath(value) + sep)
    if args.p12_password:
        os.environ["WINPAD_P12_PASSWORD"] = args.p12_password
    if args.cloud_repo and args.install is None:
        args.install = True
    if args.cert_request or args.cert_p12 or args.cloud_setup:
        try:
            if args.cert_request or args.cert_p12:
                certificate_main(args)
            if args.cloud_setup:
                cloud_setup_main(args)
        except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0
    if args.library:
        try:
            library_main(args)
        except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0
    p = project.Project.load(args.settings) if args.settings else project.Project()
    for key, value in vars(args).items():
        if key in NOT_SETTINGS or value in (None, []):
            continue
        setattr(p, key, value)
    try:
        if args.profile_only:
            if not p.game_dir or not os.path.isdir(p.game_dir):
                raise project.TranslateError(f"no game folder: {p.game_dir}")
            profiles.apply(p.game_dir, p.profile)
            return 0
        if args.record or args.record_only:
            from . import record
            record.record(p)
            if args.record_only:
                p.save()
                print(f"recorded; translate with --settings {os.path.join(p.work_dir, project.SETTINGS)}")
                return 0
        if args.package_only:
            if not p.package:
                raise project.TranslateError("--package-only needs --package FILE")
            project.write_package(p)
        else:
            project.run(p)
    except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0

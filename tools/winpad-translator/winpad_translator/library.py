"""A library of games for one WinPad Wine app: several games' images in one IPA.

The app's game library (tests/wine-app/Library.m) lists every game folder in its
Documents and starts each with its own image, Frameworks/fexaot-<game>.dylib. So one
app holds any number of games: the library lists them (each a game folder with its
work folder and settings, project.py), translates each from the code maps copied off
the iPad and writes one IPA (or Xcode project) with all their images.

The app keeps each game's code maps in Documents/fexcache/<game folder> (before, all in
Documents/fexcache/codemap/new); the whole fexcache folder can be given, and
each game takes its own from it (project.Project.own_maps_only).

Adding a game means translating it and installing the app again, over the old one, so
the games and settings in its Documents stay. On a Mac, with sign_identity, each image
also goes signed into its game folder, and the app loads it from there without a new
install (project.into_game_folder).
"""
import dataclasses
import json
import os

from . import codemaps, ipa as ipamod, package as packagemod, project

LIBRARY = "library.json"
APP_NAME = "WinPad"
# The settings of how to compile, which the library gives every game.
SHARED = ("backend", "compiler", "dispatcher", "wine", "sim_work_dir", "winpad_repo", "host_features",
          "caches_per_run", "compile_timeout", "half_barrier", "simulator_image", "sign_identity")


def default_path():
    return os.path.join(os.path.expanduser("~"), "WinPadTranslator", LIBRARY)


@dataclasses.dataclass
class Library:
    # The work folders of the games (each with its winpad-translator.json).
    games: list = dataclasses.field(default_factory=list)
    # The WinPad Wine IPA from CI the app is made from (not one this wrote).
    ipa: str = ""
    output_ipa: str = ""
    xcode_project: str = ""
    # The name under the icon; empty: "WinPad".
    app_name: str = ""
    # Write a WinPad package (.winpad) of each game translated by build() into this folder.
    package_dir: str = ""
    # Whether those packages hold the games' files too (else only settings, cover, signed image).
    package_game: bool = True
    # Settings of SHARED for every game.
    settings: dict = dataclasses.field(default_factory=dict)

    def save(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump(dataclasses.asdict(self), f, indent=2)

    @classmethod
    def load(cls, path):
        """The library at PATH, or an empty one if there is none yet."""
        if not os.path.isfile(path):
            return cls()
        with open(path) as f:
            data = json.load(f)
        known = {f.name for f in dataclasses.fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})

    def projects(self):
        return [project.Project.load(os.path.join(w, project.SETTINGS)) for w in self.games]

    def add(self, game_dir, exe="", ipad_folder="", work_dir=""):
        """Adds the game in GAME_DIR (or updates its program and iPad folder). Returns its Project."""
        game_dir = os.path.abspath(game_dir)
        if not os.path.isdir(game_dir):
            raise project.TranslateError(f"no folder {game_dir}")
        work_dir = os.path.abspath(work_dir or project.default_work_dir(game_dir))
        settings = os.path.join(work_dir, project.SETTINGS)
        p = project.Project.load(settings) if os.path.isfile(settings) else project.Project(work_dir=work_dir)
        if p.game_dir and os.path.normcase(p.game_dir) != os.path.normcase(game_dir):
            raise project.TranslateError(f"{work_dir} is the work folder of {p.game_dir}; give this game another one")
        for other in self.projects():
            if other.work_dir != work_dir and other.slug() == codemaps.slug(os.path.basename(game_dir)):
                raise project.TranslateError(
                    f"{other.game_dir} already has the image {other.image_name()}: the app tells games apart by "
                    "their folder's name, so rename one of the folders (here and on the iPad)")
        p.game_dir, p.work_dir = game_dir, work_dir
        p.exe = exe or p.exe
        p.ipad_folder = ipad_folder or p.ipad_folder
        p.save()
        if work_dir not in self.games:
            self.games.append(work_dir)
        return p

    def remove(self, name):
        """Takes the game named NAME (its folder's name, image slug or work folder) off the
        list; its work folder stays. Returns its Project."""
        for w, p in zip(list(self.games), self.projects()):
            if name in (p.folder_name(), p.slug(), w) or os.path.abspath(name) in (p.game_dir, w):
                self.games.remove(w)
                return p
        raise project.TranslateError(f"no game {name} in the library")


def image_of(p):
    return os.path.join(p.work_dir, "image-iphoneos", p.image_name())


def has_own_maps(p, folders):
    """Whether FOLDERS (copied off the iPad) hold code maps of P's game."""
    own = (p.ipad_folder or p.folder_name()).lower()
    for folder in folders:
        for m in codemaps.map_files(folder):
            if own in (f.lower() for f in codemaps.map_folders(m)):
                return True
    return False


def imports_dir():
    return os.path.join(os.path.dirname(default_path()), "imports")


def build(lib, ipad_maps=(), rebuild=False, log=print, imports=None):
    """Translates each game with new code maps in IPAD_MAPS (folders copied off the iPad, or zips
    its "Exportovat pro převodník" shared; those are unpacked under IMPORTS) or without an image
    yet, and writes the app with every game's image. Returns the images in it."""
    if not lib.games:
        raise project.TranslateError("the library has no games yet: add a game folder")
    if not lib.ipa and not lib.xcode_project:
        raise project.TranslateError("give the WinPad Wine IPA from CI (or a WinPadWine-xcode project)")
    if not lib.output_ipa and not lib.xcode_project:
        raise project.TranslateError("say where the app goes: an IPA to write (or a WinPadWine-xcode project)")
    if lib.ipa and lib.output_ipa and os.path.abspath(lib.ipa) == os.path.abspath(lib.output_ipa):
        raise project.TranslateError("write the app to another IPA than the one it is made from")
    ipad_maps, manifests = codemaps.unpack(ipad_maps, imports or imports_dir(), log)
    projects = lib.projects()
    known = {(p.ipad_folder or p.folder_name()).lower() for p in projects}
    for manifest in manifests:
        folder = codemaps.export_folder(manifest)
        if folder and folder.lower() not in known:
            log(f"##### the export of {folder} is of no game in the library: add its game folder "
                "(--add-game, or + in Game library) and build again")
    images = []
    for p in projects:
        for key in SHARED:
            if key in lib.settings:
                setattr(p, key, lib.settings[key])
        p.ipa, p.xcode_project = lib.ipa, lib.xcode_project
        p.output_ipa, p.output_dir, p.app_name, p.package = "", "", "", ""
        p.own_maps_only = True
        p.rebuild = p.rebuild or rebuild
        image = image_of(p)
        new = has_own_maps(p, ipad_maps)
        translated = False
        if new or p.drcov_logs or p.discover or p.rebuild or (not os.path.isfile(image) and
                                                               os.path.isdir(os.path.join(p.work_dir, "fexcache", "cache"))):
            p.ipad_maps = list(ipad_maps) if new else []
            log(f"##### {p.folder_name()}")
            project.run(p, log=log)
            translated = True
        elif os.path.isfile(image):
            log(f"##### {p.folder_name()}: no new code maps, its image {p.image_name()} stays")
            if p.sign_identity and not os.path.isfile(os.path.join(p.game_dir, project.GAME_FOLDER_IMAGE)):
                project.into_game_folder(p, image, log)
        else:
            log(f"##### {p.folder_name()}: no code maps yet. Play it on the iPad (it runs in the interpreter, "
                "slowly), copy WinPad Wine › fexcache off it and build the library again")
            continue
        if os.path.isfile(image):
            images.append(image)
            package = os.path.join(lib.package_dir, (p.ipad_folder or p.folder_name()) + packagemod.EXTENSION) \
                if lib.package_dir else ""
            if package and (translated or not os.path.isfile(package)):
                p.package, p.package_game = package, lib.package_game
                project.write_package(p, log)
    name = lib.app_name or APP_NAME
    if lib.output_ipa:
        ipamod.add_images(lib.ipa, lib.output_ipa, images, name)
        log(f"=== {lib.output_ipa}: {name} with {len(images)} games' images, for AltStore, SideStore or Sideloadly")
    if lib.xcode_project and os.path.isfile(os.path.join(lib.xcode_project, "Info.plist")):
        ipamod.rename_app(os.path.join(lib.xcode_project, "Info.plist"), name)
        log(f"=== {lib.xcode_project}: {len(images)} games' images, app name {name}")
    log("Done. Install the app over the old one (its Documents stay) and copy each game folder into its "
        "Documents if it is not there yet.")
    return images

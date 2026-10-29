"""Ways to run FEX's offline compiler (FEXOfflineCompiler.exe, an aarch64 Windows program).

The compiler only generates arm64 code, it never runs it, and its host features
are fixed for Apple's cores (FEX_IOS_HOST), so its caches do not depend on the
computer it runs on. It needs an arm64 Windows to run in:

  simulator  Wine in an iPad simulator, as tests/wine-app/game-aot.sh does it
             (a Mac with Xcode and a WinPad build directory, tests/wine-loader).
  wine       Wine on an arm64 Linux (or any Wine command that runs aarch64 PE).
  native     Windows on ARM runs it as it is.
  docker     Wine in an arm64 Linux container (docker --platform linux/arm64),
             which an x86-64 PC or Mac emulates (Docker Desktop, QEMU): slow,
             but it needs nothing else.

Every backend runs process-all a few caches at a time (patches/fex-wow64/0028),
until no code map is left to compile.
"""
import os
import re
import shutil
import subprocess
import sys

from . import paths

BACKENDS = ("simulator", "wine", "native", "docker")
PROGRESS = re.compile(r"\[process-all\] (\d+) caches generated \((\d+) failed\), (\d+) left")
DOCKER_IMAGE = "winpad-translator-wine:1"


class CompileError(Exception):
    pass


def default_backend():
    if sys.platform == "darwin":
        return "simulator"
    if os.name == "nt":
        machine = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE", "")
        return "native" if machine.upper() == "ARM64" else "docker"
    import platform
    return "wine" if platform.machine().lower() in ("aarch64", "arm64") else "docker"


def windows_path(local):
    """A path here as Wine names it (Z: is the Unix root) or as Windows does."""
    if os.name == "nt":
        return os.path.abspath(local)
    return "Z:" + os.path.abspath(local).replace("/", "\\")


class Backend:
    name = ""

    def __init__(self, compiler, cache_dir, log=print, per_run=8, timeout=None):
        self.compiler = compiler
        self.cache_dir = os.path.abspath(cache_dir)
        self.log = log
        self.per_run = per_run
        self.timeout = timeout

    def image_name(self, local):
        """The name the compiler opens LOCAL by: an NT path as FEX writes them."""
        return "\\??\\" + windows_path(local)

    def keep_name(self, name):
        """True for an image name the compiler's Wine has as it is."""
        return False

    def command(self, args):
        raise NotImplementedError

    def environment(self):
        env = dict(os.environ)
        env["FEX_APP_CACHE_LOCATION"] = windows_path(self.cache_dir) + "\\"
        return env

    def run_once(self):
        cmd = self.command(["process-all", "--max-caches", str(self.per_run)])
        self.log("$ " + " ".join(cmd))
        proc = subprocess.Popen(cmd, env=self.environment(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace")
        last = None
        for line in proc.stdout:
            line = line.rstrip()
            m = PROGRESS.search(line)
            if m:
                last = tuple(int(x) for x in m.groups())
            if m or "error" in line.lower() or "Couldn't" in line or "Successfully" in line:
                self.log("  " + line)
        proc.stdout.close()
        proc.wait(timeout=self.timeout)
        if last is None:
            raise CompileError(f"the offline compiler ended (exit {proc.returncode}) without its [process-all] line")
        return last

    def compile(self):
        prev = None
        while True:
            generated, failed, left = self.run_once()
            self.log(f"=== {generated} caches generated ({failed} failed), {left} left")
            if left == 0:
                break
            # A cache that fails is generated again first in the next process; when that
            # leaves nothing for the rest, stop.
            if prev is not None and left >= prev:
                raise CompileError(f"process-all made no progress: {left} caches still left")
            prev = left
        caches = os.path.join(self.cache_dir, "cache")
        if not os.path.isdir(caches) or not any(os.path.getsize(os.path.join(caches, n)) for n in os.listdir(caches)):
            raise CompileError(f"no code caches in {caches}")


class Native(Backend):
    name = "native"

    def command(self, args):
        return [self.compiler] + args


class Wine(Backend):
    name = "wine"

    def __init__(self, *a, wine="wine", **kw):
        super().__init__(*a, **kw)
        self.wine = wine

    def command(self, args):
        return [self.wine, self.compiler] + args

    def environment(self):
        env = super().environment()
        env.setdefault("WINEDEBUG", "-all")
        env.setdefault("WINEPREFIX", os.path.join(self.cache_dir, "wineprefix"))
        return env


class Docker(Backend):
    """Wine in an arm64 container; the cache directory, the game and the DLLs are
    mounted at the same paths under /host, so names stay valid in and out."""
    name = "docker"

    def __init__(self, *a, mounts=(), docker="docker", **kw):
        super().__init__(*a, **kw)
        self.docker = docker
        self.mounts = [os.path.abspath(m) for m in mounts]

    def container_path(self, local):
        p = os.path.abspath(local)
        if os.name == "nt":
            drive, rest = os.path.splitdrive(p)
            return "/host/" + drive.rstrip(":").lower() + rest.replace("\\", "/")
        return "/host" + p

    def image_name(self, local):
        return "\\??\\Z:" + self.container_path(local).replace("/", "\\")

    def ensure_image(self):
        if subprocess.run([self.docker, "image", "inspect", DOCKER_IMAGE], capture_output=True).returncode == 0:
            return
        self.log(f"=== building the container image {DOCKER_IMAGE} (once; it needs the network)")
        subprocess.run([self.docker, "build", "--platform", "linux/arm64", "-t", DOCKER_IMAGE,
                        os.path.join(paths.DATA, "docker")], check=True)

    def command(self, args):
        cmd = [self.docker, "run", "--rm", "--platform", "linux/arm64"]
        for m in sorted(set(self.mounts + [self.cache_dir, os.path.dirname(os.path.abspath(self.compiler))])):
            cmd += ["-v", f"{m}:{self.container_path(m)}"]
        cache = "Z:" + self.container_path(self.cache_dir).replace("/", "\\") + "\\"
        # The image's own Wine prefix, made when it was built (data/docker/Dockerfile).
        cmd += ["-e", f"FEX_APP_CACHE_LOCATION={cache}", "-e", "WINEDEBUG=-all", DOCKER_IMAGE,
                "wine", self.container_path(self.compiler)]
        return cmd + args

    def compile(self):
        self.ensure_image()
        super().compile()


class Simulator(Backend):
    """Wine in an iPad simulator on a Mac (tests/fex-wow64/process-all-batches.sh), with
    the work directory tests/wine-loader/build*.sh made. Its Wine prefix has the
    i386 DLLs under C:\\windows\\syswow64, so those names stay."""
    name = "simulator"

    def __init__(self, *a, work_dir=None, repo=None, jit_pool_mb=4096, **kw):
        super().__init__(*a, **kw)
        if not work_dir:
            raise CompileError("the simulator backend needs the WinPad build directory (tests/wine-loader)")
        self.work_dir = work_dir
        self.script = os.path.join(repo or paths.ROOT, "tests", "fex-wow64", "process-all-batches.sh")
        if not os.path.isfile(os.path.join(os.path.dirname(self.script), "..", "wine-loader", "run-host.sh")):
            raise CompileError("the simulator backend runs the WinPad repository's scripts: give its checkout")
        self.jit_pool_mb = jit_pool_mb

    def keep_name(self, name):
        return bool(re.match(r"^\\\?\?\\C:\\windows\\", name, re.IGNORECASE))

    def compile(self):
        env = dict(os.environ)
        for k in ("WINEHOST_EXPECT_EXIT", "WINEHOST_DLLOVERRIDES", "WINEHOST_EXPECT_OUTPUT"):
            env.pop(k, None)
        env.update(WINEHOST_FEX_CACHE=self.cache_dir, WINEHOST_SECONDS=str(self.timeout or 1800),
                   WINEHOST_SYSWOW64="1", WINEHOST_JIT="1", WINEHOST_JIT_POOL_MB=str(self.jit_pool_mb))
        cmd = ["sh", self.script, self.work_dir, self.compiler, str(self.per_run)]
        self.log("$ " + " ".join(cmd))
        proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                errors="replace")
        for line in proc.stdout:
            self.log("  " + line.rstrip())
        proc.stdout.close()
        if proc.wait() != 0:
            raise CompileError("the offline compiler in the simulator failed (see the log above)")


def make_backend(name, compiler, cache_dir, log=print, **options):
    if name not in BACKENDS:
        raise CompileError(f"unknown backend {name}; one of {', '.join(BACKENDS)}")
    if not compiler or not os.path.isfile(compiler):
        raise CompileError(f"FEXOfflineCompiler.exe not found: {compiler}")
    common = {k: options[k] for k in ("per_run", "timeout") if options.get(k)}
    if name == "native":
        return Native(compiler, cache_dir, log=log, **common)
    if name == "wine":
        wine = options.get("wine") or shutil.which("wine") or "wine"
        return Wine(compiler, cache_dir, log=log, wine=wine, **common)
    if name == "docker":
        return Docker(compiler, cache_dir, log=log, mounts=options.get("mounts", ()), **common)
    return Simulator(compiler, cache_dir, log=log, work_dir=options.get("work_dir"), repo=options.get("repo"), **common)

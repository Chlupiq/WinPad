"""Signing in the cloud: a GitHub Actions job in your own private repository signs the app.

For a Windows PC without anything to sign with. Once (setup): the translator makes a
private repository (or takes yours), puts the signing job (data/cloud-sign/winpad-sign.yml)
and signipa.py into it and stores your certificate (.p12, its password) and profile as
the repository's secrets, encrypted with the repository's key as GitHub asks.

Then each time (sign): it uploads the IPA to a draft release of that repository, starts
the job, waits for it, downloads the signed IPA and deletes the release. The IPA holds
your games' translated code, so the repository must be private: setup refuses a public one.

It takes a GitHub token (Settings > Developer settings > Fine-grained token: that
repository, Contents, Actions, Secrets and Administration read and write; or a classic
token with repo and workflow).
"""
import base64
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
WORKFLOW = "winpad-sign.yml"
HERE = os.path.dirname(os.path.abspath(__file__))
SECRETS = ("WINPAD_P12", "WINPAD_P12_PASSWORD", "WINPAD_PROFILE")


class CloudError(Exception):
    pass


def data_dir():
    import sys
    base = getattr(sys, "_MEIPASS", None)
    if base:
        return os.path.join(base, "tools", "winpad-translator", "data", "cloud-sign")
    return os.path.join(HERE, "..", "data", "cloud-sign")


def signipa_source():
    """signipa.py's source: next to the job in the packaged app (which has no .py files), else here."""
    packed = os.path.join(data_dir(), "signipa.py")
    return packed if os.path.isfile(packed) else os.path.join(HERE, "signipa.py")


def token_file():
    return os.path.join(os.path.expanduser("~"), "WinPadTranslator", "github-token")


def token(value=""):
    """The GitHub token: VALUE, GITHUB_TOKEN/WINPAD_GITHUB_TOKEN, the file setup saved it to, or gh's."""
    for t in (value, os.environ.get("WINPAD_GITHUB_TOKEN"), os.environ.get("GITHUB_TOKEN")):
        if t:
            return t.strip()
    try:
        with open(token_file()) as f:
            t = f.read().strip()
            if t:
                return t
    except OSError:
        pass
    if shutil.which("gh"):
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    raise CloudError("no GitHub token: give one (--github-token, or the GITHUB_TOKEN variable)")


def save_token(value):
    path = token_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value.strip() + "\n")
    return path


class _NoAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Release assets redirect to storage that refuses a second credential."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            for h in ("Authorization",):
                new.headers.pop(h, None)
                new.unredirected_hdrs.pop(h, None)
        return new


def seal(public_key_b64, value):
    """VALUE encrypted for a repository's secrets key (libsodium sealed box, as GitHub asks)."""
    try:
        from nacl import encoding, public
    except ImportError:
        raise CloudError("storing secrets needs PyNaCl (pip install pynacl); or add them by hand on GitHub")
    box = public.SealedBox(public.PublicKey(public_key_b64.encode(), encoding.Base64Encoder()))
    return base64.b64encode(box.encrypt(value.encode() if isinstance(value, str) else value)).decode()


class Cloud:
    def __init__(self, repo, tok, api=API, sleep=time.sleep, poll=10):
        if repo.count("/") != 1:
            raise CloudError(f"give the repository as owner/name, not {repo}")
        self.repo = repo
        self.token = tok
        self.api = api.rstrip("/")
        self.sleep = sleep
        self.poll = poll
        self.opener = urllib.request.build_opener(_NoAuthOnRedirect)

    # -- HTTP --
    def call(self, method, path, body=None, data=None, headers=None, raw=False, ok=(200, 201, 202, 204)):
        url = path if path.startswith("http") else self.api + path
        h = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
             "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "winpad-translator"}
        h.update(headers or {})
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=600) as r:
                payload = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            status, payload = e.code, e.read()
            if status not in ok:
                try:
                    msg = json.loads(payload).get("message", "")
                except ValueError:
                    msg = payload[:200].decode("utf-8", "replace")
                raise CloudError(f"GitHub {method} {path}: {status} {msg}") from None
        except urllib.error.URLError as e:
            raise CloudError(f"GitHub {method} {path}: {e.reason}") from None
        if raw:
            return payload
        return (json.loads(payload) if payload else {}), status

    # -- setup --
    def setup(self, p12=None, p12_password=None, profile=None, log=print):
        """Makes the private repository if needed, puts the job into it and stores the secrets given."""
        repo, status = self.call("GET", f"/repos/{self.repo}", ok=(200, 404))
        if status == 404:
            me, _ = self.call("GET", "/user")
            owner, name = self.repo.split("/")
            if owner.lower() != me.get("login", "").lower():
                raise CloudError(f"{self.repo} does not exist; make it on GitHub (private) or name one of yours")
            repo, _ = self.call("POST", "/user/repos", {
                "name": name, "private": True, "auto_init": True,
                "description": "Signs my WinPad apps (WinPad Translator's cloud signing)"})
            log(f"=== made the private repository {self.repo}")
        if not repo.get("private"):
            raise CloudError(f"{self.repo} is public: the app holds your games' code, so sign in a private repository")
        branch = repo.get("default_branch") or "main"
        for local, remote in ((os.path.join(data_dir(), WORKFLOW), f".github/workflows/{WORKFLOW}"),
                              (signipa_source(), "winpad-sign/signipa.py")):
            with open(local, "rb") as f:
                self.put_file(remote, f.read(), branch)
            log(f"  {remote}")
        stored = []
        values = {}
        if p12:
            with open(p12, "rb") as f:
                values["WINPAD_P12"] = base64.b64encode(f.read()).decode()
            values["WINPAD_P12_PASSWORD"] = p12_password or ""
        if profile:
            with open(profile, "rb") as f:
                values["WINPAD_PROFILE"] = base64.b64encode(f.read()).decode()
        if values:
            key, _ = self.call("GET", f"/repos/{self.repo}/actions/secrets/public-key")
            for name, value in values.items():
                self.call("PUT", f"/repos/{self.repo}/actions/secrets/{name}",
                          {"encrypted_value": seal(key["key"], value), "key_id": key["key_id"]})
                stored.append(name)
            log(f"  secrets {', '.join(stored)}")
        missing = [s for s in SECRETS if s not in stored and s != "WINPAD_P12_PASSWORD"]
        if missing:
            have, _ = self.call("GET", f"/repos/{self.repo}/actions/secrets")
            names = {s["name"] for s in have.get("secrets", [])}
            missing = [s for s in missing if s not in names]
        if missing:
            log(f"  ! still missing: {', '.join(missing)} (give --p12 and --provisioning-profile, or add them at "
                f"https://github.com/{self.repo}/settings/secrets/actions)")
        return not missing

    def put_file(self, path, content, branch):
        current, status = self.call("GET", f"/repos/{self.repo}/contents/{path}?ref={branch}", ok=(200, 404))
        body = {"message": f"WinPad Translator: {path}", "branch": branch,
                "content": base64.b64encode(content).decode()}
        if status == 200:
            if base64.b64decode(current.get("content", "")) == content:
                return
            body["sha"] = current["sha"]
        self.call("PUT", f"/repos/{self.repo}/contents/{path}", body)

    # -- signing --
    def sign(self, ipa, out, bundle_id="", app_name="", log=print, timeout=1800):
        repo, _ = self.call("GET", f"/repos/{self.repo}")
        if not repo.get("private"):
            raise CloudError(f"{self.repo} is public: the app holds your games' code, so sign in a private repository")
        tag = f"winpad-sign-{int(time.time())}"
        release, _ = self.call("POST", f"/repos/{self.repo}/releases", {
            "tag_name": tag, "name": tag, "draft": True, "body": "WinPad Translator: signing, deleted when done"})
        rid = release["id"]
        try:
            size = os.path.getsize(ipa)
            log(f"=== uploading {os.path.basename(ipa)} ({size // (1024 * 1024)} MB) to {self.repo} for signing")
            upload = release["upload_url"].split("{")[0]
            with open(ipa, "rb") as f:
                self.call("POST", f"{upload}?name=unsigned.ipa", data=f,
                          headers={"Content-Type": "application/octet-stream", "Content-Length": str(size)})
            self.call("POST", f"/repos/{self.repo}/actions/workflows/{WORKFLOW}/dispatches", {
                "ref": repo.get("default_branch") or "main",
                "inputs": {"release_id": str(rid), "bundle_id": bundle_id or "", "app_name": app_name or ""}})
            log("=== signing in GitHub Actions")
            run = self.wait(rid, timeout, log)
            if run.get("conclusion") != "success":
                raise CloudError(f"the signing job failed ({run.get('conclusion')}): {run.get('html_url')}")
            assets, _ = self.call("GET", f"/repos/{self.repo}/releases/{rid}/assets")
            signed = [a for a in assets if a["name"] == "signed.ipa"]
            if not signed:
                raise CloudError(f"the signing job left no signed.ipa: {run.get('html_url')}")
            data = self.call("GET", f"/repos/{self.repo}/releases/assets/{signed[0]['id']}", raw=True,
                             headers={"Accept": "application/octet-stream"})
            with open(out + ".tmp", "wb") as f:
                f.write(data)
            os.replace(out + ".tmp", out)
            log(f"=== {out}: signed")
            return out
        finally:
            self.call("DELETE", f"/repos/{self.repo}/releases/{rid}", ok=(204, 404))
            self.call("DELETE", f"/repos/{self.repo}/git/refs/tags/{tag}", ok=(204, 404, 422))

    def wait(self, rid, timeout, log):
        title = f"WinPad sign {rid}"
        deadline = time.time() + timeout
        run = None
        last = None
        while time.time() < deadline:
            if run is None:
                runs, _ = self.call("GET", f"/repos/{self.repo}/actions/workflows/{WORKFLOW}/runs"
                                    "?event=workflow_dispatch&per_page=20")
                run = next((r for r in runs.get("workflow_runs", []) if r.get("display_title") == title), None)
            else:
                run, _ = self.call("GET", f"/repos/{self.repo}/actions/runs/{run['id']}")
            if run:
                if run.get("status") != last:
                    last = run.get("status")
                    log(f"  {last}: {run.get('html_url')}")
                if run.get("status") == "completed":
                    return run
            self.sleep(self.poll)
        if not run:
            raise CloudError(f"the signing job did not start: is {WORKFLOW} in {self.repo} (--cloud-setup)?")
        raise CloudError(f"the signing job took longer than {timeout} s: {run.get('html_url')}")

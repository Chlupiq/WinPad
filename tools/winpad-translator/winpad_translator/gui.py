"""The window of WinPad Translator (Tk, so the same code runs on macOS and Windows)."""
import os
import queue
import threading
import traceback

from . import __version__, compile as fexcompile, library, project


def main():
    import tkinter as tk
    from tkinter import filedialog, ttk
    from tkinter.scrolledtext import ScrolledText

    root = tk.Tk()
    root.title(f"WinPad Translator {__version__}")
    root.minsize(760, 640)
    p = project.Project()
    lines = queue.Queue()

    tabs = ttk.Notebook(root)
    tabs.pack(fill="both", expand=True)
    frame = ttk.Frame(tabs, padding=12)
    tabs.add(frame, text="One game")
    library_tab(tabs)
    frame.columnconfigure(1, weight=1)
    row = 0
    entries = {}

    def path_row(label, key, kind, hint=""):
        nonlocal row
        ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=2)
        var = tk.StringVar(value=getattr(p, key))
        ttk.Entry(frame, textvariable=var).grid(row=row, column=1, sticky="ew", padx=6)

        def browse():
            if kind == "dir":
                v = filedialog.askdirectory()
            elif kind == "save":
                v = filedialog.asksaveasfilename(defaultextension=".ipa", filetypes=[("IPA", "*.ipa")])
            else:
                v = filedialog.askopenfilename(filetypes=kind)
            if v:
                var.set(v)

        ttk.Button(frame, text="…", width=3, command=browse).grid(row=row, column=2)
        entries[key] = var
        row += 1
        if hint:
            ttk.Label(frame, text=hint, foreground="gray").grid(row=row, column=1, sticky="w", padx=6)
            row += 1

    def list_row(label, key, kind, hint):
        nonlocal row
        ttk.Label(frame, text=label).grid(row=row, column=0, sticky="nw", pady=2)
        box = tk.Listbox(frame, height=3)
        box.grid(row=row, column=1, sticky="ew", padx=6)
        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=2, sticky="n")

        def add():
            if kind == "dir":
                v = filedialog.askdirectory()
                values = [v] if v else []
            else:
                values = filedialog.askopenfilenames(filetypes=kind)
            for v in values:
                box.insert("end", v)

        def remove():
            for i in reversed(box.curselection()):
                box.delete(i)

        ttk.Button(buttons, text="+", width=3, command=add).pack()
        ttk.Button(buttons, text="−", width=3, command=remove).pack()
        entries[key] = box
        row += 1
        ttk.Label(frame, text=hint, foreground="gray").grid(row=row, column=1, sticky="w", padx=6)
        row += 1

    path_row("Game folder", "game_dir", "dir", "the game as it is in WinPad Wine's Documents on the iPad")
    list_row("iPad code maps", "ipad_maps", "dir",
             "folders copied off the iPad: WinPad Wine › fexcache › codemap › new")
    list_row("PC drcov logs", "drcov_logs", [("drcov log", "*.log"), ("all", "*")],
             "optional: drrun -t drcov -- GAME.EXE on a Windows PC, played for a while")
    discover = tk.BooleanVar(value=False)
    ttk.Checkbutton(frame, text="Also find the game's code statically (more code, bigger image)",
                    variable=discover).grid(row=row, column=1, sticky="w", padx=6)
    row += 1
    path_row("WinPad Wine IPA", "ipa", [("IPA", "*.ipa")], "the app the iPad runs (its Wine DLLs must match)")
    path_row("Write IPA with image", "output_ipa", "save", "optional: sign and install it with AltStore/SideStore/Sideloadly")
    path_row("Image folder", "output_dir", "dir")

    ttk.Label(frame, text="App name").grid(row=row, column=0, sticky="w", pady=2)
    entries["app_name"] = tk.StringVar(value=p.app_name)
    ttk.Entry(frame, textvariable=entries["app_name"]).grid(row=row, column=1, sticky="ew", padx=6)
    row += 1
    ttk.Label(frame, text="optional: the name under the icon on the iPad, e.g. the game's",
              foreground="gray").grid(row=row, column=1, sticky="w", padx=6)
    row += 1

    ttk.Label(frame, text="Sign into game folder").grid(row=row, column=0, sticky="w", pady=2)
    entries["sign_identity"] = tk.StringVar(value=p.sign_identity)
    ttk.Entry(frame, textvariable=entries["sign_identity"]).grid(row=row, column=1, sticky="ew", padx=6)
    row += 1
    ttk.Label(frame, text="Mac, optional: auto or your Apple Development identity; the app then loads the image "
              "from the game folder, no new install", foreground="gray").grid(row=row, column=1, sticky="w", padx=6)
    row += 1

    ttk.Label(frame, text="Compiler runs").grid(row=row, column=0, sticky="w", pady=2)
    backend = tk.StringVar(value=fexcompile.default_backend())
    ttk.Combobox(frame, textvariable=backend, values=fexcompile.BACKENDS, state="readonly", width=12).grid(
        row=row, column=1, sticky="w", padx=6)
    row += 1

    advanced = ttk.LabelFrame(frame, text="Advanced", padding=6)
    advanced.grid(row=row, column=0, columnspan=3, sticky="ew", pady=6)
    advanced.columnconfigure(1, weight=1)
    row += 1
    adv = {}
    for i, (label, key) in enumerate([("FEXOfflineCompiler.exe", "compiler"), ("dispatcher.bin", "dispatcher"),
                                       ("Work folder", "work_dir"), ("Simulator build dir", "sim_work_dir"),
                                       ("Xcode project", "xcode_project")]):
        ttk.Label(advanced, text=label).grid(row=i, column=0, sticky="w")
        var = tk.StringVar(value=getattr(p, key))
        ttk.Entry(advanced, textvariable=var).grid(row=i, column=1, sticky="ew", padx=6)
        adv[key] = var
    half = tk.BooleanVar(value=True)
    rebuild = tk.BooleanVar(value=False)
    ttk.Checkbutton(advanced, text="Half barriers for new blocks (iPad faults on unaligned atomics)",
                    variable=half).grid(row=5, column=1, sticky="w", padx=6)
    ttk.Checkbutton(advanced, text="Generate every cache again", variable=rebuild).grid(row=6, column=1, sticky="w", padx=6)

    log = ScrolledText(frame, height=14, font=("TkFixedFont", 10))
    log.grid(row=row + 1, column=0, columnspan=3, sticky="nsew", pady=(6, 0))
    frame.rowconfigure(row + 1, weight=1)
    run_button = ttk.Button(frame, text="Translate")
    run_button.grid(row=row, column=2, sticky="e")

    def collect():
        for key, var in entries.items():
            if isinstance(var, tk.Listbox):
                setattr(p, key, list(var.get(0, "end")))
            else:
                setattr(p, key, var.get().strip())
        for key, var in adv.items():
            setattr(p, key, var.get().strip())
        p.discover, p.half_barrier, p.rebuild = discover.get(), half.get(), rebuild.get()
        p.backend = backend.get()
        p.simulator_image = bool(p.xcode_project)

    def work():
        try:
            project.run(p, log=lines.put)
        except project.KNOWN_ERRORS as e:
            lines.put(f"error: {e}")
        except Exception as e:  # noqa: BLE001 - shown in the window, with where it happened
            lines.put(f"error: {e}")
            lines.put(traceback.format_exc())
        lines.put(None)

    def start():
        collect()
        log.delete("1.0", "end")
        run_button.state(["disabled"])
        threading.Thread(target=work, daemon=True).start()

    def pump():
        try:
            while True:
                line = lines.get_nowait()
                if line is None:
                    run_button.state(["!disabled"])
                    continue
                log.insert("end", line + "\n")
                log.see("end")
        except queue.Empty:
            pass
        root.after(100, pump)

    def load_settings(game_dir):
        path = os.path.join(project.default_work_dir(game_dir), project.SETTINGS)
        if not os.path.isfile(path):
            return
        loaded = project.Project.load(path)
        for key, var in list(entries.items()) + list(adv.items()):
            value = getattr(loaded, key)
            if isinstance(var, tk.Listbox):
                var.delete(0, "end")
                for v in value:
                    var.insert("end", v)
            else:
                var.set(value)
        backend.set(loaded.backend or backend.get())

    entries["game_dir"].trace_add("write", lambda *_: load_settings(entries["game_dir"].get())
                                  if os.path.isdir(entries["game_dir"].get()) else None)
    run_button.configure(command=start)
    pump()
    root.mainloop()
    return 0


def library_tab(tabs):
    """Several games in one app (library.py): their folders, the code maps off the iPad, the IPA."""
    import tkinter as tk
    from tkinter import filedialog, ttk
    from tkinter.scrolledtext import ScrolledText

    path = library.default_path()
    lib = library.Library.load(path)
    lines = queue.Queue()
    frame = ttk.Frame(tabs, padding=12)
    tabs.add(frame, text="Game library")
    frame.columnconfigure(1, weight=1)

    ttk.Label(frame, text="Games").grid(row=0, column=0, sticky="nw", pady=2)
    games = tk.Listbox(frame, height=6)
    games.grid(row=0, column=1, sticky="ew", padx=6)

    def refresh():
        games.delete(0, "end")
        for p in lib.projects():
            state = "image ready" if os.path.isfile(library.image_of(p)) else "no image yet"
            games.insert("end", f"{p.folder_name()}  ({state})  {p.game_dir}")

    def add_game():
        folder = filedialog.askdirectory(title="The game folder, as it is in the app's Documents on the iPad")
        if folder:
            try:
                lib.add(folder)
            except project.TranslateError as e:
                lines.put(f"error: {e}")
            lib.save(path)
            refresh()

    def remove_game():
        for i in reversed(games.curselection()):
            lib.remove(lib.games[i])
        lib.save(path)
        refresh()

    buttons = ttk.Frame(frame)
    buttons.grid(row=0, column=2, sticky="n")
    ttk.Button(buttons, text="+", width=3, command=add_game).pack()
    ttk.Button(buttons, text="−", width=3, command=remove_game).pack()
    ttk.Label(frame, text="each a game folder; its image is fexaot-<folder>.dylib, which the app's library finds",
              foreground="gray").grid(row=1, column=1, sticky="w", padx=6)

    ttk.Label(frame, text="iPad code maps").grid(row=2, column=0, sticky="w", pady=2)
    maps = tk.StringVar()
    ttk.Entry(frame, textvariable=maps).grid(row=2, column=1, sticky="ew", padx=6)
    ttk.Button(frame, text="…", width=3, command=lambda: maps.set(filedialog.askdirectory() or maps.get())).grid(
        row=2, column=2)
    ttk.Label(frame, text="WinPad Wine › fexcache › codemap › new copied off the iPad: the maps of all games, "
              "each game takes its own", foreground="gray").grid(row=3, column=1, sticky="w", padx=6)

    fields = {}
    for row, (label, key, kind) in enumerate([("WinPad Wine IPA", "ipa", "open"), ("Write app IPA", "output_ipa", "save"),
                                              ("App name", "app_name", None)], start=4):
        ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=2)
        var = tk.StringVar(value=getattr(lib, key))
        ttk.Entry(frame, textvariable=var).grid(row=row, column=1, sticky="ew", padx=6)
        if kind:
            def browse(var=var, kind=kind):
                v = (filedialog.asksaveasfilename(defaultextension=".ipa", filetypes=[("IPA", "*.ipa")]) if kind == "save"
                     else filedialog.askopenfilename(filetypes=[("IPA", "*.ipa")]))
                if v:
                    var.set(v)
            ttk.Button(frame, text="…", width=3, command=browse).grid(row=row, column=2)
        fields[key] = var
    ttk.Label(frame, text="the IPA from CI (not one written here); the app name defaults to WinPad",
              foreground="gray").grid(row=7, column=1, sticky="w", padx=6)
    ttk.Label(frame, text="Sign into game folders").grid(row=8, column=0, sticky="w", pady=2)
    sign = tk.StringVar(value=lib.settings.get("sign_identity", ""))
    ttk.Entry(frame, textvariable=sign).grid(row=8, column=1, sticky="ew", padx=6)
    ttk.Label(frame, text="Mac only, optional: auto or your Apple Development identity",
              foreground="gray").grid(row=9, column=1, sticky="w", padx=6)
    ttk.Label(frame, text="Compiler runs").grid(row=10, column=0, sticky="w", pady=2)
    backend = tk.StringVar(value=lib.settings.get("backend") or fexcompile.default_backend())
    ttk.Combobox(frame, textvariable=backend, values=fexcompile.BACKENDS, state="readonly", width=12).grid(
        row=10, column=1, sticky="w", padx=6)

    build_button = ttk.Button(frame, text="Build the app")
    build_button.grid(row=11, column=2, sticky="e", pady=6)
    log = ScrolledText(frame, height=14, font=("TkFixedFont", 10))
    log.grid(row=12, column=0, columnspan=3, sticky="nsew")
    frame.rowconfigure(12, weight=1)

    def work(folders):
        try:
            library.build(lib, folders, log=lines.put)
            lib.save(path)
        except project.KNOWN_ERRORS as e:
            lines.put(f"error: {e}")
        except Exception as e:  # noqa: BLE001 - shown in the window, with where it happened
            lines.put(f"error: {e}")
            lines.put(traceback.format_exc())
        lines.put(None)

    def start():
        for key, var in fields.items():
            setattr(lib, key, var.get().strip())
        lib.settings["backend"] = backend.get()
        if sign.get().strip():
            lib.settings["sign_identity"] = sign.get().strip()
        else:
            lib.settings.pop("sign_identity", None)
        lib.save(path)
        log.delete("1.0", "end")
        build_button.state(["disabled"])
        threading.Thread(target=work, args=([maps.get().strip()] if maps.get().strip() else [],), daemon=True).start()

    def pump():
        try:
            while True:
                line = lines.get_nowait()
                if line is None:
                    build_button.state(["!disabled"])
                    refresh()
                    continue
                log.insert("end", line + "\n")
                log.see("end")
        except queue.Empty:
            pass
        frame.after(100, pump)

    build_button.configure(command=start)
    refresh()
    pump()

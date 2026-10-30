"""WinPad Translator: turns a game's FEX code maps into the AOT image the WinPad Wine iPad app runs.

The iPad app runs x86 code without a JIT, only from code compiled ahead of time
into Frameworks/fexaot-<game>.dylib. Code the image lacks runs in FEX's
interpreter, slowly, and is written to the app's Documents/fexcache/codemap/new.
This tool takes those code maps (and DynamoRIO logs of native PC runs, or a
static walk of the game's .exe), compiles them with FEX's offline compiler and
links the result into the dylib, for any game, on a Mac or a Windows PC.
See README.md next to this package.
"""

__version__ = "0.1.0"

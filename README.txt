// ULOS //

A Unix-Like OS for OpenComputers.  I need to stop writing these.

Structured similarly to Apotheosis, but hopefully with a slightly better architecture.

// REQUIREMENTS

To build ULOS, you'll need a working install of Lua 5.3, a *nix-like system supporting `io.popen`, `mkdir`, and `cd`, as well as `cmd1; cmd2` in the shell (when in doubt, the Bourne shell will more than suffice).  You'll also need LuaFileSystem.

Make sure to clone with `--recursive`, since the repository has submodules.

To build, just run `./build` from the repository root.  Output will be placed in `out`.

// PRIMARY FEATURES

At the core of ULOS, the Cynosure kernel's VT100 emulator is nearly as fast as the OpenOS 'term' API (only a second or two slower when writing huge amounts of text, plus color changes, to the terminal), proof that VT100 in OpenComputers doesn't have to be slow[1].

The Cynosure kernel also features extensive security measures such as strict separation and sandboxing of user-space from kernel-space, full permissions support for many critical aspects of the system, and multi-user support with per-user permissions.  There is first-class support for custom filesystems, so that file permissions and ownership may be used with no custom tools or user-space hacks.

Rather than suffer the memory overhead of two separate filesystems, Cynosure combines the devfs and procfs under /sys/dev and /sys/proc, respectively.  Components may be accessed and interacted with through /sys/components.  This eliminates the need for the often-complex APIs used in other systems for terminal access and process information[2].

With the Refinement init system, script and service configuration is simpler than ever - and, thanks to strict separation measures, the init system may be easily swapped.

ULOS runs smoothly on 256K of RAM, something neither Monolith nor Apotheosis can accomplish.  It supports multi-terminal functionality, with terminals initalized at boot time, allowing simultaneous use by several users.

ULOS ships with upstream TLE and its syntax highlighting files, for an incredible text editing experience.  This is proof that VT100-based editing doesn't have to be slow or primitive.


////footnotes
1.  It is extremely difficult to produce a benchmark that accurately mirrors actual use.  Not all features of the various tested OS's VT100 emulators were tested.  Real-world results may vary.
2.  There is still an API for process management, since there has to be a way to spawn new processes, and for processes to obtain more in-depth information about themselves.  However, programs like ps(1) may be written without the use of such APIs, simplifying program structure.

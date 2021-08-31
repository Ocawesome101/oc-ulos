// ULOS //

A Unix-Like OS for OpenComputers.  I need to stop writing these.

Structured similarly to Apotheosis, but hopefully with a slightly better architecture.

The ULOS Web Site is live now at https://ocawesome101.github.io/ulos !

// INSTALLATION + USER GUIDE

Run `pastebin run L7iWx5j7` in an OpenOS shell to begin the installation process.  The installer should be fairly self-explanatory.

An outdated user guide + installation guide is available at `docs/USERGUIDE.txt`.

// BUILDING

*** IMPORTANT ***
Building ULOS is only necessary if you wish to make significant changes to the system;  if you just want to install it on a computer, follow the instructions pointed to above.

To build ULOS, you'll need a working install of Lua 5.3, a *nix-like system supporting `io.popen`, `mkdir`, and `cd`, as well as `cmd1; cmd2` in the shell (when in doubt, the Bourne shell will more than suffice).  You'll also need LuaFileSystem.

Make sure to clone with `--recursive`, since the repository has submodules.

To build, just run `./build` from the repository root.  Output will be placed in `out`.

To develop ULOS, clone the repository, then run `./setup.sh` from the repository root.

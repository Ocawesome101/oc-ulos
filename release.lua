-- self-extracting mtar loader thingy: header --
-- this is designed for minimal overhead, not speed.
-- Expects an MTAR V1 archive.  Will not work with V0.

local fs = component.proxy(computer.getBootAddress())
local gpu = component.proxy(component.list("gpu")())
gpu.bind(gpu.getScreen() or (component.list("screen")()))

-- filesystem tree
local tree = {__is_a_directory = true}

local handle = assert(fs.open("/init.lua", "r"))

local seq = {"|","/","-","\\"}
local si = 1

gpu.setResolution(50, 16)
gpu.fill(1, 1, 50, 16, " ")
gpu.setForeground(0)
gpu.setBackground(0xFFFFFF)
gpu.set(1, 1, "             Cynosure MTAR-FS Loader              ")
gpu.setBackground(0)
gpu.setForeground(0xFFFFFF)

local function status(x, y, t, c)
  if c then gpu.fill(1, y+1, 50, 1, " ") end
  gpu.set(x, y+1, t)
end

status(1, 1, "Seeking to data section...")
local startoffset = 5536
-- seek in a hardcoded amount for speed reasons
fs.read(handle, 2048)
fs.read(handle, 2048)
fs.read(handle, 1440)
local last_time = computer.uptime()
repeat
  local c = fs.read(handle, 1)
  startoffset = startoffset + 1
  local t = computer.uptime()
  if t - last_time >= 0.1 then
    --status(30, 1, tostring(startoffset))
    status(28, 1, seq[si])
    si = si + 1
    if not seq[si] then si = 1 end
    last_time = t
  end
until c == "\90" -- uppercase z: magic
assert(fs.read(handle, 1) == "\n") -- skip \n

local function split_path(path)
  local s = {}
  for _s in path:gmatch("[^\\/]+") do
    if _s == ".." then
      s[#s] = nil
    elseif s ~= "." then
      s[#s+1]=_s
    end
  end
  return s
end

local function add_to_tree(name, offset, len)
  local cur = tree
  local segments = split_path(name)
  if #segments == 0 then return end
  for i=1, #segments - 1, 1 do
    cur[segments[i]] = cur[segments[i]] or {__is_a_directory = true}
    cur = cur[segments[i]]
  end
  cur[segments[#segments]] = {offset = offset, length = len}
end

local function read(n, offset, rdata)
  if offset then fs.seek(handle, "set", offset) end
  local to_read = n
  local data = ""
  while to_read > 0 do
    local n = math.min(2048, to_read)
    to_read = to_read - n
    local chunk = fs.read(handle, n)
    if rdata then data = data .. (chunk or "") end
  end
  return data
end

local function read_header()
  -- skip V1 header
  fs.read(handle, 3)
  local namelen = fs.read(handle, 2)
  if not namelen then
    return nil
  end
  namelen = string.unpack(">I2", namelen)
  local name = read(namelen, nil, true)
  local flendat = fs.read(handle, 8)
  if not flendat then return end
  local flen = string.unpack(">I8", flendat)
  local offset = fs.seek(handle, "cur", 0)
  status(24, 2, name .. (" "):rep(50 - (24 + #name)))
  fs.seek(handle, "cur", flen)
  add_to_tree(name, offset, flen)
  return true
end

status(1, 2, "Reading file headers... ")
repeat until not read_header()

-- create the mtar fs node --

local function find(f)
  if f == "/" or f == "" then
    return tree
  end

  local s = split_path(f)
  local c = tree
  
  for i=1, #s, 1 do
    if s[i] == "__is_a_directory" then
      return nil, "file not found"
    end
  
    if not c[s[i]] then
      return nil, "file not found"
    end

    c = c[s[i]]
  end

  return c
end

local obj = {}

function obj:stat(f)
  checkArg(1, f, "string")
  
  local n, e = find(f)
  
  if n then
    return {
      permissions = 365,
      owner = 0,
      group = 0,
      lastModified = 0,
      size = 0,
      isDirectory = not not n.__is_a_directory,
      type = n.__is_a_directory and 2 or 1
    }
  else
    return nil, e
  end
end

function obj:touch()
  return nil, "device is read-only"
end

function obj:remove()
  return nil, "device is read-only"
end

function obj:list(d)
  local n, e = find(d)
  
  if not n then return nil, e end
  if not n.__is_a_directory then return nil, "not a directory" end
  
  local f = {}
  
  for k, v in pairs(n) do
    if k ~= "__is_a_directory" then
      f[#f+1] = tostring(k)
    end
  end
  
  return f
end

local function ferr()
  return nil, "bad file descriptor"
end

local _handle = {}

function _handle:read(n)
  checkArg(1, n, "number")
  if self.fptr >= self.node.length then return nil end
  n = math.min(self.fptr + n, self.node.length)
  local data = read(n - self.fptr, self.fptr + self.node.offset, true)
  self.fptr = n
  return data
end

_handle.write = ferr

function _handle:seek(origin, offset)
  checkArg(1, origin, "string")
  checkArg(2, offset, "number", "nil")
  local n = (origin == "cur" and self.fptr) or (origin == "set" and 0) or
    (origin == "end" and self.node.length) or
    (error("bad offset to 'seek' (expected one of: cur, set, end, got "
      .. origin .. ")"))
  n = n + (offset or 0)
  if n < 0 or n > self.node.length then
    return nil, "cannot seek there"
  end
  self.fptr = n
  return n
end

function _handle:close()
  if self.closed then
    return ferr()
  end
  
  self.closed = true
end

function obj:open(f, m)
  checkArg(1, f, "string")
  checkArg(2, m, "string")

  if m:match("[w%+]") then
    return nil, "device is read-only"
  end
  
  local n, e = find(f)
  
  if not n then return nil, e end
  if n.__is_a_directory then return nil, "is a directory" end

  local new = setmetatable({
    node = n, --data = read(n.length, n.offset, true),
    mode = m,
    fptr = 0
  }, {__index = _handle})

  return new
end

obj.node = {getLabel = function() return "mtarfs" end}

status(1, 3, "Loading kernel...")

_G.__mtar_fs_tree = obj

local hdl = assert(obj:open("/boot/cynosure.lua", "r"))
local ldme = hdl:read(hdl.node.length)
hdl:close()

assert(load(ldme, "=mtarfs:/boot/cynosure.lua", "t", _G))()

-- concatenate mtar data past this line
--[=======[Z
�� bin/touch.lua      U-- coreutils: touch --

local path = require("path")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: touch FILE ...
Create the specified FILE(s) if they do not exist.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

for i=1, #args, 1 do
  local ok, err = filesystem.touch(path.canonical(args[i]),
    ftypes.file)

  if not ok then
    io.stderr:write("touch: cannot touch '", args[i], "': ", err, "\n")
    os.exit(1)
  end
end
�� bin/free.lua      2-- free --

local computer = require("computer")
local size = require("size")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: free [-h]
Prints system memory usage information.

Options:
  -h  Print sizes human-readably.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local function pinfo()
  local total = computer.totalMemory()
  local free = computer.freeMemory()
  
  -- collect garbage
  for i=1, 10, 1 do
    coroutine.yield(0)
  end
  
  local garbage = free - computer.freeMemory()
  local used = total - computer.freeMemory()

  print(string.format(
"total:    %s\
used:     %s\
free:     %s",
    size.format(total, not opts.h),
    size.format(used, not opts.h),
    size.format(computer.freeMemory(), not opts.h)))
end

pinfo()
�� 
bin/cp.lua      	^-- coreutils: cp --

local path = require("path")
local futil = require("futil")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args < 2 then
  io.stderr:write([[
usage: cp [-rv] SOURCE ... DEST
Copy SOURCE(s) to DEST.

Options:
  -r  Recurse into directories.
  -v  Be verbose.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(2)
end

local function copy(src, dest)
  if opts.v then
    print(string.format("'%s' -> '%s'", src, dest))
  end

  local inhandle, err = io.open(src, "r")
  if not inhandle then
    return nil, src .. ": " .. err
  end

  local outhandle, err = io.open(dest, "w")
  if not outhandle then
    return nil, dest .. ": " .. err
  end

  repeat
    local data = inhandle:read(8192)
    if data then outhandle:write(data) end
  until not data

  inhandle:close()
  outhandle:close()

  return true
end

local function exit(...)
  io.stderr:write("cp: ", ...)
  os.exit(1)
end

local dest = path.canonical(table.remove(args, #args))

if #args > 1 then -- multiple sources, dest has to be a directory
  local dstat, err = filesystem.stat(dest)

  if dstat and (not dstat.isDirectory) then
    exit("cannot copy to '", dest, "': target is not a directory\n")
  end
end

local function cp(f)
  local file = path.canonical(f)
  
  local stat, err = filesystem.stat(file)
  if not stat then
    exit("cannot stat '", f, "': ", err, "\n")
  end

  if stat.isDirectory then
    if not opts.r then
      exit("cannot copy directory '", f, "'; use -r to recurse\n")
    end
    local tree = futil.tree(file)

    filesystem.touch(dest, ftypes.directory)

    for i=1, #tree, 1 do
      local abs = path.concat(dest, tree[i]:sub(#file + 1))
      local data = filesystem.stat(tree[i])
      if data.isDirectory then
        local ok, err = filesystem.touch(abs, ftypes.directory)
        if not ok then
          exit("cannot create directory ", abs, ": ", err, "\n")
        end
      else
        local ok, err = copy(tree[i], abs)
        if not ok then exit(err, "\n") end
      end
    end
  else
    local dst = dest
    if #args > 1 then
      local segments = path.split(file)
      dst = path.concat(dest, segments[#segments])
    end
    local ok, err = copy(file, dst)
    if not ok then exit(err, "\n") end
  end
end

for i=1, #args, 1 do cp(args[i]) end
�� bin/file.lua      �-- file --

local fs = require("filesystem")
local path = require("path")
local filetypes = require("filetypes")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: file FILE ...
   or: file [--help]
Prints filetype information for the specified
FILE(s).

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

for i=1, #args, 1 do
  local full = path.canonical(args[i])
  local ok, err = fs.stat(full)
  if not ok then
    io.stderr:write("file: cannot stat '", args[i], "': ", err, "\n")
    os.exit(1)
  end
  local ftype = "data"
  for k, v in pairs(filetypes) do
    if v == ok.type then
      ftype = k
      break
    end
  end
  io.write(args[i], ": ", ftype, "\n")
end
�� 
bin/rm.lua      4-- coreutils: rm --

local path = require("path")
local futil = require("futil")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: rm [-rfv] FILE ...
   or: rm --help
Remove all FILE(s).

Options:
  -r      Recurse into directories.  Only
          necessary on some filesystems.
  -f      Ignore nonexistent files/directories.
  -v      Print the path of every file that is
          directly removed.
  --help  Print this help and exit.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local function exit(...)
  if not opts.f then
    io.stderr:write("rm: ", ...)
    os.exit(1)
  end
end

local function remove(file)
  local abs = path.canonical(file)
  local data, err = filesystem.stat(abs)

  if not data then
    exit("cannot delete '", file, "': ", err, "\n")
  end

  if data.isDirectory and opts.r then
    local files = futil.tree(abs)
    for i=#files, 1, -1 do
      remove(files[i])
    end
  end

  local ok, err = filesystem.remove(abs)
  if not ok then
    exit("cannot delete '", file, "': ", err, "\n")
  end

  if ok and opts.v then
    io.write("removed ", data.isDirectory and "directory " or "",
      "'", abs, "'\n")
  end
end

for i, file in ipairs(args) do remove(file) end
�� bin/find.lua      X-- find --

local path = require("path")
local futil = require("futil")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: find DIRECTORY ...
Print a tree of all files in DIRECTORY.  All
printed file paths are absolute.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
end

for i=1, #args, 1 do
  local tree, err = futil.tree(path.canonical(args[i]))
  
  if not tree then
    io.stderr:write("find: ", err, "\n")
    os.exit(1)
  end

  for i=1, #tree, 1 do
    io.write(tree[i], "\n")
    if i % 10 == 0 then coroutine.yield(0) end
  end
end
�� bin/uname.lua       :-- coreutils: uname --

-- TODO: expand
print(_OSVERSION)
�� bin/login.lua      �-- coreutils: login

local users = require("users")
local process = require("process")
local readline = require("readline")

if (process.info().owner or 0) ~= 0 then
  io.stderr:write("login may only be run as root!\n")
  os.exit(1)
end

io.write("\27?0c\27[39;49m\nWelcome to ULOS.\n\n")

local function main()
  io.write("\27?0c", os.getenv("HOSTNAME") or "localhost", " login: ")
  local un = readline()
  io.write("password: \27[8m")
  local pw = io.read("l")
  io.write("\n\27[m\27?0c")
  local uid = users.get_uid(un)
  if not uid then
    io.write("no such user\n\n")
  else
    local ok, err = users.authenticate(uid, pw)
    if not ok then
      io.write(err, "\n\n")
    else
      local info = users.attributes(uid)
      local shell = info.shell or "/bin/sh"
      if not shell:match("%.lua$") then
        shell = string.format("%s.lua", shell)
      end
      local shellf, sherr = loadfile(shell)
      if not shellf then
        io.write("failed loading shell: ", sherr, "\n\n")
      else
        io.write("\n")

        local motd = io.open("/etc/motd.txt", "r")
        if motd then
          print((motd:read("a") or ""))
          motd:close()
        end

        local exit, err = users.exec_as(uid, pw, shellf, shell, true)
        if exit ~= 0 then
          print(err)
        end
      end
    end
  end
end

while true do
  local ok, err = xpcall(main, debug.traceback)
  if not ok then
    io.stderr:write(err, "\n")
  end
end
�� bin/install.lua      	�-- install to a writable medium. --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: install
Install ULOS to a writable medium.  Only present
in the live system image.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local component = require("component")
local computer = require("computer")

local fs = {}
do
  local _fs = component.list("filesystem")

  for k, v in pairs(_fs) do
    if k ~= computer.tmpAddress() then
      fs[#fs+1] = k
    end
  end
end

print("Available filesystems:")
for k, v in ipairs(fs) do
  print(string.format("%d. %s", k, v))
end

print("Please input your selection.")

local choice
repeat
  io.write("> ")
  choice = io.read("l")
until fs[tonumber(choice) or 0]

os.execute("mount -u /mnt")
os.execute("mount " .. fs[tonumber(choice)] .. " /mnt")

local online, full = false, false
if component.list("internet")() then
  io.write("Perform an online installation? [Y/n]: ")
  local choice
  repeat
    io.write(choice and "Please enter 'y' or 'n': " or "")
    choice = io.read():gsub("\n", "")
  until choice == "y" or choice == "n" or choice == ""
  online = (choice == "y" or #choice == 0)
  if online then
    io.write("Install the full system (manual pages, TLE)?  [Y/n]: ")
    local choice
    repeat
      io.write(choice and "Please enter 'y' or 'n': " or "")
      choice = io.read():gsub("\n", "")
    until choice == "y" or choice == "n" or choice == ""
    full = (choice == "y" or #choice == 0)
    if full then
      print("Installing the full system from the internet")
    else
      print("Installing the base system from the internet")
    end
  else
    print("Copying the system from the installer medium")
  end
else
  print("No internet card installed, defaulting to offline installation")
end

if online then
  os.execute("upm update --root=/mnt")
  local pklist = {
    "cynosure",
    "refinement",
    "coreutils",
    "corelibs",
    "upm",
  }
  if full then
    pklist[#pklist+1] = "tle"
    pklist[#pklist+1] = "manpages"
  end
  os.execute("upm install --root=/mnt " .. table.concat(pklist, " "))
else
-- TODO: do this some way other than hard-coding it
  local dirs = {
    "bin",
    "etc",
    "lib",
    "sbin",
    "usr",
    "init.lua", -- copy this last for safety reasons
  }

  for i, dir in ipairs(dirs) do
    os.execute("cp -rv /"..dir.." /mnt/"..dir)
  end

  os.execute("rm /mnt/bin/install.lua")
end
�� 
bin/df.lua      �-- df --

local path = require("path")
local size = require("size")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: df [-h]
Print information about attached filesystems.
Uses information from the sysfs.

Options:
  -h  Print sizes in human-readable form.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local fscpath = "/sys/components/by-type/filesystem/"
local files = filesystem.list(fscpath)

table.sort(files)

print("      fs     name    total     used     free")

local function readFile(f)
  local handle = assert(io.open(f, "r"))
  local data = handle:read("a")
  handle:close()

  return data
end

local function printInfo(fs)
  local addr = readFile(fs.."/address"):sub(1, 8)
  local name = readFile(fs.."/label")
  local used = tonumber(readFile(fs.."/spaceUsed"))
  local total = tonumber(readFile(fs.."/spaceTotal"))

  local free = total - used

  if opts.h then
    used = size.format(used)
    free = size.format(free)
    total = size.format(total)
  end

  print(string.format("%8s %8s %8s %8s %8s", addr, name, total, used, free))
end

for i, file in ipairs(files) do
  printInfo(path.concat(fscpath, file))
end
�� 
bin/ps.lua      r-- ps: format information from /proc --

local users = require("users")
local fs = require("filesystem")

local args, opts = require("argutil").parse(...)

local function read(f)
  local handle, err = io.open(f)
  if not handle then
    io.stderr:write("ps: cannot open ", f, ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()
  return tonumber(data) or data
end

if opts.help then
  io.stderr:write([[
usage: ps
Format process information from /sys/proc.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

local procs = fs.list("/sys/proc")
table.sort(procs, function(a, b) return tonumber(a) < tonumber(b) end)

print("   PID  STATUS     TIME NAME")
for i=1, #procs, 1 do
  local base = string.format("/sys/proc/%d/",
    tonumber(procs[i]))
  local data = {
    name = read(base .. "name"),
    pid = tonumber(procs[i]),
    status = read(base .. "status"),
    owner = users.attributes(read(base .. "owner")).name,
    time = read(base .. "cputime")
  }

  print(string.format("%6d %8s %7s %s", data.pid, data.status,
    string.format("%.2f", data.time), data.name))
end
�� 
bin/wc.lua      �-- coreutils: wc --

local path = require("path")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: wc [-lcw] FILE ...
Print line, word, and character (byte) counts from
all FILEs.

Options:
  -c  Print character counts.
  -l  Print line counts.
  -w  Print word counts.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if not (opts.l or opts.w or opts.c) then
  opts.l = true
  opts.w = true
  opts.c = true
end

local function wc(f)
  local handle, err = io.open(f, "r")
  if not handle then
    return nil, err
  end

  local data = handle:read("a")
  handle:close()

  local out = {}

  if opts.l then
    out[#out+1] = tostring(select(2, data:gsub("\n", "")))
  end

  if opts.w then
    out[#out+1] = tostring(select(2, data:gsub("[ \n\t\r]+", "")))
  end

  if opts.c then
    out[#out+1] = tostring(#data)
  end

  return out
end

for i=1, #args, 1 do
  local ok, err = wc(path.canonical(args[i]))
  if not ok then
    io.stderr:write("wc: ", args[i], ": ", err, "\n")
    os.exit(1)
  else
    io.write(table.concat(ok, " "), " ", args[i], "\n")
  end
end
�� bin/mkdir.lua      �-- coreutils: mkdir --

local path = require("path")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: mkdir [-p] DIRECTORY ...
Create the specified DIRECTORY(ies), if they do
not exist.

Options:
  -p  Do not exit if the file already exists;
      automatically create parent directories as
      necessary.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

for i=1, #args, 1 do
  local dir = path.canonical(args[i])
  local exists = not not filesystem.stat(dir)
  if exists and not opts.p then
    io.stderr:write("mkdir: ", args[i], ": file already exists\n")
    os.exit(1)
  elseif not exists then
    local seg = path.split(dir)
    local parent = path.clean(table.concat(seg, "/", 1, #seg - 1))
    if opts.p then
      local segments = path.split(parent)
      for n, segment in ipairs(segments) do
        local ok, err = filesystem.touch(path.canonical("/"..
          table.concat(segments, "/", 1, n)), ftypes.directory)
        if not ok and err then
          io.stderr:write("mkdir: cannot create directory '", args[i], ": ",
            err, "\n")
          --os.exit(2)
        end
      end
    end
    local ok, err = filesystem.touch(dir, ftypes.directory)
    if not ok and err then
      io.stderr:write("mkdir: cannot create directory '", args[i],
        "': ", err, "\n")
      os.exit(2)
    end
  end
end
�� bin/lsh.lua      7X-- lsh: the Lispish SHell

-- Shell syntax is heavily Lisp-inspired but not entirely Lisp-like.
-- String literals with spaces are supported between double-quotes - otherwise,
-- tokens are separated by whitespace.  A semicolon or EOF marks separation of
-- commands.
-- Everything inside () is evaluated as an expression (or subcommand);  the
-- program's output is tokenized by line and passed to the parent command as
-- arguments, such that `echo 1 2 (seq 3 6) 7 8` becomes `echo 1 2 3 4 5 6 7 8`.
-- This behavior is supported recursively.
-- [] behaves identically to (), except that the exit status of the child
-- command is inserted in place of its output.  An exit status of 0 is generally
-- assumed to mean success, and all non-zero exit statii to indicate failure.
-- Variables may be set with the 'set' builtin, and read with the 'get' builtin.
-- Functions may be declared with the 'def' builtin, e.g.:
-- def example (dir) (cd (get dir); print (get PWD));.
-- Comments are preceded by a # and continue until the next newline character
-- or until EOF.

local readline = require("readline")
local process = require("process")
local fs = require("filesystem")
local paths = require("path")
local pipe = require("pipe")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: lsh
The Lisp-like SHell.  See lsh(1) for details.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

-- Initialize environment --
os.setenv("PWD", os.getenv("PWD") or os.getenv("HOME") or "/")
os.setenv("PS1", os.getenv("PS1") or 
  "<(get USER)@(or (get HOSTNAME) localhost): (or (match (get PWD) \"([^/]+)/?$\") /)> ")
os.setenv("PATH", os.getenv("PATH") or "/bin:/sbin:/usr/bin")

local splitters = {
  ["["] = true,
  ["]"] = true,
  ["("] = true,
  [")"] = true,
  ["#"] = true,
}

local rdr = {
  peek = function(s)
    return s.tokens[s.i]
  end,
  next = function(s)
    s.i = s.i + 1
    return s.tokens[s.i-1]
  end,
  sequence = function(s, b, e)
    local seq = {}
    local bl = 1
    repeat
      local tok = s:next()
      seq[#seq+1] = tok
      if s:peek() == b then bl = bl + 1
      elseif s:peek() == e then bl = bl - 1 end
    until bl == 0 or not s:peek()
    s:next()
    return seq
  end,
}

-- split a command into tokens
local function tokenize(str)
  local tokens = {}
  local token = ""
  local in_str = false

  for c in str:gmatch(".") do
    if c == "\"" then
      in_str = not in_str
      if #token > 0 or not in_str then
        if not in_str then
          token = token
            :gsub("\\e", "\27")
            :gsub("\\n", "\n")
            :gsub("\\a", "\a")
            :gsub("\\27", "\27")
            :gsub("\\t", "\t")
        end
        tokens[#tokens+1] = token
        token = ""
      end
    elseif in_str then
      token = token .. c
    elseif c:match("[ \n\t\r]") then
      if #token > 0 then
        tokens[#tokens+1] = token
        token = ""
      end
    elseif splitters[c] then
      if #token > 0 then tokens[#tokens+1] = token token = "" end
      tokens[#tokens+1] = c
    else
      token = token .. c
    end
  end

  if #token > 0 then tokens[#tokens+1] = token end

  return setmetatable({
    tokens = tokens,
    i = 1
  }, {__index = rdr})
end

local processCommand

-- Call a function, return its exit status,
-- and if 'sub' is true return its output.
local sub = false
local function call(name, func, args, fio)
  local fauxio
  local function proc()
    local old_exit = os.exit
    local old_exec = os.execute

    function os.exit()
      os.exit = old_exit
      os.execute = old_exec
      old_exit(n)
    end

    os.execute = processCommand

    if fauxio then
      io.output(fauxio)
      io.stdout = fauxio
    end

    local ok, err, ret = xpcall(func, debug.traceback, table.unpack(args))

    if (not ok and err) or (not err and ret) then
      io.stderr:write(name, ": ", err or ret, "\n")
      os.exit(127)
    end

    os.exit(0)
  end

  if sub then
    fauxio = setmetatable({
      buffer = "",
      write = function(s, ...)
        s.buffer = s.buffer .. table.concat(table.pack(...)) end,
      read = function() return nil, "bad file descriptor" end,
      seek = function() return nil, "bad file descriptor" end,
      close = function() return true end
    }, {__name = "FILE*"})
  end

  if fio then fauxio = fio end

  local pid = process.spawn {
    func = proc,
    name = name,
    stdin = io.stdin,
    stdout = fauxio or io.stdout,
    stderr = io.stderr,
    input = io.input(),
    output = fauxio or io.output()
  }

  local exitStatus, exitReason = process.await(pid)

  if exitStatus ~= 0 and exitReason ~= "__internal_process_exit"
      and exitReason ~= "exited" and exitReason and #exitReason > 0 then
    io.stderr:write(name, ": ", exitReason, "\n")
  end

  local out
  if fauxio then
    out = {}
    for line in fauxio.buffer:gmatch("[^\n]+") do
      out[#out+1] = line
    end
  end

  return exitStatus, out
end

local shenv = process.info().data.env

local builtins = {
  ["or"] = function(a, b)
    if #tostring(a) == 0 then a = nil end
    if #tostring(b) == 0 then b = nil end
    print(a or b or "")
  end,
  ["get"] = function(k)
    if not k then
      io.stderr:write("get: usage: get NAME\nRead environment variables.\n")
      os.exit(1)
    end
    print(shenv[k] or "")
  end,
  ["set"] = function(k, v)
    if not k then
      for k,v in pairs(shenv) do
        print(string.format("%s=%q", k, v))
      end
    else
      shenv[k] = tonumber(v) or v
    end
  end,
  ["cd"] = function(dir)
    if dir == "-" then
      if not shenv.OLDPWD then
        io.stderr:write("cd: OLDPWD not set\n")
        os.exit(1)
      end
      dir = shenv.OLDPWD
      print(dir)
    elseif not dir then
      if not shenv.HOME then
        io.stderr:write("cd: HOME not set\n")
        os.exit(1)
      end
      dir = shenv.HOME
    end
    local cdir = paths.canonical(dir)
    local ok, err = fs.stat(cdir)
    if ok then
      shenv.OLDPWD = shenv.PWD
      shenv.PWD = cdir
    else
      io.stderr:write("cd: ", dir, ": ", err, "\n")
      os.exit(1)
    end
  end,
  ["match"] = function(str, pat)
    if not (str and pat) then
      io.stderr:write("match: usage: match STRING PATTERN\nMatch STRING against PATTERN.\n")
      os.exit(1)
    end
    print(table.concat(table.pack(string.match(str, pat)), "\n"))
  end,
  ["gsub"] = function(str, pat, rep)
    if not (str and pat and rep) then
      io.stderr:write("gsub: usage: gsub STRING PATTERN REPLACE\nReplace all matches of PATTERN with REPLACE.\n")
      os.exit(1)
    end
    print(table.concat(table.pack(string.gsub(str,pat,rep)), "\n"))
  end,
  ["sub"] = function(str, i, j)
    if not (str and tonumber(i) and tonumber(j)) then
      io.stderr:write("sub: usage: sub STRING START END\nPrint a substring of STRING, beginning at index\nSTART and ending at END.\n")
      os.exit(1)
    end
    print(string.sub(str, tonumber(i), tonumber(j)))
  end,
  ["print"] = function(...)
    print(table.concat(table.pack(...), " "))
  end,
  ["time"] = function(...)
    local computer = require("computer")
    local start = computer.uptime()
    os.execute(table.concat(table.pack(...), " "))
    print("\ntook " .. (computer.uptime() - start) .. "s")
  end,
  ["+"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["-"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["/"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["*"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["="] = function(a, b) os.exit(a == b and 0 or 1) end,
  ["into"] = function(...)
    local args = table.pack(...)
    local f = args[1] ~= "-p" and args[1] or args[2]
    if not f then
      io.stderr:write([[
into: usage: into [options] FILE ...
Write all arguments to FILE.

Options:
  -p  Execute the arguments as a program rather
      than taking them literally.
]])
      os.exit(1)
    end
    local name, mode = f:match("(.-):(.)")
    name = name or f
    local handle, err = io.open(name, mode or "w")
    if not handle then
      io.stderr:write("into: ", name, ": ", err, "\n")
      os.exit(1)
    end
    if args[1] == "-p" then
      processCommand(table.concat(args, " ", 3, #args), false,
        handle)
    else
      handle:write(table.concat(table.pack(...), "\n"))
    end
    handle:close()
  end,
  ["seq"] = function(start, finish)
    for i=tonumber(start), tonumber(finish), 1 do
      print(i)
    end
  end
}

local shebang_pattern = "^#!(/.-)\n"

local function loadCommand(path, h)
  local handle, err = io.open(path, "r")
  if not handle then return nil, path .. ": " .. err end
  local data = handle:read("a")
  handle:close()
  if data:match(shebang_pattern) then
    local shebang = data:match(shebang_pattern)
    if not shebang:match("lua") then
      local executor = loadCommand(shebang, h)
      return function(...)
        return call(table.concat({shebang, path, ...}, " "), executor,
          {path, ...}, h)
      end
    else
      data = data:gsub(shebang_pattern, "")
      return load(data, "="..path, "t", _G)
    end
  else
    return load(data, "="..path, "t", _G)
  end
end

local extensions = {
  "lua",
  "lsh"
}

local function resolveCommand(cmd, h)
  local path = os.getenv("PATH")

  local ogcmd = cmd

  if builtins[cmd] then
    return builtins[cmd]
  end

  local try = paths.canonical(cmd)
  if fs.stat(try) then
    return loadCommand(try, h)
  end

  for k, v in pairs(extensions) do
    if fs.stat(try .. "." .. v) then
      return loadCommand(try .. "." .. v, h)
    end
  end

  for search in path:gmatch("[^:]+") do
    local try = paths.canonical(paths.concat(search, cmd))
    if fs.stat(try) then
      return loadCommand(try, h)
    end

    for k, v in pairs(extensions) do
      if fs.stat(try .. "." .. v) then
        return loadCommand(try .. "." .. v)
      end
    end
  end

  return nil, ogcmd .. ": command not found"
end

local defined = {}

local processTokens
local function eval(set, h)
  local osb = sub
  sub = set.getOutput or sub
  local ok, err = processTokens(set, false, h)
  sub = osb
  return ok, err
end

processTokens = function(tokens, noeval, handle)
  local sequence = {}

  if not tokens.next then tokens = setmetatable({i=1,tokens=tokens},
    {__index = rdr}) end
  
  repeat
    local tok = tokens:next()
    if tok == "(" then
      local subc = tokens:sequence("(", ")")
      subc.getOutput = true
      sequence[#sequence+1] = subc
    elseif tok == "[" then
      local subc = tokens:sequence("[", "]")
      sequence[#sequence+1] = subc
    elseif tok == ")" then
      return nil, "unexpected token ')'"
    elseif tok == "]" then
      return nil, "unexpected token ')'"
    elseif tok ~= "#" then
      if defined[tok] then
        sequence[#sequence+1] = defined[tok]
      else
        sequence[#sequence+1] = tok
      end
    end
  until tok == "#" or not tok

  if #sequence == 0 then return "" end

  if sequence[1] == "def" then
    defined[sequence[2]] = sequence[3]
    sequence = ""
  elseif sequence[1] == "if" then
    local ok, err = eval(sequence[2], handle)
    if not ok then return nil, err end
    local _ok, _err
    if err == 0 then
      _ok, _err = eval(sequence[3], handle)
    elseif sequence[4] then
      _ok, _err = eval(sequence[4], handle)
    else
      _ok = ""
    end
    return _ok, _err
  elseif sequence[1] == "for" then
    local iter, err = eval(sequence[3], handle)
    if not iter then return nil, err end
    local result = {}
    for i, v in ipairs(iter) do
      shenv[sequence[2]] = v
      local ok, _err = eval(sequence[4], handle)
      if not ok then return nil, _err end
      result[#result+1] = ok
    end
    shenv[sequence[2]] = nil
    return result
  else
    for i=1, #sequence, 1 do
      if type(sequence[i]) == "table" then
        local ok, err = eval(sequence[i], handle)
        if not ok then return nil, err end
        sequence[i] = ok
      elseif defined[sequence[i]] then
        local ok, err = eval(defined[sequence[i]], handle)
        if not ok then return nil, err end
        sequence[i] = ok
      end
    end

    -- expand
    local i = 1
    while true do
      local s = sequence[i]
      if type(s) == "table" then
        table.remove(sequence, i)
        for n=#s, 1, -1 do
          table.insert(sequence, i, s[n])
        end
      end
      i = i + 1
      if i > #sequence then break end
    end

    if noeval then return sequence end
    -- now, execute it
    local name = sequence[1]
    if not name then return true end
    local ok, err = resolveCommand(table.remove(sequence, 1), handle)
    if not ok then return nil, err end
    local old = sub
    sub = sequence.getOutput or sub
    local ex, out = call(name, ok, sequence, handle)
    sub = old

    if out then
      return out, ex
    end

    return ex
  end

  return sequence
end

processCommand = function(text, ne, h)
  -- TODO: do this correctly
  local result = {}
  for chunk in text:gmatch("[^;]+") do 
    result = table.pack(processTokens(tokenize(chunk), ne, h))
  end
  return table.unpack(result)
end

local function processPrompt(text)
  for group in text:gmatch("%b()") do
    text = text:gsub(group:gsub("[%(%)%[%]%.%+%?%$%-%%]", "%%%1"),
      tostring(processCommand(group, true)[1] or ""))
  end
  return (text:gsub("\n", ""))
end

os.execute = processCommand
os.remove = function(file)
  return fs.remove(paths.canonical(file))
end
io.popen = function(command, mode)
  checkArg(1, command, "string")
  checkArg(2, mode, "string", "nil")
  mode = mode or "r"
  assert(mode == "r" or mode == "w", "bad mode to io.popen")

  local handle = pipe.create()

  processCommand(command)

  return handle
end

local history = {}
local rlopts = {
  history = history
}
while true do
  io.write("\27[0m\27?0c", processPrompt(os.getenv("PS1")))
  local command = readline(rlopts)
  history[#history+1] = command
  if #history > 32 then
    table.remove(history, 1)
  end
  local ok, err = processCommand(command)
  if not ok and err then
    io.stderr:write(err, "\n")
  end
end
�� bin/upm.lua      *�-- UPM: the ULOS Package Manager --

local fs = require("filesystem")
local path = require("path")
local tree = require("futil").tree
local mtar = require("mtar")
local config = require("config")
local network = require("network")
local filetypes = require("filetypes")

local args, opts = require("argutil").parse(...)

local cfg = config.bracket:load("/etc/upm.cfg") or {}

cfg.General = cfg.General or {}
cfg.General.dataDirectory = cfg.General.dataDirectory or "/etc/upm"
cfg.General.cacheDirectory = cfg.General.cacheDirectory or "/etc/upm/cache"
cfg.Repositories = cfg.Repositories or {main = "https://oz-craft.pickardayune.com/upm/main/"}

config.bracket:save("/etc/upm.cfg", cfg)

if type(opts.root) ~= "string" then opts.root = "/" end
opts.root = path.canonical(opts.root)

-- create directories
os.execute("mkdir -p " .. path.concat(opts.root, cfg.General.dataDirectory))
os.execute("mkdir -p " .. path.concat(opts.root, cfg.General.cacheDirectory))

if opts.root ~= "/" then
  config.bracket:save(path.concat(opts.root, "/etc/upm.cfg"), cfg)
end

local usage = "\
UPM - the ULOS Package Manager\
\
usage: \27[36mupm \27[39m[\27[93moptions\27[39m] \27[96mCOMMAND \27[39m[\27[96m...\27[39m]\
\
Available \27[96mCOMMAND\27[39ms:\
  \27[96minstall \27[91mPACKAGE ...\27[39m\
    Install the specified \27[91mPACKAGE\27[39m(s).\
\
  \27[96mremove \27[91mPACKAGE ...\27[39m\
    Remove the specified \27[91mPACKAGE\27[39m(s).\
\
  \27[96mupdate\27[39m\
    Update (refetch) the repository package lists.\
\
  \27[96mupgrade\27[39m\
    Upgrade installed packages.\
\
  \27[96msearch \27[91mPACKAGE\27[39m\
    Search local package lists for \27[91mPACKAGE\27[39m, and\
    display information about it.\
\
  \27[96mlist\27[39m [\27[91mTARGET\27[39m]\
    List packages.  If \27[91mTARGET\27[39m is 'all',\
    then list packages from all repos;  if \27[91mTARGET\27[37m\
    is 'installed', then print all installed\
    packages;  otherewise, print all the packages\
    in the repo specified by \27[91mTARGET\27[37m.\
    \27[91mTARGET\27[37m defaults to 'installed'.\
\
Available \27[93moption\27[39ms:\
  \27[93m-q\27[39m            Be quiet;  no log output.\
  \27[93m-f\27[39m            Skip checks for package version and\
                              installation status.\
  \27[93m-v\27[39m            Be verbose;  overrides \27[93m-q\27[39m.\
  \27[93m-y\27[39m            Automatically assume 'yes' for\
                              all prompts.\
  \27[93m--root\27[39m=\27[33mPATH\27[39m   Treat \27[33mPATH\27[39m as the root filesystem\
                instead of /.\
\
The ULOS Package Manager is copyright (c) 2021\
Ocawesome101 under the DSLv2.\
"

local pfx = {
  info = "\27[92m::\27[39m ",
  warn = "\27[93m::\27[39m ",
  err = "\27[91m::\27[39m "
}

local function log(...)
  if opts.v or not opts.q then
    io.stderr:write(...)
    io.stderr:write("\n")
  end
end

local function exit(reason)
  log(pfx.err, reason)
  os.exit(1)
end

local installed, ipath
do
  ipath = path.concat(opts.root, cfg.General.dataDirectory, "installed.list")

  local ilist = path.concat(opts.root, cfg.General.dataDirectory, "installed.list")
  
  if not fs.stat(ilist) then
    local handle, err = io.open(ilist, "w")
    if not handle then
      exit("cannot create installed.list: " .. err)
    end
    handle:write("{}")
    handle:close()
  end

  local inst, err = config.table:load(ipath)

  if not inst and err then
    exit("cannot open installed.list: " .. err)
  end
  installed = inst
end

local search, update, download, extract, install_package, install

function search(name)
  if opts.v then log(pfx.info, "querying repositories for package ", name) end
  local repos = cfg.Repositories
  for k, v in pairs(repos) do
    if opts.v then log(pfx.info, "searching list ", k) end
    local data, err = config.table:load(path.concat(opts.root,
      cfg.General.dataDirectory, k .. ".list"))
    if not data then
      log(pfx.warn, "list ", k, " is nonexistent; run 'upm update' to refresh")
    else
      if data.packages[name] then
        return data.packages[name], k
      end
    end
  end
  exit("package " .. name .. " not found")
end

function update()
  log(pfx.info, "refreshing package lists")
  local repos = cfg.Repositories
  for k, v in pairs(repos) do
    log(pfx.info, "refreshing list: ", k)
    local url = v .. "/packages.list"
    download(url, path.concat(opts.root, cfg.General.dataDirectory, k .. ".list"))
  end
end

function download(url, dest)
  log(pfx.warn, "downloading ", url, " as ", dest)
  local out, err = io.open(dest, "w")
  if not out then
    exit(dest .. ": " .. err)
  end

  local handle, err = network.request(url)
  if not handle then
    out:close() -- just in case
    exit(err)
  end

  repeat
    local chunk = handle:read(2048)
    if chunk then out:write(chunk) end
  until not chunk
  handle:close()
  out:close()
end

function extract(package)
  log(pfx.info, "extracting ", package)
  local base, err = io.open(package, "r")
  if not base then
    exit(package .. ": " .. err)
  end
  local files = {}
  for file, diter, len in mtar.unarchive(base) do
    files[#files+1] = file
    if opts.v then
      log("  ", pfx.info, "extract file: ", file, " (length ", len, ")")
    end
    local absolute = path.concat(opts.root, file)
    local segments = path.split(absolute)
    for i=1, #segments - 1, 1 do
      local create = table.concat(segments, "/", 1, i)
      if not fs.stat(create) then
        local ok, err = fs.touch(create, filetypes.directory)
        if not ok and err then
          log(pfx.err, "failed to create directory " .. create .. ": " .. err)
          exit("leaving any already-created files - manual cleanup may be required!")
        end
      end
    end
    if opts.v then
      log("   ", pfx.info, "writing to: ", absolute)
    end
    local handle, err = io.open(absolute, "w")
    if not handle then
      exit(absolute .. ": " .. err)
    end
    while true do
      local chunk = diter(math.min(len, 2048))
      if not chunk then break end
      handle:write(chunk)
    end
    handle:close()
  end
  base:close()
  log(pfx.info, "ok")
  return files
end

function install_package(name)
  local data, err = search(name)
  if not data then
    exit("failed reading metadata for package " .. name .. ": " .. err)
  end
  local files = extract(path.concat(opts.root, cfg.General.cacheDirectory, name .. ".mtar"))
  installed[name] = {info = data, files = files}
end

local function dl_pkg(name, repo, data)
  download(cfg.Repositories[repo] .. data.mtar,
    path.concat(opts.root, cfg.General.cacheDirectory, name .. ".mtar"))
end

local function install(packages)
  if #packages == 0 then
    exit("no packages to install")
  end
  
  local to_install = {}
  local resolve, resolving = nil, {}
  resolve = function(pkg)
    local data, repo = search(pkg)
    if installed[pkg] and installed[pkg].info.version >= data.version
        and not opts.f then
      log(pfx.err, pkg .. ": package is already installed")
    elseif resolving[pkg] then
      log(pfx.warn, pkg .. ": circular dependency detected")
    else
      to_install[pkg] = {data = data, repo = repo}
      if data.dependencies then
        local orp = resolving[pkg]
        resolving[pkg] = true
        for i, dep in pairs(data.dependencies) do
          resolve(dep)
        end
        resolving[pkg] = orp
      end
    end
  end

  log(pfx.info, "resolving dependencies")
  for i=1, #packages, 1 do
    resolve(packages[i])
  end

  log(pfx.info, "packages to install: ")
  for k in pairs(to_install) do
    io.write(k, "  ")
  end
  
  if not opts.y then
    io.write("\n\nContinue? [Y/n] ")
    repeat
      local c = io.read("l")
      if c == "n" then os.exit() end
      if c ~= "y" and c ~= "" then io.write("Please enter 'y' or 'n': ") end
    until c == "y" or c == ""
  end

  log(pfx.info, "downloading packages")
  for k, v in pairs(to_install) do
    dl_pkg(k, v.repo, v.data)
  end

  log(pfx.info, "installing packages")
  for k in pairs(to_install) do
    install_package(k)
  end

  config.table:save(ipath, installed)
end

if opts.help or args[1] == "help" then
  io.stderr:write(usage)
  os.exit(1)
end

if #args == 0 then
  exit("an operation is required; see 'upm --help'")
end

if args[1] == "install" then
  if not args[2] then
    exit("command verb 'install' requires at least one argument")
  end
  
  table.remove(args, 1)
  install(args)
elseif args[1] == "upgrade" then
  local to_upgrade = {}
  for k, v in pairs(installed) do
    local data, repo = search(k)
    if not (installed[k] and installed[k].info.version >= data.version
        and not opts.f) then
      log(pfx.info, "updating ", k)
      to_upgrade[#to_upgrade+1] = k
    end
  end
  install(to_upgrade)
elseif args[1] == "remove" then
  if not args[2] then
    exit("command verb 'remove' requires at least one argument")
  end
  local rm = assert(loadfile("/bin/rm.lua"))
  for i=2, #args, 1 do
    local ent = installed[args[i]]
    if not ent then
      log(pfx.err, "package ", args[i], " is not installed")
    else
      log(pfx.info, "removing files")
      for i, file in ipairs(ent.files) do
        rm("-rf", path.concat(opts.root, file))
      end
      log(pfx.info, "unregistering package")
      installed[args[i]] = nil
    end
  end
  config.table:save(ipath, installed)
elseif args[1] == "update" then
  update()
elseif args[1] == "search" then
  if not args[2] then
    exit("command verb 'search' requires at least one argument")
  end
  for i=2, #args, 1 do
    local data, repo = search(args[i])
    io.write("\27[94m", repo, "\27[39m/", args[i], " ",
      installed[args[i]] and "\27[96m(installed)\27[39m" or "", "\n")
    io.write("  \27[92mAuthor: \27[39m", data.author or "(unknown)", "\n")
    io.write("  \27[92mDesc: \27[39m", data.description or "(no description)", "\n")
  end
elseif args[1] == "list" then
  if args[2] == "installed" then
    for k in pairs(installed) do
      print(k)
    end
  elseif args[2] == "all" or not args[2] then
    for k, v in pairs(cfg.Repositories) do
      if opts.v then log(pfx.info, "searching list ", k) end
      local data, err = config.table:load(path.concat(opts.root,
        cfg.General.dataDirectory, k .. ".list"))
      if not data then
        log(pfx.warn, "list ", k, " is nonexistent; run 'upm update' to refresh")
      else
        for p in pairs(data.packages) do
          print(p)
        end
      end
    end
  elseif cfg.Repositories[args[2]] then
    local data, err = config.table:load(path.concat(opts.root,
      cfg.General.dataDirectory, args[2] .. ".list"))
    if not data then
      log(pfx.warn, "list ", args[2], " is nonexistent; run 'upm update' to refresh")
    else
      for p in pairs(data.packages) do
        print(p)
      end
    end
  else
    exit("cannot determine target '" .. args[2] .. "'")
  end
else
  exit("operation '" .. args[1] .. "' is unrecognized")
end
�� bin/clear.lua      6-- coreutils: clear --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: clear
Clears the screen by writing to standard output.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if io.stdout.tty then io.stdout:write("\27[2J\27[1H") end
�� bin/pwd.lua      -- coreutils: pwd --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: pwd
Print the current working directory.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

io.write(os.getenv("PWD"), "\n")
�� bin/edit.lua      v#!/usr/bin/env lua
-- edit: a text editor focused purely on speed --

local termio = require("termio")
local sleep = os.sleep or require("posix.unistd").sleep

local file = ...

local buffer = {""}
local cache = {}
local cl, cp = 1, 0
local scroll = {w = 0, h = 0}

if file then
  local handle = io.open(file, "r")
  if handle then
    buffer[1] = nil
    for line in handle:lines("l") do
      buffer[#buffer+1] = line
    end
    handle:close()
  end
else
  io.stderr:write("usage: edit FILE\n")
  os.exit(1)
end

local w, h = termio.getTermSize()

local function status(msg)
  io.write(string.format("\27[%d;1H\27[30;47m\27[2K%s\27[39;49m", h, msg))
end

local function redraw()
  for i=1, h-1, 1 do
    local n = i + scroll.h
    if not cache[n] then
      cache[n] = true
      io.write(string.format("\27[%d;1H%s\27[K", i, buffer[n] or ""))
    end
  end
  status(string.format("%s | ^W=quit ^S=save ^F=find | %d", file:sub(-16), cl))
  io.write(string.format("\27[%d;%dH",
    cl - scroll.h, math.max(1, math.min(#buffer[cl] - cp + 1, w))))
end

local function sscroll(up)
  if up then
    io.write("\27[T")
    scroll.h = scroll.h - 1
    cache[scroll.h + 1] = false
  else
    io.write("\27[S")
    scroll.h = scroll.h + 1
    cache[scroll.h + h + 1] = false
  end
end

local processKey
processKey = function(key, flags)
  flags = flags or {}
  if flags.ctrl then
    if key == "w" then
      io.write("\27[2J\27[1;1H")
      os.exit()
    elseif key == "s" then
      local handle, err = io.open(file, "w")
      if not handle then
        status(err)
        io.flush()
        sleep(1)
        return
      end
      handle:write(table.concat(buffer, "\n") .. "\n")
      handle:close()
    elseif key == "f" then
      status("find: ")
      io.write("\27[30;47m")
      local pat = io.read()
      io.write("\27[39;49m")
      cache = {}
      for i=cl+1, #buffer, 1 do
        if buffer[i]:match(pat) then
          cl = i
          scroll.h = math.max(0, cl - h + 2)
          return
        end
      end
      redraw()
      status("no match")
      io.flush()
      sleep(1)
    elseif key == "m" then
      table.insert(buffer, cl + 1, "")
      processKey("down")
      cache = {}
    end
  elseif not flags.alt then
    if key == "backspace" or key == "delete" or key == "\8" then
      if #buffer[cl] == 0 then
        processKey("up")
        table.remove(buffer, cl + 1)
        cp = 0
        cache = {}
      elseif cp == 0 and #buffer[cl] > 0 then
        buffer[cl] = buffer[cl]:sub(1, -2)
        cache[cl] = false
      elseif cp < #buffer[cl] then
        local tx = buffer[cl]
        buffer[cl] = tx:sub(0, #tx - cp - 1) .. tx:sub(#tx - cp + 1)
        cache[cl] = false
      end
    elseif key == "up" then
      local clch = false
      if (cl - scroll.h) == 1 and cl > 1 then
        sscroll(true)
        cl = cl - 1
        clch = true
      elseif cl > 1 then
        cl = cl - 1
        clch = true
      end
      if clch then
        local dfe_old = #buffer[cl + 1] - cp
        cp = math.max(0, #buffer[cl] - dfe_old)
      end
    elseif key == "down" then
      local clch = false
      if (cl - scroll.h) >= h - 1 and cl < #buffer then
        cl = cl + 1
        sscroll()
        clch = true
      elseif cl < #buffer then
        cl = cl + 1
        clch = true
      end
      if clch then
        local dfe_old = #buffer[cl - 1] - cp
        cp = math.max(0, #buffer[cl] - dfe_old)
      end
    elseif key == "left" then
      if cp < #buffer[cl] then
        cp = cp + 1
      end
    elseif key == "right" then
      if cp > 0 then
        cp = cp - 1
      end
    elseif #key == 1 then
      if cp == 0 then
        buffer[cl] = buffer[cl] .. key
      else
        buffer[cl] = buffer[cl]:sub(0, -cp - 1) .. key .. buffer[cl]:sub(-cp)
      end
      cache[cl] = false
    end
  end
end

io.write("\27[2J")
while true do
  redraw()
  local key, flags = termio.readKey()
  processKey(key, flags)
end
�� bin/tle.lua      [L#!/usr/bin/env lua
-- TLE - The Lua Editor.  Licensed under the DSLv2. --

-- basic terminal interface library --

local vt = {}

function vt.set_cursor(x, y)
  io.write(string.format("\27[%d;%dH", y, x))
end

function vt.get_cursor()
  io.write("\27[6n")
  local resp = ""
  repeat
    local c = io.read(1)
    resp = resp .. c
  until c == "R"
  local y, x = resp:match("\27%[(%d+);(%d+)R")
  return tonumber(x), tonumber(y)
end

function vt.get_term_size()
  local cx, cy = vt.get_cursor()
  vt.set_cursor(9999, 9999)
  local w, h = vt.get_cursor()
  vt.set_cursor(cx, cy)
  return w, h
end

-- keyboard interface with standard VT100 terminals --

local kbd = {}

local patterns = {
  ["1;7."] = {ctrl = true, alt = true},
  ["1;5."] = {ctrl = true},
  ["1;3."] = {alt = true}
}

local substitutions = {
  A = "up",
  B = "down",
  C = "right",
  D = "left",
  ["5"] = "pgUp",
  ["6"] = "pgDown",
}

-- this is a neat party trick.  works for all alphabetical characters.
local function get_char(ascii)
  return string.char(96 + ascii:byte())
end

function kbd.get_key()
--  os.execute("stty raw -echo")
  local data = io.read(1)
  local key, flags
  if data == "\27" then
    local intermediate = io.read(1)
    if intermediate == "[" then
      data = ""
      repeat
        local c = io.read(1)
        data = data .. c
        if c:match("[a-zA-Z]") then
          key = c
        end
      until c:match("[a-zA-Z]")
      flags = {}
      for pat, keys in pairs(patterns) do
        if data:match(pat) then
          flags = keys
        end
      end
      key = substitutions[key] or "unknown"
    else
      key = io.read(1)
      flags = {alt = true}
    end
  elseif data:byte() > 31 and data:byte() < 127 then
    key = data
  elseif data:byte() == 127 then
    key = "backspace"
  else
    key = get_char(data)
    flags = {ctrl = true}
  end
  --os.execute("stty sane")
  return key, flags
end

local rc
-- VLERC parsing
-- yes, this is for TLE.  yes, it's using VLERC.  yes, this is intentional.

rc = {syntax=true,cachelastline=true}

do
  local function split(line)
    local words = {}
    for word in line:gmatch("[^ ]+") do
      words[#words + 1] = word
    end
    return words
  end

  local function pop(t) return table.remove(t, 1) end

  local fields = {
    bi = "builtin",
    bn = "blank",
    ct = "constant",
    cm = "comment",
    is = "insert",
    kw = "keyword",
    kc = "keychar",
    st = "string",
  }
  local colors = {
    black = 30,
    gray = 90,
    lightGray = 37,
    red = 91,
    green = 92,
    yellow = 93,
    blue = 94,
    magenta = 95,
    cyan = 96,
    white = 97
  }
  
  local function parse(line)
    local words = split(line)
    if #words < 1 then return end
    local c = pop(words)
    -- color keyword 32
    -- co kw green
    if c == "color" or c == "co" and #words >= 2 then
      local field = pop(words)
      field = fields[field] or field
      local color = pop(words)
      if colors[color] then
        color = colors[color]
      else
        color = tonumber(color)
      end
      if not color then return end
      rc[field] = color
    elseif c == "cachelastline" then
      local arg = pop(words)
      arg = (arg == "yes") or (arg == "true") or (arg == "on")
      rc.cachelastline = arg
    elseif c == "syntax" then
      local arg = pop(words)
      rc.syntax = (arg == "yes") or (arg == "true") or (arg == "on")
    end
  end

  local home = os.getenv("HOME")
  local handle = io.open(home .. "/.vlerc", "r")
  if not handle then goto anyways end
  for line in handle:lines() do
    parse(line)
  end
  handle:close()
  ::anyways::
end
-- rewritten syntax highlighting engine

local syntax = {}

do
  local function esc(n)
    return string.format("\27[%dm", n)
  end
  
  local colors = {
    keyword = esc(rc.keyword or 91),
    builtin = esc(rc.builtin or 92),
    constant = esc(rc.constant or 95),
    string = esc(rc.string or 93),
    comment = esc(rc.comment or 90),
    keychar = esc(rc.keychar or 94),
    operator = esc(rc.operator or rc.keychar or 94)
  }
  
  local function split(l)
    local w = {}
    for wd in l:gmatch("[^ ]+") do
      w[#w+1]=wd
    end
    return w
  end
  
  local function parse_line(self, line)
    local words = split(line)
    local cmd = words[1]
    if not cmd then
      return
    elseif cmd == "keychars" then
      for i=2, #words, 1 do
        self.keychars = self.keychars .. words[i]
      end
    elseif cmd == "comment" then
      self.comment = words[2] or "#"
    elseif cmd == "keywords" then
      for i=2, #words, 1 do
        self.keywords[words[i]] = true
      end
    elseif cmd == "const" then
      for i=2, #words, 1 do
        self.constants[words[i]] = true
      end
    elseif cmd == "constpat" then
      for i=2, #words, 1 do
        self.constpat[#self.constpat+1] = words[i]
      end
    elseif cmd == "builtin" then
      for i=2, #words, 1 do
        self.builtins[words[i]] = true
      end
    elseif cmd == "operator" then
      for i=2, #words, 1 do
        self.operators[words[i]] = true
      end
    elseif cmd == "strings" then
      if words[2] == "on" then
        self.strings = "\"'"
      elseif words[2] == "off" then
        self.strings = false
      else
        self.strings = self.strings .. (words[2] or "")
      end
    end
  end
  
  -- splits on keychars and spaces
  -- groups together blocks of identical keychars
  local function asplit(self, line)
    local words = {}
    local cword = ""
    local opchars = ""
    --for k in pairs(self.operators) do
    --  opchars = opchars .. k
    --end
    --opchars = "["..opchars:gsub("[%[%]%(%)%.%+%%%$%-%?%^%*]","%%%1").."]"
    for char in line:gmatch(".") do
      local last = cword:sub(-1) or ""
      if #self.keychars > 2 and char:match(self.keychars) then
        if last == char then -- repeated keychar
          cword = cword .. char
        else -- time to split!
          if #cword > 0 then words[#words+1] = cword end
          cword = char
        end
      elseif #self.keychars > 2 and last:match(self.keychars) then
        -- also time to split
        if #cword > 0 then words[#words+1] = cword end
        if char == " " then
          words[#words+1]=char
          cword = ""
        else
          cword = char
        end
      -- not the cleanest solution, but it'll do
      elseif #last > 0 and self.operators[last .. char] then
        if #cword > 0 then words[#words + 1] = cword:sub(1,-2) end
        words[#words+1] = last..char
        cword = ""
      elseif self.strings and char:match(self.strings) then
        if #cword > 0 then words[#words+1] = cword end
        words[#words+1] = char
        cword = ""
      elseif char == " " then
        if #cword > 0 then words[#words+1] = cword end
        words[#words+1] = " "
        cword = ""
      else
        cword = cword .. char
      end
    end
    
    if #cword > 0 then
      words[#words+1] = cword
    end
    
    return words
  end
  
  local function isconst(self, word)
    if self.constants[word] then return true end
    for i=1, #self.constpat, 1 do
      if word:match(self.constpat[i]) then
        return true
      end
    end
    return false
  end
  
  local function isop(self, word)
    return self.operators[word]
  end
  
  local function iskeychar(self, word)
    return #self.keychars > 2 and not not word:match(self.keychars)
  end
  
  local function highlight(self, line)
    local ret = ""
    local strings, comment = self.strings, self.comment
    local words = asplit(self, line)
    local in_str, in_cmt
    for i, word in ipairs(words) do
      --io.stderr:write(word, "\n")
      if strings and word:match(strings) and not in_str and not in_cmt then
        in_str = word:sub(1,1)
        ret = ret .. colors.string .. word
      elseif in_str then
        ret = ret .. word
        if word == in_str then
          ret = ret .. "\27[39m"
          in_str = false
        end
      elseif word:sub(1,#comment) == comment then
        in_cmt = true
        ret = ret .. colors.comment .. word
      elseif in_cmt then
        ret = ret .. word
      else
        local esc = (self.keywords[word] and colors.keyword) or
                    (self.builtins[word] and colors.builtin) or
                    (isconst(self, word) and colors.constant) or
                    (isop(self, word) and colors.operator) or
                    (iskeychar(self, word) and colors.keychar) or
                    ""
        ret = string.format("%s%s%s%s", ret, esc, word,
          (esc~=""and"\27[39m"or""))
      end
    end
    ret = ret .. "\27[39m"
    return ret
  end
  
  function syntax.load(file)
    local new = {
      keywords = {},
      operators = {},
      constants = {},
      constpat = {},
      builtins = {},
      keychars = "",
      comment = "#",
      strings = "\"'",
      highlighter = highlight
    }
    local handle = assert(io.open(file, "r"))
    for line in handle:lines() do
      parse_line(new, line)
    end
    if new.strings then
      new.strings = string.format("[%s]", new.strings)
    end
    new.keychars = string.format("[%s]", (new.keychars:gsub(
      "[%[%]%(%)%.%+%%%$%-%?%^%*]", "%%%1")))
    return function(line)
      return new:highlighter(line)
    end
  end
end


local args = {...}

local cbuf = 1
local w, h = 1, 1
local buffers = {}

local function get_abs_path(file)
  local pwd = os.getenv("PWD")
  if file:sub(1,1) == "/" or not pwd then return file end
  return string.format("%s/%s", pwd, file):gsub("[\\/]+", "/")
end

local function read_file(file)
  local handle, err = io.open(file, "r")
  if not handle then
    return ""
  end
  local data = handle:read("a")
  handle:close()
  return data
end

local function write_file(file, data)
  local handle, err = io.open(file, "w")
  if not handle then return end
  handle:write(data)
  handle:close()
end

local function get_last_pos(file)
  local abs = get_abs_path(file)
  local pdata = read_file(os.getenv("HOME") .. "/.vle_positions")
  local pat = abs:gsub("[%[%]%(%)%^%$%%%+%*%*]", "%%%1") .. ":(%d+)\n"
  if pdata:match(pat) then
    local n = tonumber(pdata:match(pat))
    return n or 1
  end
  return 1
end

local function save_last_pos(file, n)
  local abs = get_abs_path(file)
  local escaped = abs:gsub("[%[%]%(%)%^%$%%%+%*%*]", "%%%1")
  local pat = "(" .. escaped .. "):(%d+)\n"
  local vp_path = os.getenv("HOME") .. "/.vle_positions"
  local data = read_file(vp_path)
  if data:match(pat) then
    data = data:gsub(pat, string.format("%%1:%d\n", n))
  else
    data = data .. string.format("%s:%d\n", abs, n)
  end
  write_file(vp_path, data)
end

local commands -- forward declaration so commands and load_file can access this
local function load_file(file)
  local n = #buffers + 1
  buffers[n] = {name=file, cline = 1, cpos = 0, scroll = 1, lines = {}, cache = {}}
  local handle = io.open(file, "r")
  cbuf = n
  if not handle then
    buffers[n].lines[1] = ""
    return
  end
  for line in handle:lines() do
    buffers[n].lines[#buffers[n].lines + 1] =
                                     (line:gsub("[\r\n]", ""):gsub("\t", "  "))
  end
  handle:close()
  buffers[n].cline = math.min(#buffers[n].lines,
    get_last_pos(get_abs_path(file)))
  buffers[n].scroll = math.min(1, buffers[n].cline - h)
  if commands and commands.t then commands.t() end
end

if args[1] == "--help" then
  print("usage: tle [FILE]")
  os.exit()
elseif args[1] then
  for i=1, #args, 1 do
    load_file(args[i])
  end
else
  buffers[1] = {name="<new>", cline = 1, cpos = 0, scroll = 1, lines = {""}, cache = {}}
end

local function truncate_name(n, bn)
  if #n > 16 then
    n = "..." .. (n:sub(-13))
  end
  if buffers[bn].unsaved then n = n .. "*" end
  return n
end

-- TODO: may not draw correctly on small terminals or with long buffer names
local function draw_open_buffers()
  vt.set_cursor(1, 1)
  local draw = "\27[2K\27[46m"
  local dr = ""
  for i=1, #buffers, 1 do
    dr = dr .. truncate_name(buffers[i].name, i) .. "   "
    draw = draw .. "\27[36m \27["..(i == cbuf and "107" or "46")..";30m " .. truncate_name(buffers[i].name, i) .. " \27[46m"
  end
  local diff = string.rep(" ", w - #dr)
  draw = draw .. "\27[46m" .. diff .. "\27[39;49m"
  if #dr:gsub("\27%[[%d.]+m", "") > w then
    draw = draw:sub(1, w)
  end
  io.write(draw, "\27[39;49m")--, "\n\27[G\27[2K\27[36m", string.rep("-", w))
end

local function draw_line(line_num, line_text)
  local write
  if line_text then
    line_text = line_text:gsub("\t", " ")
    if #line_text > (w - 4) then
      line_text = line_text:sub(1, w - 5)
    end
    if buffers[cbuf].highlighter then
      line_text = buffers[cbuf].highlighter(line_text)
    end
    write = string.format("\27[2K\27[36m%4d\27[37m %s", line_num,
                                   line_text)
  else
    write = "\27[2K\27[96m~\27[37m"
  end
  io.write(write)
end

-- dynamically getting dimensions makes the experience slightly nicer for the
-- 2%, at the cost of a rather significant performance drop on slower
-- terminals.  hence, I have removed it.
--
-- to re-enable it, just move the below line inside the draw_buffer() function.
-- you may want to un-comment it.
-- w, h = vt.get_term_size()
local function draw_buffer()
  io.write("\27[39;49m")
  if os.getenv("TERM") == "cynosure" then
    io.write("\27?14c")
  end
  draw_open_buffers()
  local buffer = buffers[cbuf]
  local top_line = buffer.scroll
  for i=1, h - 1, 1 do
    local line = top_line + i - 1
    if (not buffer.cache[line]) or
        (buffer.lines[line] and buffer.lines[line] ~= buffer.cache[line]) then
      vt.set_cursor(1, i + 1)
      draw_line(line, buffer.lines[line])
      buffer.cache[line] = buffer.lines[line] or "~"
    end
  end
  if os.getenv("TERM") == "cynosure" then
    io.write("\27?4c")
  end
end

local function update_cursor()
  local buf = buffers[cbuf]
  local mw = w - 5
  local cx = (#buf.lines[buf.cline] - buf.cpos) + 6
  local cy = buf.cline - buf.scroll + 2
  if cx > mw then
    vt.set_cursor(1, cy)
    draw_line(buf.cline, (buf.lines[buf.cline]:sub(cx - mw + 1, cx)))
    cx = mw
  end
  vt.set_cursor(cx, cy)
end

local arrows -- these forward declarations will kill me someday
local function insert_character(char)
  local buf = buffers[cbuf]
  buf.unsaved = true
  if char == "\n" then
    local text = ""
    local old_cpos = buf.cpos
    if buf.cline > 1 then -- attempt to get indentation of previous line
      local prev = buf.lines[buf.cline]
      local indent = #prev - #(prev:gsub("^[%s]+", ""))
      text = (" "):rep(indent)
    end
    if buf.cpos > 0 then
      text = text .. buf.lines[buf.cline]:sub(-buf.cpos)
      buf.lines[buf.cline] = buf.lines[buf.cline]:sub(1,
                                          #buf.lines[buf.cline] - buf.cpos)
    end
    table.insert(buf.lines, buf.cline + 1, text)
    arrows.down()
    buf.cpos = old_cpos
    return
  end
  local ln = buf.lines[buf.cline]
  if char == "\8" then
    buf.cache[buf.cline] = nil
    buf.cache[buf.cline - 1] = nil
    buf.cache[buf.cline + 1] = nil
    buf.cache[#buf.lines] = nil
    if buf.cpos < #ln then
      buf.lines[buf.cline] = ln:sub(0, #ln - buf.cpos - 1)
                                                  .. ln:sub(#ln - buf.cpos + 1)
    elseif ln == "" then
      if buf.cline > 1 then
        table.remove(buf.lines, buf.cline)
        arrows.up()
        buf.cpos = 0
      end
    elseif buf.cline > 1 then
      local line = table.remove(buf.lines, buf.cline)
      local old_cpos = buf.cpos
      arrows.up()
      buf.cpos = old_cpos
      buf.lines[buf.cline] = buf.lines[buf.cline] .. line
    end
  else
    buf.lines[buf.cline] = ln:sub(0, #ln - buf.cpos) .. char
                                                  .. ln:sub(#ln - buf.cpos + 1)
  end
end

local function trim_cpos()
  if buffers[cbuf].cpos > #buffers[cbuf].lines[buffers[cbuf].cline] then
    buffers[cbuf].cpos = #buffers[cbuf].lines[buffers[cbuf].cline]
  end
  if buffers[cbuf].cpos < 0 then
    buffers[cbuf].cpos = 0
  end
end

local function try_get_highlighter()
  local ext = buffers[cbuf].name:match("%.(.-)$")
  if not ext then
    return
  end
  local try = "/usr/share/VLE/"..ext..".vle"
  local also_try = os.getenv("HOME").."/.local/share/VLE/"..ext..".vle"
  local ok, ret = pcall(syntax.load, also_try)
  if ok then
    return ret
  else
    ok, ret = pcall(syntax.load, try)
    if ok then
      return ret
    else
      ok, ret = pcall(syntax.load, "syntax/"..ext..".vle")
      if ok then
        io.stderr:write("OKAY")
        return ret
      end
    end
  end
  return nil
end

arrows = {
  up = function()
    local buf = buffers[cbuf]
    if buf.cline > 1 then
      local dfe = #(buf.lines[buf.cline] or "") - buf.cpos
      buf.cline = buf.cline - 1
      if buf.cline < buf.scroll and buf.scroll > 0 then
        buf.scroll = buf.scroll - 1
        io.write("\27[T") -- scroll up
        buf.cache[buf.cline] = nil
      end
      buf.cpos = #buf.lines[buf.cline] - dfe
    end
    trim_cpos()
  end,
  down = function()
    local buf = buffers[cbuf]
    if buf.cline < #buf.lines then
      local dfe = #(buf.lines[buf.cline] or "") - buf.cpos
      buf.cline = buf.cline + 1
      if buf.cline > buf.scroll + h - 3 then
        buf.scroll = buf.scroll + 1
        io.write("\27[S") -- scroll down, with some VT100 magic for efficiency
        buf.cache[buf.cline] = nil
      end
      buf.cpos = #buf.lines[buf.cline] - dfe
    end
    trim_cpos()
  end,
  left = function()
    local buf = buffers[cbuf]
    if buf.cpos < #buf.lines[buf.cline] then
      buf.cpos = buf.cpos + 1
    elseif buf.cline > 1 then
      arrows.up()
      buf.cpos = 0
    end
  end,
  right = function()
    local buf = buffers[cbuf]
    if buf.cpos > 0 then
      buf.cpos = buf.cpos - 1
    elseif buf.cline < #buf.lines then
      arrows.down()
      buf.cpos = #buf.lines[buf.cline]
    end
  end,
  -- not strictly an arrow but w/e
  backspace = function()
    insert_character("\8")
  end
}

-- TODO: clean up this function
local function prompt(text)
  -- box is max(#text, 18)x3
  local box_w = math.max(#text, 18)
  local box_x, box_y = w//2 - (box_w//2), h//2 - 1
  vt.set_cursor(box_x, box_y)
  io.write("\27[46m", string.rep(" ", box_w))
  vt.set_cursor(box_x, box_y)
  io.write("\27[30;46m", text)
  local inbuf = ""
  local function redraw()
    vt.set_cursor(box_x, box_y + 1)
    io.write("\27[46m", string.rep(" ", box_w))
    vt.set_cursor(box_x + 1, box_y + 1)
    io.write("\27[36;40m", inbuf:sub(-(box_w - 2)), string.rep(" ",
                                                          (box_w - 2) - #inbuf))
    vt.set_cursor(box_x, box_y + 2)
    io.write("\27[46m", string.rep(" ", box_w))
    vt.set_cursor(box_x + 1 + math.min(box_w - 2, #inbuf), box_y + 1)
  end
  repeat
    redraw()
    local c, f = kbd.get_key()
    f = f or {}
    if c == "backspace" or (f.ctrl and c == "h") then
      inbuf = inbuf:sub(1, -2)
    elseif not (f.ctrl or f.alt) then
      inbuf = inbuf .. c
    end
  until (c == "m" and (f or {}).ctrl)
  io.write("\27[39;49m")
  buffers[cbuf].cache = {}
  return inbuf
end

local prev_search
commands = {
  b = function()
    if cbuf < #buffers then
      cbuf = cbuf + 1
      buffers[cbuf].cache = {}
    end
  end,
  v = function()
    if cbuf > 1 then
      cbuf = cbuf - 1
      buffers[cbuf].cache = {}
    end
  end,
  f = function()
    local search_pattern = prompt("Search pattern:")
    if #search_pattern == 0 then search_pattern = prev_search end
    prev_search = search_pattern
    for i = buffers[cbuf].cline + 1, #buffers[cbuf].lines, 1 do
      if buffers[cbuf].lines[i]:match(search_pattern) then
        commands.g(i)
        return
      end
    end
    for i = 1, #buffers[cbuf].lines, 1 do
      if buffers[cbuf].lines[i]:match(search_pattern) then
        commands.g(i)
        return
      end
    end
  end,
  g = function(i)
    i = i or tonumber(prompt("Goto line:"))
    i = math.min(i, #buffers[cbuf].lines)
    buffers[cbuf].cline = i
    buffers[cbuf].scroll = i - math.min(i, h // 2)
  end,
  k = function()
    local del = prompt("# of lines to delete:")
    del = tonumber(del)
    if del and del > 0 then
      for i=1, del, 1 do
        local ln = buffers[cbuf].cline
        if ln > #buffers[cbuf].lines then return end
        table.remove(buffers[cbuf].lines, ln)
      end
      buffers[cbuf].cpos = 0
      buffers[cbuf].unsaved = true
      if buffers[cbuf].cline > #buffers[cbuf].lines then
        buffers[cbuf].cline = #buffers[cbuf].lines
      end
    end
  end,
  r = function()
    local search_pattern = prompt("Search pattern:")
    local replace_pattern = prompt("Replace with?")
    for i = 1, #buffers[cbuf].lines, 1 do
      buffers[cbuf].lines[i] = buffers[cbuf].lines[i]:gsub(search_pattern,
                                                                replace_pattern)
    end
  end,
  t = function()
    buffers[cbuf].highlighter = try_get_highlighter()
    buffers[cbuf].cache = {}
  end,
  h = function()
    insert_character("\8")
  end,
  m = function() -- this is how we insert a newline - ^M == "\n"
    insert_character("\n")
  end,
  n = function()
    local file_to_open = prompt("Enter file path:")
    load_file(file_to_open)
  end,
  s = function()
    local ok, err = io.open(buffers[cbuf].name, "w")
    if not ok then
      prompt(err)
      return
    end
    for i=1, #buffers[cbuf].lines, 1 do
      ok:write(buffers[cbuf].lines[i], "\n")
    end
    ok:close()
    save_last_pos(buffers[cbuf].name, buffers[cbuf].cline)
    buffers[cbuf].unsaved = false
  end,
  w = function()
    -- the user may have unsaved work, prompt
    local unsaved
    for i=1, #buffers, 1 do
      if buffers[i].unsaved then
        unsaved = true
       break
      end
    end
    if unsaved then
      local really = prompt("Delete unsaved work? [y/N] ")
      if really ~= "y" then
        return
      end
    end
    table.remove(buffers, cbuf)
    cbuf = math.min(cbuf, #buffers)
    if #buffers == 0 then
      commands.q()
    end
    buffers[cbuf].cache = {}
  end,
  q = function()
    if #buffers > 0 then -- the user may have unsaved work, prompt
      local unsaved
      for i=1, #buffers, 1 do
        if buffers[i].unsaved then
          unsaved = true
          break
        end
      end
      if unsaved then
        local really = prompt("Delete unsaved work? [y/N] ")
        if really ~= "y" then
          return
        end
      end
    end
    io.write("\27[2J\27[1;1H\27[m")
    if os.getenv("TERM") == "paragon" then
      io.write("\27(r\27(L")
    elseif os.getenv("TERM") == "cynosure" then
      io.write("\27?13;2c")
    else
      os.execute("stty sane")
    end
    os.exit()
  end
}

for i=1, #buffers, 1 do
  cbuf = i
  buffers[cbuf].highlighter = try_get_highlighter()
end
io.write("\27[2J")
if os.getenv("TERM") == "paragon" then
  io.write("\27(R\27(l\27[8m")
elseif os.getenv("TERM") == "cynosure" then
  io.write("\27?3;12c\27[8m")
else
  os.execute("stty raw -echo")
end
w, h = vt.get_term_size()

while true do
  draw_buffer()
  update_cursor()
  local key, flags = kbd.get_key()
  flags = flags or {}
  if flags.ctrl then
    if commands[key] then
      commands[key]()
    end
  elseif flags.alt then
  elseif arrows[key] then
    arrows[key]()
  elseif #key == 1 then
    insert_character(key)
  end
end
�� 
bin/sh.lua      3^-- a shell.

local fs = require("filesystem")
local pipe = require("pipe")
local users = require("users")
local process = require("process")
local builtins = require("sh/builtins")
local tokenizer = require("tokenizer")
local args, shopts = require("argutil").parse(...)

if shopts.help then
  io.stderr:write([[
usage: sh [-e]
A Bourne-ish shell.  Mildly deprecated in favor of
the Lisp-like SHell (lsh).

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local w_iter = tokenizer.new()

os.setenv("PWD", os.getenv("PWD") or "/")
os.setenv("PS1", os.getenv("PS1") or "\\u@\\h: \\W\\$ ")

local def_path = "/bin:/sbin:/usr/bin"

w_iter.discard_whitespace = false
w_iter:addToken("bracket", "()[]{}<>")
w_iter:addToken("splitter", "$|&\"'; ")

local function tkiter()
  return w_iter:matchToken()
end

local function split(text)
  w_iter.text = text
  w_iter.i = 0
  local words = {}
  for word, ttype in tkiter do
    word = word:gsub("\n", "")
    words[#words + 1] = word
  end
  return words
end

local token_st = {}

local function push(t)
  token_st[#token_st+1] = t
end

local function pop(t)
  return table.remove(token_st, #token_st)
end

local state = {
  backticked = false,
  quoted = false,
}

local alt = {
  ["("] = ")",
  ["{"] = "}",
  ["["] = "]"
}

local splitc = {
  ["|"] = true,
  [";"] = true,
  ["&"] = true,
  [">"] = true,
  ["<"] = true
}

local var_decl = "([^ ]+)=(.-)"

-- builtin command environment
local penv = {
  env = process.info().data.env,
  shopts = shopts,
  exit = false
}
local function resolve_program(program)
  if builtins[program] then
    return function(...) return builtins[program](penv, ...) end
  end

  if program == "" or not program then
    return
  end
  
  local pwd = os.getenv("PWD")
  local path = os.getenv("PATH") or def_path
  
  if program:match("/") then
    local relative
  
    if program:sub(1,1) == "/" then
      relative = program
    else
      relative = string.format("%s/%s", pwd, program)
    end
    
    if fs.stat(relative) then
      return relative
    elseif fs.stat(relative .. ".lua") then
      return relative .. ".lua"
    end
  end

  for entry in path:gmatch("[^:]+") do
    local try = string.format("%s/%s", entry, program)
  
    if fs.stat(try) then
      return try
    elseif fs.stat(try .. ".lua") then
      return try .. ".lua"
    end
  end

  return nil, "sh: " .. program .. ": command not found"
end

local function os_execute(...)
  local prg = table.concat(table.pack(...), " ")
  local e, c = penv.execute(prg)
  return c ~= 0, e, c
end

local function run_programs(programs, getout)
  local sequence = {{}}
  local execs = {}
  for i, token in ipairs(programs) do
    if splitc[token] then
      if #sequence[#sequence] > 0 then
        table.insert(sequence, token)
        sequence[#sequence + 1] = {}
      else
        return nil, "sh: syntax error near unexpected token '"..token.."'"
      end
    else
      table.insert(sequence[#sequence], token)
    end
  end

  if #sequence[1] == 0 then
    return true
  end

  for i, program in ipairs(sequence) do
    if type(program) ~= "string" then
      local prg_env = {}
      program.env = prg_env
      while #program > 0 and program[1]:match(var_decl) do
        local k, v = table.remove(program, 1):match(var_decl)
        prg_env[k] = v
      end

      if #program == 0 then
        for k, v in pairs(prg_env) do
          os.setenv(k, v)
        end
        return
      end

      for i, token in ipairs(program) do
        if token:match("%$([^ ]+)") then
          program[i] = os.getenv(token:sub(2))
        end
      end

      program[0] = program[1]
      local pre
      program[1], pre = resolve_program(program[1])
      if not program[1] and pre then
        return nil, pre
      end

      for k, v in pairs(program) do
        if type(v) == "string" and not v:match("[^%s]") and k ~= 0 then
          table.remove(program, k)
        end
      end

      if (not penv.skip_until) or program[0] == penv.skip_until then
        penv.skip_until = nil
        execs[#execs + 1] = program
      end
      -- TODO: there's some weirdness that will happen here under
      -- certain conditions
    elseif program == "|" then
      if type(sequence[i - 1]) ~= "table" or
          type(sequence[i + 1]) ~= "table" then
        return nil, "sh: syntax error near unexpected token '|'"
      end
      local pipe = pipe.create()
      sequence[i - 1].output = pipe
      sequence[i + 1].input = pipe
    elseif program == ">" then
      if type(sequence[i - 1]) ~= "table" or
          type(sequence[i + 1]) ~= "table" then
        return nil, "sh: syntax error near unexpected token '>'"
      end
      local handle, err = io.open(sequence[i+1][1], "a")
      if not handle then
        handle, err = io.open(sequence[i+1][1], "w")
      end
      if not handle then
        return nil, "sh: cannot open " .. sequence[i+1][1] .. ": " ..
          err .. "\n"
      end
      table.remove(sequence, i + 1)
      sequence[i - 1].output = handle
      handle.buffer_mode = "none"
      getout = false
    end
  end

  local outbuf = ""
  if getout then
    sequence[#sequence].output = {
      write = function(_, ...)
        outbuf = outbuf .. table.concat(table.pack(...))
        return _
      end, close = function()end
    }
    setmetatable(sequence[#sequence].output, {__name = "FILE*"})
  end

  local exit, code

  for i, program in ipairs(execs) do
    if program[1] == "\n" or program[1] == "" or not program[1] then
      return
    end

    local exec, err, pname
    if type(program[1]) == "function" then
      exec = program[1]
      pname = program[0] .. " " .. table.concat(program, " ", 2)
    else
      local handle = io.open(program[1], "r")
      
      if handle then
        local data = handle:read(64)
        handle:close()
        local shebang = data:match("#!([^\n]+)\n")
        if shebang then
          local ok, err = resolve_program(shebang)
          if not ok then
            return nil, "sh: " .. program[0] .. ": " .. shebang ..
              ": bad interpreter: " .. (err or "command not found")
          end
          table.insert(program, 1, shebang)
        end
      end

      exec, err = loadfile(program[1])
      pname = table.concat(program, " ")
    end

    if not exec then
      return nil, "sh: " .. program[0] .. ": " ..
        (err or "command not found")
    end
    
    local pid = process.spawn {
      func = function()
        for k, v in pairs(program.env) do
          os.setenv(k, v)
        end

        -- this hurts me, but i must do it
        local old_osexe = os.execute
        local old_osexit = os.exit
        os.execute = os_execute
        function os.exit(n)
          os.execute = old_osexe
          os.exit = old_osexit
          if program.output then
            program.output:close()
          end
          old_osexit(n)
        end
    
        if program.input then
          io.input(program.input)
          --io.stdin = program.input
        end
        
        if program.output then
          io.output(program.output)
          --io.stdout = program.output
        end
        
        local ok, err, ret1 = xpcall(exec, debug.traceback,
          table.unpack(program, 2))

        if not io.input().tty then io.input():close() end
        if not io.output().tty then io.output():close() end

        if not ok and err then
          io.stderr:write(program[0], ": ", err, "\n")
          os.exit(127)
        elseif not err and ret1 then
          io.stderr:write(program[0], ": ", err, "\n")
          os.exit(127)
        end
        
        os.exit(0)
      end,
      name = pname or program[0],
      stdin = program.input,
      input = program.input,
      stdout = program.output,
      output = program.output,
      stderr = program.stderr
                or io.stderr
    }

    code, exit = process.await(pid)

    if code ~= 0 and shopts.e then
      return exit, code
    end
  end

  if getout then return outbuf, exit, code end
  return exit, code
end

local function parse(cmd)
  local ret = {}
  local words = split(cmd)
  for i=1, #words, 1 do
    local token = words[i]
    token = token:gsub("\n", "")
    local opening = token_st[#token_st]
    local preceding = words[i - 1]
    if token:match("[%(%{]") and not state.quoted then -- opening bracket
      if preceding == "$" then
        push(token)
        if ret[#ret] == "$" then ret[#ret] = "" else ret[#ret + 1] = "" end
      else
        -- TODO: handle this
        return nil, "sh: syntax error near unexpected token '" .. token .. "'"
      end
    elseif token:match("[%)%}]") and not state.quoted then -- closing bracket
      local ttok = pop()
      if token ~= alt[ttok] then
        return nil, "sh: syntax error near unexpected token '" .. token .. "'"
      end
      local pok, perr = parse(table.concat(ret[#ret], " "))
      if not pok then
        return nil, perr
      end
      local rok, rerr = run_programs(pok, true)
      if not rok then
        return nil, rerr
      end
      ret[#ret] = rok
    elseif token:match([=[["']]=]) then
      if state.quoted and token == state.quoted then
        state.quoted = false
      elseif not state.quoted then
        state.quoted = token
        ret[#ret + 1] = ""
      else
        ret[#ret] = ret[#ret] .. token
      end
    elseif opening and opening:match("[%({]") then
      ret[#ret + 1] = {}
      table.insert(ret[#ret], token)
    elseif state.quoted then
      ret[#ret] = ret[#ret] .. token
    elseif token:match("[%s\n]") then
      if (not ret[#ret]) or #ret[#ret] > 0 then ret[#ret + 1] = "" end
    elseif token == ";" or token == ">" then
      if #ret == 0 or #(ret[#ret - 1] or ret[#ret]) == 0 then
        io.stderr:write("sh: syntax error near unexpected token '", token,
          "'\n")
        return nil
      end
      ret[#ret + 1] = token
      ret[#ret + 1] = ""
    elseif token then
      if #ret == 0 then ret[1] = "" end
      ret[#ret] = ret[#ret] .. token
    end
  end
  return ret
end

-- instantly replace these
local crep = {
  ["\\a"] = "\a",
  ["\\e"] = "\27",
  ["\\n"] = "\n",
  ["\\([0-7]+)"] = function(a) return string.char(tonumber(a, 8)) end,
  ["\\x([0-9a-fA-F][0-9a-fA-F])"] = function(a) return
    string.char(tonumber(a,16)) end,
  ["~"] = os.getenv("HOME")
}

local function execute(cmd)
  for k, v in pairs(crep) do
    cmd = cmd:gsub(k, v)
  end

  local data, err = parse(cmd)
  if not data then
    return nil, err
  end

  return run_programs(data)
end

penv.execute = execute

-- this should be mostly complete
local prep = {
  ["\\%$"] = function() return process.info().owner == 0 and "#" or "$" end,
  ["\\a"] = function() return "\a" end,
  ["\\A"] = function() return os.date("%H:%M") end,
  ["\\d"] = function() return os.date("%a %b %d") end,
  ["\\e"] = function() return "\27" end,
  ["\\h"] = function() return os.getenv("HOSTNAME") or "localhost" end,
  ["\\H"] = function() return os.getenv("HOSTNAME") or "localhost" end,
  ["\\j"] = function() return "0" end, -- TODO what does this actually do?
  ["\\l"] = function() return "tty"..(io.stdin.base.ttyn or 0) end,
  ["\\n"] = function() return "\n" end,
  ["\\r"] = function() return "\r" end,
  ["\\s"] = function() return "sh" end,
  ["\\t"] = function() return os.date("%T") end,
  ["\\T"] = function() return os.date("%I:%M:%S") end,
  ["\\u"] = function() return os.getenv("USER") end,
  ["\\v"] = function() return SH_VERSION end,
  ["\\V"] = function() return SH_VERSION end,
  ["\\w"] = function() return (os.getenv("PWD"):gsub("^" .. ((os.getenv("HOME")
    or "/"):gsub("%.%-%+", "%%%1")), "~")) end,
  ["\\W"] = function() local n = require("path").split(os.getenv("PWD"));
    if (not n[#n]) or #n[#n] == 0 then return "/" else return n[#n] end end,
}

local function prompt(text)
  if not text then return "$ " end
  for k, v in pairs(prep) do
    text = text:gsub(k, v() or "")
  end
  return text
end

local function exec_script(s)
  local handle, err = io.open(s, "r")
  if not handle then
    io.stderr:write(s, ": ", err, "\n")
    if not noex then os.exit(1) end
    return
  end
  local data = handle:read("a")
  handle:close()

  local ok, err = execute(data)
  if not ok and err then
    io.stderr:write(s, ": ", err, "\n")
    if not noex then os.exit(1) end
    return
  end
end

if fs.stat("/etc/profile") then
  exec_script("/etc/profile", true)
end

if fs.stat(os.getenv("HOME").."/.shrc") then
  exec_script(os.getenv("HOME").."/.shrc", true)
end

if io.stdin.tty then
  -- ignore ^C
  process.info().data.self.signal[process.signals.interrupt] = function() end

  -- ignore ^Z
  process.info().data.self.signal[process.signals.kbdstop] = function() end

  -- ignore ^D
  process.info().data.self.signal[process.signals.hangup] = function() end
end

while not penv.exit do
  io.write("\27?0c", prompt(os.getenv("PS1")))
  local inp = io.read("L")
  if inp then
    local ok, err = execute(inp)
    if not ok and err then
      io.stderr:write(err, "\n")
    end
  end
end

if type(penv.exit) == "number" then
  os.exit(penv.exit)
end

os.exit(0)
�� bin/less.lua      -- coreutils: less --

local text = require("text")
local termio = require("termio")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: less FILE ...
Page through FILE(s).  They will be concatenated.
]])
  os.exit(1)
end

local lines = {}
local w, h = termio.getTermSize()
local scr = 0

local function scroll(n)
  if n then
    if scr+h < #lines then
      scr=scr+1
    end
  elseif scr > 0 then
    scr=scr-1
  end
end

for i=1, #args, 1 do
  for line in io.lines(args[i], "l") do
    lines[#lines+1] = line
  end
end

local function redraw()
  io.write("\27[1;1H")
  for i=1, h-1, 1 do
    io.write("\27[2K", lines[scr+i] or "", "\n")
  end
end

io.write("\27[2J")
redraw()

local prompt = string.format("\27[%d;1H\27[2K:", h)

io.write(prompt)
while true do
  local key, flags = termio.readKey()
  if key == "c" and flags.control then
    -- interrupted
    io.write("interrupted\n")
    os.exit(1)
  elseif key == "q" then
    io.write("\27[2J\27[1;1H")
    io.flush()
    os.exit(0)
  elseif key == "up" then
    scroll(false)
  elseif key == "down" then
    scroll(true)
  elseif key == " " then
    scr=math.min(scr+h, #lines - h - 1)
  elseif key == "/" then
    local search = io.read()
  end
  redraw()
  io.write(prompt)
end
�� bin/lua.lua      ?-- lua REPL --

local args = table.pack(...)
local notopts, opts = require("argutil").parse(...)

local readline = require("readline")

opts.i = opts.i or #args == 0

if opts.help then
  io.stderr:write([=[
usage: lua [options] [script [args ...]]
Available options are:
  -e stat  execute string 'stat'
  -i       enter interactive mode after executing 'script'
  -l name  require library 'name' into global 'name'

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]=])
  os.exit(1)
end

-- prevent some pollution of _G
local prog_env = {}
for k, v in pairs(_G) do prog_env[k] = v end
prog_env.require = require -- ????
setmetatable(prog_env, {__index = _G})

if opts.i then
  if _VERSION == "Lua 5.2" then
    io.write(_VERSION, "  Copyright (C) 1994-2015 Lua.org, PUC-Rio\n")
  else
    io.write(_VERSION, "  Copyright (C) 1994-2020 Lua.org, PUC-Rio\n")
  end
end

for i=1, #args, 1 do
  if args[i] == "-e" then
    opts.e = args[i + 1]
    if not opts.e then
      io.stderr:write("lua: '-e' needs argument")
    end
    break
  end
end

if opts.e then
  local ok, err = load(opts.e, "=(command line)", "bt", prog_env)
  if not ok then
    io.stderr:write(err, "\n")
    if not opts.i then os.exit(1) end
  else
    local result = table.pack(xpcall(ok, debug.traceback))
    if not result[1] and result[2] then
      io.stderr:write(result[2], "\n")
      if not opts.i then os.exit(1) end
    elseif result[1] then
      print(table.unpack(result, 2, result.n))
    end
  end
end

if opts.i then
  local hist = {}
  local rlopts = {history = hist}
  while true do
    io.write("> ")
    local eval = readline(rlopts)
    hist[#hist+1] = eval
    local ok, err = load(eval, "=stdin", "bt", prog_env)
    if not ok then
      ok, err = load("return " ..eval, "=stdin", "bt", prog_env)
    end
    if not ok then
      io.stderr:write(err, "\n")
    else
      local result = table.pack(xpcall(ok, debug.traceback))
      if not result[1] and result[2] then
        io.stderr:write(result[2], "\n")
      elseif result[1] then
        print(table.unpack(result, 2, result.n))
      end
    end
  end
end
�� 
bin/sv.lua      �-- sv: service management --

local sv = require("sv")
local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help or (args[1] ~= "list" and #args < 2) then
  io.stderr:write([[
usage: sv [up|down] service
   or: sv list
Manage running services.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local verb = args[1]

if not sv[verb] then
  io.stderr:write("bad command verb '", verb, "'\n")
  os.exit(1)
end

if verb == "list" then
  local r = sv.list()
  for k,v in pairs(r) do
    print(k)
  end
else
  local ok, err = sv[verb](args[2])
  if not ok then
    io.stderr:write("sv: ", verb, ": ", err, "\n")
    os.exit(1)
  end
end
�� bin/tfmt.lua      P-- coreutils: text formatter --

local text = require("text")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: tfmt [options] FILE ...
Format FILE(s) according to a simple format
specification.

Options:
  --wrap=WD       Wrap output text at WD
                  characters.
  --output=FILE   Send output to file FILE.

ULOS Coreutils copyright (c) 2021 Ocawesome101
under the DSLv2.
]])
  os.exit(1)
end

local colors = {
  bold = "97",
  regular = "39",
  italic = "36",
  link = "94",
  file = "93",
  red = "91",
  green = "92",
  yellow = "93",
  blue = "94",
  magenta = "95",
  cyan = "96",
  white = "97"
}

local patterns = {
  {"%*({..-})", "bold"},
  {"%$({..-})", "italic"},
  {"@({..-})", "link"},
  {"#({..-})", "file"},
  {"red({..-})", "red"},
  {"green({..-})", "green"},
  {"yellow({..-})", "yellow"},
  {"blue({..-})", "blue"},
  {"magenta({..-})", "magenta"},
  {"cyan({..-})", "cyan"},
  {"white({..-})", "white"},
}

opts.wrap = tonumber(opts.wrap)

local output = io.output()
if opts.output and type(opts.output) == "string" then
  local handle, err = io.open(opts.output, "w")
  if not handle then
    io.stderr:write("tfmt: cannot open ", opts.output, ": ", err, "\n")
    os.exit(1)
  end

  output = handle
end

for i=1, #args, 1 do
  local handle, err = io.open(args[i], "r")
  if not handle then
    io.stderr:write("tfmt: ", args[i], ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()

  for i=1, #patterns, 1 do
    data = data:gsub(patterns[i][1], function(x)
      return string.format("\27[%sm%s\27[%sm", colors[patterns[i][2]],
        x:sub(2, -2), colors.regular)
    end)
  end

  if opts.wrap then
    data = text.wrap(data, opts.wrap)
  end

  output:write(data .. "\n")
  output:flush()
end

if opts.output then
  output:close()
end
�� bin/passwd.lua      	�-- coreutils: passwd --

local sha = require("sha3").sha256
local acl = require("acls")
local users = require("users")
local process = require("process")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: passwd [options] USER
   or: passwd [options]
Generate or modify users.

Options:
  -i, --info      Print the user's info and exit.
  --home=PATH     Set the user's home directory.
  --shell=PATH    Set the user's shell.
  --enable=P,...  Enable user ACLs.
  --disable=P,... Disable user ACLs.
  -r, --remove    Remove the specified user.

Note that an ACL may only be set if held by the
current user.  Only root may delete users.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local current = users.attributes(process.info().owner).name
local user = args[1] or current

local _ok, _err = users.get_uid(user)
local attr
if not _ok then
  attr = {}
else
  attr = users.attributes(_ok)
end

attr.home = opts.home or attr.home or "/home/" .. user
attr.shell = opts.shell or attr.shell or "/bin/lsh"
attr.uid = _ok
attr.name = attr.name or user

local acls = attr.acls or 0
attr.acls = {}
for k, v in pairs(acl.user) do
  if acls | v ~= 0 then
    attr.acls[k] = true
  end
end

if opts.i or opts.info then
  print("uid:   " .. attr.uid)
  print("name:  " .. attr.name)
  print("home:  " .. attr.home)
  print("shell: " .. attr.shell)
  local cacls = {}
  for k,v in pairs(attr.acls) do if v then cacls[#cacls+1] = k end end
  print("acls:  " .. table.concat(cacls, " | "))
  os.exit(0)
elseif opts.r or opts.remove then
  local ok, err = users.remove(attr.uid)
  if not ok then
    io.stderr:write("passwd: cannot remove user: ", err, "\n")
    os.exit(1)
  end
  os.exit(0)
end

local pass
repeat
  io.stderr:write("password: \27[8m")
  pass = io.read()
  io.stderr:write("\27[0m\n")
  if #pass < 5 then
    io.stderr:write("passwd: password too short\n")
  end
until #pass > 4

attr.pass = sha(pass):gsub(".", function(x)
  return string.format("%02x", x:byte()) end)

for a in (opts.enable or ""):gmatch("[^,]+") do
  attr.acls[a:upper()] = true
end

for a in (opts.disable or ""):gmatch("[^,]+") do
  attr.acls[a:upper()] = false
end

local function pc(f, ...)
  local ok, a, b = pcall(f, ...)
  if not ok and a then
    io.stderr:write("passwd: ", a, "\n")
    os.exit(1)
  else
    return a, b
  end
end

local ok, err = pc(users.usermod, attr)

if not ok then
  io.stderr:write("passwd: ", err, "\n")
  os.exit(1)
end
�� 
bin/ls.lua      �-- coreutils: ls --

local text = require("text")
local size = require("size")
local path = require("path")
local users = require("users")
local termio = require("termio")
local filetypes = require("filetypes")
local fs = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([=[
usage: ls [options] [file1 [file2 ...]]
Lists information about file(s).  Defaults to the
current directory.  Sorts entries alphabetically.
  -1            one file per line
  -a            show hidden files
  --color=WHEN  If "no", disable coloration;  if
                "always", force coloration even
                if the standard output is not
                connected to a terminal;
                otherwise, decide automatically.
  -d            Display information about a
                directory as though it were a
                file.
  -h            Use human-readable file sizes.
  --help        Display this help message and
                exit.
  -l            Display full file information
                (permissions, last modification
                date, etc.) instead of just file
                names.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]=])
  os.exit(1)
end

local colors = {
  default = "39;49",
  dir = "49;94",
  exec = "49;92",
  link = "49;96",
  special = "49;93"
}

local dfa = {name = "n/a"}
local function infoify(base, files, hook, hka)
  local infos = {}
  local maxn_user = 0
  local maxn_size = 0
  
  for i=1, #files, 1 do
    local fpath = files[i]
    
    if base ~= files[i] then
      fpath = path.canonical(path.concat(base, files[i]))
    end
    
    local info, err = fs.stat(fpath)
    if not info then
      io.stderr:write("ls: failed getting information for ", fpath, ": ",
        err, "\n")
      return nil
    end
    
    local perms = string.format(
      "%s%s%s%s%s%s%s%s%s%s",
      info.type == filetypes.directory and "d" or
        info.type == filetypes.special and "c" or
        "-",
      info.permissions & 0x1 and "r" or "-",
      info.permissions & 0x2 and "w" or "-",
      info.permissions & 0x4 and "x" or "-",
      info.permissions & 0x8 and "r" or "-",
      info.permissions & 0x10 and "w" or "-",
      info.permissions & 0x20 and "x" or "-",
      info.permissions & 0x40 and "r" or "-",
      info.permissions & 0x80 and "w" or "-",
      info.permissions & 0x100 and "x" or "-")
    
    local user = (users.attributes(info.owner) or dfa).name
    maxn_user = math.max(maxn_user, #user)
    infos[i] = {
      perms = perms,
      user = user,
      size = size.format(math.floor(info.size), not opts.h),
      modified = os.date("%b %d %H:%M", info.lastModified),
    }
  
    maxn_size = math.max(maxn_size, #infos[i].size)
    if hook then files[i] = hook(files[i], hka) end
  end

  for i=1, #files, 1 do
    files[i] = string.format(
      "%s %s %s %s %s",
      infos[i].perms,
      text.padRight(maxn_user, infos[i].user),
      text.padRight(maxn_size, infos[i].size),
      infos[i].modified,
      files[i])
  end
end

local function colorize(f, p)
  if opts.color == "no" or ((not io.output().tty) and opts.color ~= "always") then
    return f
  end
  if type(f) == "table" then
    for i=1, #f, 1 do
      f[i] = colorize(f[i], p)
    end
  else
    local full = f
    if p ~= f then full = path.concat(p, f) end
    
    local info, err = fs.stat(full)
    
    if not info then
      io.stderr:write("ls: failed getting color information for ", f, ": ", err, "\n")
      return nil
    end
    
    local color = colors.default
  
    if info.type == filetypes.directory then
      color = colors.dir
    elseif info.type == filetypes.link then
      color = colors.link
    elseif info.type == filetypes.special then
      color = colors.special
    elseif info.permissions & 4 ~= 0 then
      color = colors.exec
    end
    return string.format("\27[%sm%s\27[39;49m", color, f)
  end
end

local function list(dir)
  local odir = dir
  dir = path.canonical(dir)
  
  local files, err
  local info, serr = fs.stat(dir)
  
  if not info then
    err = serr
  elseif opts.d or not info.isDirectory then
    files = {dir}
  else
    files, err = fs.list(dir)
  end
  
  if not files then
    return nil, string.format("cannot access '%s': %s", odir, err)
  end
  
  local rm = {}
  for i=1, #files, 1 do
    files[i] = files[i]:gsub("[/]+$", "")
    if files[i]:sub(1,1) == "." and not opts.a then
      rm[#rm + 1] = i
    end
  end

  for i=#rm, 1, -1 do
    table.remove(files, rm[i])
  end

  table.sort(files)
  
  if opts.l then
    infoify(dir, files, colorize, dir)
  
    for i=1, #files, 1 do
      print(files[i])
    end
  elseif opts["1"] then
    for i=1, #files, 1 do
      print(colorize(files[i], dir))
    end
  elseif not (io.stdin.tty and io.stdout.tty) then
    for i=1, #files, 1 do
      print(files[i])
    end
  else
    print(text.mkcolumns(files, { hook = function(f)
        return colorize(f, dir)
      end,
      maxWidth = termio.getTermSize() }))
  end

  return true
end

if #args == 0 then
  args[1] = os.getenv("PWD")
end

for i=1, #args, 1 do
  if #args > 1 then
    if i > 1 then
      io.write("\n")
    end
    print(args[i] .. ":")
  end
  
  local ok, err = list(args[i])
  if not ok and err then
    io.stderr:write("ls: ", err, "\n")
  end
end
�� bin/cat.lua      -- cat --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: cat FILE1 FILE2 ...
Concatenate FILE(s) to standard output.  With no
FILE, or where FILE is -, read standard input.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

if #args == 0 then
  args[1] = "-"
end

for i=1, #args, 1 do
  local handle, err

  if args[i] == "-" then
    handle, err = io.input(), "missing stdin"
  else
    handle, err = io.open(require("path").canonical(args[i]), "r")
  end
  
  if not handle then
    io.stderr:write("cat: cannot open '", args[i], "': ", err, "\n")
    os.exit(1)
  else
    for line in handle:lines("L") do
      io.write(line)
    end
    if handle ~= io.input() then handle:close() end
  end
end
�� bin/env.lua      4-- env

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: env [options] PROGRAM ...
Executes PROGRAM with the specified options.

Options:
  --unset=KEY,KEY,... Unset all specified
                      variables in the child
                      process's environment.
  --chdir=DIR         Set the child process's
                      working directory to DIR.
                      DIR is not checked for
                      existence.
  -i                  Execute the child process
                      with an empty environment.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local program = table.concat(args, " ")

local pge = require("process").info().data.env

-- TODO: support short opts with arguments, and maybe more opts too

if opts.unset and type(opts.unset) == "string" then
  for v in opts.unset:gmatch("[^,]+") do
    pge[v] =  ""
  end
end

if opts.i then
  pge = {}
end

if opts.chdir and type(opts.chdir) == "string" then
  pge["PWD"] = opts.chdir
end

os.execute(program)
�� bin/libm.lua      -- preload: preload libraries

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.h or opts.help then
  io.stderr:write([[
usage: libm [-vr] LIB1 LIB2 ...
Loads or unloads libraries.  Internally uses
require().
    -v    be verbose
    -r    unload libraries rather than loading
          them

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
end

local function handle(f, a)
  local ok, err = pcall(f, a)
  if not ok and err then
    io.stderr:write(err, "\n")
    os.exit(1)
  else
    return true
  end
end

for i=1, #args, 1 do
  if opts.v then
    io.write(opts.r and "unload" or "load", " ", args[i], "\n")
  end
  if opts.r then
    handle(function() package.loaded[args[i]] = nil end)
  else
    handle(require, args[i])
  end
end
�� bin/mount.lua      
�-- coreutils: mount --

local component = require("component")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

local function readFile(f)
  local handle, err = io.open(f, "r")
  if not handle then
    io.stderr:write("mount: cannot open ", f, ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()

  return data
end

if opts.help then
  io.stderr:write([[
usage: mount NODE LOCATION [FSTYPE]
   or: mount -u PATH
Mount the filesystem node NODE at LOCATION.  Or,
if -u is specified, unmount the filesystem node
at PATH.

If FSTYPE is either "overlay" or unset, NODE will
be mounted as an overlay at LOCATION.  Otherwise,
if NODE points to a filesystem in /sys/dev, mount
will try to read device information from the file.
If both of these cases fail, NODE will be treated
as a component address.

Options:
  -u  Unmount rather than mount.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if #args == 0 then
  io.write(readFile("/sys/mounts"))
  os.exit(0)
end

if opts.u then
  local ok, err = filesystem.umount(require("path").canonical(args[1]))
  if not ok then
    io.stderr:write("mount: unmounting ", args[1], ": ", err, "\n")
    os.exit(1)
  end
  os.exit(0)
end

local node, path, fstype = args[1], args[2], args[3]

do
  local npath = require("path").canonical(node)
  local data = filesystem.stat(npath)
  if data then
    if npath:match("/sys/") then -- the path points to somewhere the sysfs
      if data.isDirectory then
        node = readFile(npath .. "/address")
      else
        node = readFile(npath)
      end
    elseif not data.isDirectory then
      node = readFile(npath)
    end
  end
end

if not fstype then
  local addr = component.get(node)
  if addr then
    node = addr
    if component.type(addr) == "drive" then
      fstype = "raw"
    elseif component.type(addr) == "filesystem" then
      fstype = "node"
    else
      io.stderr:write("mount: ", node, ": not a filesystem or drive\n")
      os.exit(1)
    end
  end
end

if (not fstype) or fstype == "overlay" then
  local abs = require("path").canonical(node)
  local data, err = filesystem.stat(abs)
  if not data then
    io.stderr:write("mount: ", node, ": ", err, "\n")
    os.exit(1)
  end
  if not data.isDirectory then
    io.stderr:write("mount: ", node, ": not a directory\n")
    os.exit(1)
  end
  node = abs
  fstype = "overlay"
end

if not filesystem.types[fstype:upper()] then
  io.stderr:write("mount: ", fstype, ": bad filesystem node type\n")
  os.exit(1)
end

local ok, err = filesystem.mount(node, filesystem.types[fstype:upper()], path)

if not ok then
  io.stderr:write("mount: mounting ", node, " on ", path, ": ", err, "\n")
  os.exit(1)
end
�� init.lua      �-- cynosure loader --

local fs = component.proxy(computer.getBootAddress())
local gpu = component.proxy(component.list("gpu", true)())
gpu.bind(gpu.getScreen() or (component.list("screen", true)()))
gpu.setResolution(50, 16)
local b, w = 0, 0xFFFFFF
gpu.setForeground(b)
gpu.setBackground(w)
gpu.set(1, 1, "            Cynosure Kernel Loader v1             ")
gpu.setBackground(b)
gpu.setForeground(w)

local function readFile(f, p)
  local handle
  if p then
    handle = fs.open(f, "r")
    if not handle then return "" end
  else
    handle = assert(fs.open(f, "r"))
  end
  local data = ""
  repeat
    local chunk = fs.read(handle, math.huge)
    data = data .. (chunk or "")
  until not chunk
  fs.close(handle)
  return data
end

local function status(x, y, t, c)
  if c then gpu.fill(1, y+1, 50, 1, " ") end
  gpu.set(x, y+1, t)
end

status(1, 1, "Reading configuration")

local cfg = {}
do
  local data = readFile("/boot/cldr.cfg", true)
  for line in data:gmatch("[^\n]+") do
    local word, arg = line:gmatch("([^ ]+) (.+)")
    if word and arg then cfg[word] = tonumber(arg) or arg end
  end

  local flags = cfg.flags or "root=UUID="..computer.getBootAddress()
  cfg.flags = {}
  for word in flags:gmatch("[^ ]+") do
    cfg.flags[#cfg.flags+1] = word
  end
  cfg.path = cfg.path or "/boot/cynosure.lua"
end

status(1, 2, "Loading kernel from " .. cfg.path)
status(1, 3, "Kernel flags: " .. table.concat(cfg.flags, " "))

assert(load(readFile(cfg.path), "="..cfg.path, "t", _G))(table.unpack(cfg.flags))
�� sbin/sudo.lua      �-- coreutils: sudo --

local users = require("users")
local process = require("process")

local args = table.pack(...)

local uid = 0
if args[1] and args[1]:match("^%-%-uid=%d+$") then
  uid = tonumber(args[1]:match("uid=(%d+)")) or 0
  table.remove(args, 1)
end

if #args == 0 then
  io.stderr:write([[
sudo: usage: sudo [--uid=UID] COMMAND
Executes COMMAND as root or the specified UID.
]])
  os.exit(1)
end

local password
repeat
  io.write("password: \27[8m")
  password = io.read()
  io.write("\27[0m\n")
until #password > 0

local ok, err = users.exec_as(uid,
  password, function() os.execute(table.concat(args, " ")) end, args[1], true)

if ok ~= 0 and err ~= "__internal_process_exit" then
  io.stderr:write(err, "\n")
  os.exit(ok)
end
�� sbin/shutdown.lua      k-- shutdown

local computer = require("computer")

local args, opts = require("argutil").parse(...)

-- don't do anything except broadcast shutdown (TODO)
if opts.k then
  io.stderr:write("shutdown: -k not implemented yet, exiting cleanly anyway\n")
  os.exit(0)
end

local function try(f, a)
  local ok, err = f(a)
  if not ok then
    io.stderr:write("shutdown: ", err, "\n")
    os.exit(1)
  end
end

-- reboot
if opts.r or opts.reboot then
  try(computer.shutdown, true)
end

-- halt
if opts.h or opts.halt then
  try(computer.shutdown, "halt")
end

-- just power off
if opts.p or opts.P or opts.poweroff then
  try(computer.shutdown)
end

io.stderr:write([[
usage: shutdown [options]
options:
  --poweroff, -P, -p  power off
  --reboot, -r        reboot
  --halt, -h          halt the system
  -k                  write wall message but do not shut down
]])

os.exit(1)
�� sbin/init.lua      "-- Refinement init system. --
-- Copyright (c) 2021 i develop things under the DSLv1.

local rf = {}
-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "1.05"
  rf._RUNNING_ON = "ULOS 21.06-1.1"
  
  io.write("\n  \27[97mWelcome to \27[93m", rf._RUNNING_ON, "\27[97m!\n\n")
  local version = "2021.06.28"
  rf._VERSION = string.format("%s r%s-%s", rf._NAME, rf._RELEASE, version)
end
--#include "src/version.lua"
-- logger --

do
  rf.prefix = {
    red = " \27[91m*\27[97m ",
    blue = " \27[94m*\27[97m ",
    green = " \27[92m*\27[97m ",
    yellow = " \27[93m*\27[97m "
  }
  function rf.log(...)
    io.write(...)
    io.write("\n")
  end

  rf.log(rf.prefix.blue, "Starting \27[94m", rf._VERSION, "\27[97m")
end
--#include "src/logger.lua"
-- require function

rf.log(rf.prefix.green, "src/require")

do
  local loaded = package.loaded
  local loading = {}
  function _G.require(module)
    if loaded[module] then
      return loaded[module]
    elseif not loading[module] then
      local library, status, step
      
      step, library, status = "not found",
          package.searchpath(module, package.path)
      
      if library then
        step, library, status = "loadfile failed", loadfile(library)
      end
      
      if library then
        loading[module] = true
        step, library, status = "load failed", pcall(library, module)
        loading[module] = false
      end
      
      assert(library, string.format("module '%s' %s:\n%s",
          module, step, status))
      
      loaded[module] = status
      return status
    else
      error("already loading: " .. module .. "\n" .. debug.traceback(), 2)
    end
  end
end
--#include "src/require.lua"
local config = {}
do
  rf.log(rf.prefix.blue, "Loading service configuration")

  -- string -> boolean, number, or string
  local function coerce(val)
    if val == "true" then
      return true
    elseif val == "false" then
      return false
    elseif val == "nil" then
      return nil
    else
      return tonumber(val) or val
    end
  end

  local fs = require("filesystem")
  if fs.stat("/etc/rf.cfg") then
    local section
    for line in io.lines("/etc/rf.cfg") do
      if line:match("%[.+%]") then
        section = line:sub(2, -2)
        config[section] = config[section] or {}
      else
        local k, v = line:match("^(.-) = (.+)$")
        if k and v then
          v = v:gsub("\n", "")
          if v:match("^%[.+%]$") then
            config[section][k] = {}
            for item in v:gmatch("[^%[%]%s,]+") do
              table.insert(config[section][k], coerce(item))
           end
          else
            config[section][k] = coerce(v)
          end
        end
      end
    end
  end
end
--#include "src/config.lua"
-- service management, again

rf.log(rf.prefix.green, "src/services")

do
  local svdir = "/etc/rf/"
  local sv = {}
  local running = {}
  rf.running = running
  local process = require("process")
  
  function sv.up(svc)
    if running[svc] then
      return true
    end

    if not config[svc] then
      return nil, "service not registered"
    end
    
    if config[svc].depends then
      for i, v in ipairs(config[svc].depends) do
        local ok, err = sv.up(v)
    
        if not ok then
          return nil, "failed starting dependency " .. v .. ": " .. err
        end
      end
    end

    local path = config[svc].file or
      string.format("%s.lua", svc)
    
    if path:sub(1,1) ~= "/" then
      path = string.format("%s/%s", svdir, path)
    end
    
    local ok, err = loadfile(path, "bt", _G)
    if not ok then
      return nil, err
    end
    
    local pid = process.spawn {
      name = svc,
      func = ok,
    }
    
    running[svc] = pid
    return true
  end
  
  function sv.down(svc)
    if not running[svc] then
      return true
    end
    
    local ok, err = process.kill(running[svc])
    if not ok then
      return nil, err
    end
    
    running[svc] = nil
    return true
  end
  
  function sv.list()
    return setmetatable({}, {
      __index = running,
      __pairs = running,
      __ipairs = running,
      __metatable = {}
    })
  end

  package.loaded.sv = package.protect(sv)
  
  rf.log(rf.prefix.blue, "Starting services")
  for k, v in pairs(config) do
    if v.autostart then
      if (not v.type) or v.type == "service" then
        rf.log(rf.prefix.yellow, "service START: ", k)
        local ok, err = sv.up(k)
    
        if not ok then
          rf.log(rf.prefix.red, "service FAIL: ", k, ": ", err)
        else
          rf.log(rf.prefix.yellow, "service UP: ", k)
        end
      elseif v.type == "script" then
        rf.log(rf.prefix.yellow, "script START: ", k)
        local file = v.file or k
        
        if file:sub(1, 1) ~= "/" then
          file = string.format("%s/%s", svdir, file)
        end
        
        local ok, err = pcall(dofile, file)
        if not ok and err then
          rf.log(rf.prefix.red, "script FAIL: ", k, ": ", err)
        else
          rf.log(rf.prefix.yellow, "script DONE: ", k)
        end
      end
    end
  end

  rf.log(rf.prefix.blue, "Started services")
end
--#include "src/services.lua"
-- shutdown override mkII

rf.log(rf.prefix.green, "src/shutdown")

do
  local computer = require("computer")
  local process = require("process")

  local shutdown = computer.shutdown

  function computer.shutdown(rbt)
    if process.info().owner ~= 0 then
      return nil, "permission denied"
    end

    rf.log(rf.prefix.red, "INIT: Stopping services")
    
    for svc, proc in pairs(rf.running) do
      rf.log(rf.prefix.yellow, "INIT: Stopping service: ", svc)
      process.kill(proc)
    end

    rf.log(rf.prefix.red, "INIT: Requesting system shutdown")
    shutdown(rbt)
  end
end
--#include "src/shutdown.lua"

while true do
  --local s = table.pack(
  coroutine.yield()
  --) if s[1] == "process_died" then print(table.unpack(s)) end
end
�� etc/upm/cache/.keepme        �� etc/rf/io.lua      2-- make io sensible about paths

local path = require("path")

local function wrap(f)
  return function(p, ...)
    if type(p) == "string" then p = path.canonical(p) end
    return f(p, ...)
  end
end

io.open = wrap(io.open)
io.input = wrap(io.input)
io.output = wrap(io.output)
io.lines = wrap(io.lines)
�� etc/rf/ttys.lua      A-- getty implementation --

local log = require("syslog")
local ld = log.open("start-ttys")

local function try(...)
  local result = table.pack(pcall(...))
  if not result[1] and result[2] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end

local fs = require("filesystem")
local process = require("process")

local d = "/sys/dev"
local files, err = fs.list(d)
if not files then
  log.write(ld, d .. ": " .. err)
  return
end

table.sort(files, function(a, b)
  if a:match("tty(%d+)") and b:match("tty(%d+)") then
    return tonumber((a:match("tty(%d+)"))) < tonumber((b:match("tty(%d+)")))
  end
  return a < b
end)

local login, err = loadfile("/bin/login.lua")
if not login then
  log.write(ld, "Failed loading login:", err)
  return nil, "failed loading login"
else
  for _, f in ipairs(files) do
    if f:match("tty") then
      log.write(ld, "Starting login on " .. f)
      local n = tonumber(f:match("tty(%d+)"))
      if not n then
        log.write(ld, "Bad TTY ID, for", f, "not starting login")
      else
        local handle, err = io.open("/sys/dev/" .. f, "rw")
        handle.tty = true
        handle.buffer_mode = "none"
        if not handle then
          log.write(ld, "Failed opening TTY /sys/dev/" .. f .. ":", err)
        else
          process.spawn {
            name = "login[tty" .. n .. "]",
            func = login,
            stdin = handle,
            stdout = handle,
            stderr = handle,
            input = handle,
            output = handle
          }
        end
      end
    end
  end
end

log.close(ld)
�� etc/motd.txt       �ULOS r1.2.

Core utilities are available in /bin and /sbin.  Services are configured in /etc/rf.cfg.  Manual pages are available for most libraries and utilities.  Please report bugs at https://github.com/ocawesome101/oc-ulos/issues.
�� 
etc/rf.cfg       �[start-ttys]
autostart = true
type = script
file = ttys.lua
depends = []

[io]
autostart = true
type = script
file = io.lua
depends = []
�� usr/bin/man.lua      �-- manpages: man --

local fs = require("filesystem")
local tio = require("termio")

local w, h = tio.getTermSize()

local page_path = "/usr/man/%d/%s"

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write("usage: man [SECTION] PAGE\n")
  os.exit(1)
end

-- section search order
local sections = {1, 3, 2, 5, 4, 6, 7}

local section, page

if #args == 1 then
  page = args[1]
elseif tonumber(args[1]) then
  section = tonumber(args[1])
  page = args[2]
else
  page = args[1]
end

if section then table.insert(sections, 1, section) end

for i, section in ipairs(sections) do
  local try = string.format(page_path, section, page)
  if fs.stat(try) then
    os.remove("/tmp/manfmt")
    os.execute("tfmt --output=/tmp/manfmt --wrap=" .. w .. " " .. try)
    os.execute("less /tmp/manfmt")
    os.exit(0)
  end
end

io.stderr:write(page .. ": page not found in any section\n")
os.exit(1)
�� usr/share/VLE/forth.vle      "# FORTH syntax file
# Only supports the subset of FORTH that is supported by Open Forth

comment \
constpat ^%d+$ ^0x[0-9a-fA-F]$
keychars + * / - . ; : < = >
keywords cr if else then do loop drop dup mod swap i words
builtin power read fread invoke memfree write eval clist split memtotal
�� usr/share/VLE/svm.vle       �# StackVM highlighting because why not

keychars ; : + - / * @ { } [ ] ( ) = , & #
keywords use for in if else dec
builtin printf open read write close hashmap array fn int char float str
�� usr/share/VLE/vle.vle       �# VLE highlighting for... VLE

strings off
comment #
keywords operator strings keychars comment keywords const builtin numpat
keywords constpat
�� usr/share/VLE/lua.vle      S# VLE highlighting V2: Electric Boogaloo
# this is probably the most feature-complete syntax file of the ones i've
# written, mostly because Lua is the language I know best.

comment --
const true false nil
keychars []{}(),:;+-/=~<>&|^%#*
operator + - / // = ~= >> << > < & * | ^ % .. #
keywords const close local while for repeat until do if in else elseif and or not then end
keywords function return goto break
constpat ^[%d%.]+$
constpat ^0x[0-9a-fA-F%.]+$
builtin tonumber dofile xpcall pcall require string setmetatable package warn _G
builtin ipairs arg load assert utf8 debug getmetatable print error next rawlen
builtin coroutine select io math pairs _VERSION rawequal table type rawget
builtin loadfile os tostring collectgarbage rawset
# all builtins from Lua 5.4
builtin string.match string.find string.packsize string.gmatch string.dump
builtin string.format string.len string.sub string.pack string.char string.byte
builtin string.upper string.reverse string.gsub string.unpack string.rep 
builtin string.lower package.config package.loaded package.cpath
builtin package.searchers package.path package.preload package.searchpath
builtin package.loadlib _G.tonumber _G.dofile _G.xpcall _G.pcall _G.require
builtin _G.string _G.setmetatable _G.package _G.warn _G._G _G.ipairs _G.arg
builtin _G.load _G.assert _G.utf8 _G.debug _G.getmetatable _G.print _G.error
builtin _G.next _G.rawlen _G.coroutine _G.select _G.io _G.math _G.pairs
builtin _G._VERSION _G.rawequal _G.table _G.type _G.rawget _G.loadfile _G.os
builtin _G.tostring _G.collectgarbage _G.rawset arg.0 utf8.char utf8.codepoint
builtin utf8.offset utf8.charpattern utf8.codes utf8.len debug.upvaluejoin
builtin debug.getupvalue debug.debug debug.getmetatable debug.getuservalue 
builtin debug.sethook debug.traceback debug.setupvalue debug.setmetatable
builtin debug.getlocal debug.gethook debug.setcstacklimit debug.setlocal
builtin debug.getinfo debug.getregistry debug.upvalueid debug.setuservalue 
builtin coroutine.close coroutine.isyieldable coroutine.status coroutine.create
builtin coroutine.running coroutine.wrap coroutine.resume coroutine.yield 
builtin io.lines io.flush io.output io.type io.read io.stdin io.popen io.close
builtin io.stderr io.tmpfile io.stdout io.write io.open io.input math.ldexp
builtin math.randomseed math.exp math.fmod math.mininteger math.pi math.huge
builtin math.ult math.acos math.random math.cos math.frexp math.sin math.log
builtin math.rad math.asin math.maxinteger math.log10 math.type math.cosh
builtin math.sinh math.pow math.tointeger math.tan math.atan2 math.ceil math.abs
builtin math.tanh math.sqrt math.modf math.max math.atan math.deg math.min 
builtin math.floor table.remove table.sort table.insert table.pack table.unpack
builtin table.move table.concat os.exit os.remove os.date os.rename os.getenv
builtin os.setlocale os.clock os.tmpname os.difftime os.time os.execute
�� usr/share/VLE/md.vle       ~# basic markdown highlighting

strings ` # markdown has no strings, so treat codeblocks as strings.  why not?
keychars -*[]()
�� usr/share/VLE/c.vle      �# basic C highlighting

comment //
keychars ()[]{}*;,
operator = + - != == >= <= &= |= || && * += -= /= *= >> << < > -> /
const true false
constpat ^<.+>$
constpat ^#.+$
constpat ^%d+$
constpat ^-%d+$
constpat ^0x[a-fA-F0-9]+$
keywords if then else while for return do break
builtin int int32 int64 int32_t int64_t uint uint32 uint64 uint32_t uint64_t
builtin int16 int16_t uint16 uint16_t char struct bool float void ssize_t
builtin uint8 uint8_t int8 int8_t size_t const unsigned
�� usr/share/VLE/py.vle      	�# python.  ugh.

const True False None
comment #
constpat ^%d+$
constpat ^-%d+$
constpat ^0x%x+$
constpat ^0b[01]$
constpat ^0o[0-7]$
keychars []()@
operator = + - / * != += -= /= *= | @ & ^ . : / << > < >>
keywords break for not class from or continue global pass def if raise and del
keywords import return as elif in try assert else is while async except lambda
keywords with await finally nonlocal yield exec
builtin NotImplemented Ellipsis abs all any bin bool bytearray callable chr
builtin classmethod compile complex delattr dict dir divmod enumerate eval filter
builtin float format frozenset getattr globals hasattr hash help hex id input int
builtin isinstance issubclass iter len list locals map max memoryview min next
builtin object oct open ord pow print property range repr reversed round set
builtin setattr slice sorted staticmethod str sum super tuple type vars zip
# python 2 only
builtin basestring cmp execfile file long raw_input reduce reload unichr unicode
builtin xrange apply buffer coerce intern
# python 3 only
builtin ascii bytes exec

# errors!
# builtin BaseException Exception
builtin ArithmeticError BufferError
builtin LookupError
# builtin base exceptions removed in Python 3
builtin EnvironmentError StandardError
# builtin exceptions (actually raised)
builtin AssertionError AttributeError
builtin EOFError FloatingPointError GeneratorExit
builtin ImportError IndentationError
builtin IndexError KeyError KeyboardInterrupt
builtin MemoryError NameError NotImplementedError
builtin OSError OverflowError ReferenceError
builtin RuntimeError StopIteration SyntaxError
builtin SystemError SystemExit TabError TypeError
builtin UnboundLocalError UnicodeError
builtin UnicodeDecodeError UnicodeEncodeError
builtin UnicodeTranslateError ValueError
builtin ZeroDivisionError
# builtin OS exceptions in Python 3
builtin BlockingIOError BrokenPipeError
builtin ChildProcessError ConnectionAbortedError
builtin ConnectionError ConnectionRefusedError
builtin ConnectionResetError FileExistsError
builtin FileNotFoundError InterruptedError
builtin IsADirectoryError NotADirectoryError
builtin PermissionError ProcessLookupError
builtin RecursionError StopAsyncIteration
builtin TimeoutError
# builtin exceptions deprecated/removed in Python 3
builtin IOError VMSError WindowsError
# builtin warnings
builtin BytesWarning DeprecationWarning FutureWarning
builtin ImportWarning PendingDeprecationWarning
builtin ResourceWarning
�� usr/share/VLE/vlerc.vle      keywords color co syntax cachelastline macro
builtin co bi bn ct cm is kw kc st op color builtin blank constant comment
builtin insert keyword keychar string black gray lightGray red green yellow blue
builtin magenta cyan white function alias
const on off yes no true false
�� usr/share/VLE/wren.vle      �# wren highlighting

# no multiline comment support because VLE has no state-based highlighting
comment //
keychars []{}()=!&|~-*%.<>^?:+
const true false null
constpat ^%d+$ ^0x[0-9a-zA-Z]+$
constpat ^_.+$ # this is a weird one
keywords as break class construct continue else for foreign if import in is null
keywords return static super this var while
builtin Bool Class Fiber Fn List Map Null Num Object Range Sequence
builtin String System Meta Random
�� usr/share/VLE/cpp.vle      }# basic C highlighting

comment //
keychars ()[]*&^|{}=<>;
const true false
constpat ^#.+$
constpat ^%d+$
constpat ^-%d+$
constpat ^0x[a-fA-F0-9]+$
keywords if then else while for
builtin int int32 int64 int32_t int64_t uint uint32 uint64 uint32_t uint64_t
builtin int16 int16_t uint16 uint16_t char struct bool float void ssize_t
builtin uint8 uint8_t int8 int8_t size_t cuint8_t
�� usr/share/VLE/hc.vle      x# this is an odd language
# i've written highlighting for VLE only because it's stupidly easy to
# get decent results really fast

comment //
constpat ^[%d%.]+$
constpat ^0x[0-9a-fA-F%.]+$
keychars ,=+-/*()
keywords include fn var asm const
builtin nop imm sto ldr psh pop mov add sub div mul lsh rsh xor or not and
builtin jur jun jcr jcn sof cmp dsi eni hdi int prd pwr hlt
�� usr/share/VLE/sh.vle      �# Basic highlighting for shell scripts

comment #
keychars ={}[]()|><&*:;~/
operator || >> > << < && * : ; ~ /
keywords alias bg bind break builtin caller case in esac cd command compgen
keywords complete compopt continue coproc declare dirs disown echo enable eval
keywords exec exit export fc fg for do done function getopts hash help history
keywords if then elif fi jobs kill let local logout mapfile popd printf pushd
keywords pwd read readarray readonly return select set shift shopt source
keywords suspend test time times trap type typeset ulimit umask unalias unset
keywords until wait while
const true false
constpat ^%-(.+)$
constpat ^([%d.]+)$
constpat ^%$[%w_]+$
�� usr/man/5/passwd       X*{NAME}
  passwd - format for /etc/passwd

*{DESCRIPTION}
  This manual page is a stub.
�� usr/man/5/.keepme        �� usr/man/5/fstab       V*{NAME}
  fstab - format for /etc/fstab

*{DESCRIPTION}
  This manual page is a stub.
�� usr/man/4/.keepme        �� usr/man/3/termio      
p*{NAME}
  termio - terminal-specific abstraction

*{DESCRIPTION}
  ${termio} is a library created out of necessity.  It is portable to many systems by the creation of a corresponding terminal-specific handler.

  Note that ${termio} is only intended to simplify a few specific actions.  These actions are getting terminal size and reading keyboard input.  ${termio} does not support terminals except those that follow the VT100 specification.

*{FUNCTIONS}
  blue{setCursor}(*{x}:magenta{number}, *{y}:magenta{number})
    Set the cursor position to (magenta{x},magenta{y}).  Equivalent to blue{io.write}(red{"\27[Y;XH"}).  Included for the sake of completeness and ease-of-use.  If the input and output streams do not point to a TTY, this will do nothing.

  blue{getCursor}(): magenta{number}, magenta{number}
    Get the cursor position.  This is not as easy to do as setting the cursor, requiring some terminal-specific commands.  This, along with blue{readKey}, is the reason for the usage of terminal handlers.

    If the terminal is not recognized, or the input and output streams do not point to a TTY, then (magenta{1}, magenta{1}) will be returned.

  blue{getTermSize}(): magenta{number}, magenta{number}
    Returns the dimensions of the terminal.  If the terminal is not recognized, or the input and output streams do not point to a TTY, then (magenta{1}, magenta{1}) will be returned.

  blue{readKey}(): red{string}, green{table}
    Reads one keypress from the standard input.  The green{table} contains two fields, magenta{ctrl} and magenta{alt}, both booleans, indicate whether the *{Control} or *{Alt} keys were pressed, respectively.  The red{string} return is the key that was pressed.  Unless it is a key such as *{Return}, *{Backspace}, or *{Delete}, it will be the character generated by the key press - so instead of red{"space"}, blue{readKey} would return red{" "}.

*{TERMINAL HANDLERS}
  Terminal handlers should be placed in #{lib/termio/TERM.lua}, and must contain a library with the following functions:
    
    blue{ttyIn}(): magenta{boolean}
      This function should return whether the input stream points to a TTY.

    blue{ttyOut}(): magenta{boolean}
      This function should return whether the output stream points to a TTY.

    blue{setRaw}(*{raw}:magenta{boolean})
      Set the terminal raw mode.  This must do the following:

        - Enable or disable line buffering on at least the terminal input
        - Enable or disable local echo

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/argutil      `*{NAME}
  argutil - argument parsing utilities

*{DESCRIPTION}
  ${argutil} provies a basic OpenOS-style argument parser to all programs.  It is primarily intended to prevent most programs from requiring their own argument parser.

*{FUNCTIONS}
  blue{parse}(magenta{...}): green{table}, green{table}
    Sort the varargs into green{args} and green{opts}, then return them in that order.  This will work for most things.  When blue{parse} encounters a yellow{--}, it will stop looking for options and dump any remaining varargs into the green{args} table.

    green{args} is simply an array of arguments;  green{opts} is a map, such that green{opts}[*{option}] blue{=} *{value}.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/readline      Q*{NAME}
  readline - readline implementation

*{DESCRIPTION}
  The ${readline} function provides a highly optimized and fairly intuitive form of line editing.  It is similar in style to Bash's line editing (though with a few less features) and very straightforward.

  ${readline} supports text history and may be provided a prompt.

*{USAGE}
  blue{readline}(*{opts}:green{table}): red{string}
    Reads a string from the user, and returns it.

    Available green{opts}:
      *{history}:green{table}
        An array of history entries, with the last entry being the most recent.

      *{prompt}:red{string}
        A prompt to be written before reading input.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/serializer      3*{NAME}
  serializer - serialize Lua tables to text

*{DESCRIPTION}
  The ${serializer} function, when given a Lua table as its only argument, will try to serialize that table into a string which can then be written to a file or blue{load}ed again.

  Recursion is handled but cannot be unserialized.  Functions and threads cannot be serialized and so will break unserialization.

*{COPYRIGHT}
  Serializer library copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/size      �*{NAME}
  size - format sizes

*{DESCRIPTION}
  ${size} is a very simple single-function library.  Provided sizes will be formatted as power-of-2 units (1024-byte KB) by default - however, this may be changed by editing the library and changing the declaration "yellow{local} *{UNIT} = magenta{1024}" on line 14.

*{FUNCTIONS}
  blue{format}(*{n}): red{string}
    Returns the formatted size with a unit specifier (K, M, G, T, P, and E are currently supported) concatenated to it.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/.keepme        �� usr/man/3/text      �*{NAME}
  text - utilities for working with text

*{DESCRIPTION}
  The ${text} library contains several useful methods for working with text.

*{FUNCTIONS}
  blue{escape}(*{str}:red{string}): red{string}
    Escape all special pattern characters in the provided red{str}.

  blue{split}(*{text}:red{string}, *{split}:red{string} or green{table}): green{table}
    Split the provided red{text} on the characters provided in *{split}.

  blue{padRight}(*{n}:magenta{number}, *{text}:red{string}, *{c}:red{string}): red{string}
    Pad the provided red{text} to magenta{n} characters, concatenating a string of repeating red{c}, of the corresponding length, to the left side of the string.

  blue{padLeft}(*{n}:magenta{number}, *{text}:red{string}, *{c}:red{string}): red{string}
    Pad the provided red{text} to magenta{n} characters, concatenating a string of repeating red{c}, of the corresponding length, to the right side of the string.

  blue{mkcolumns}(*{items}:green{table}[, *{args}:green{table}]): red{string}
    Sorts the green{items}, then columnizes them.  This is mostly intended for use in shell commands but could potentially have other uses.  Columnization is only implemented on a row-first basis.

    green{args} may contain a *{maxWidth}:magenta{number} field.  This will limit the maximum row width.  If green{args}.blue{hook} exists and is a function, it will be called with each item and the text for that item replaced with the result of the hook.

  blue{wrap}(*{text}:red{string}, *{width}:magenta{number}): red{string}
    Wraps the provided red{text} to magenta{width} characters, ignoring - but preserving! - VT100 escape sequences.  Useful for determining the number of lines a piece of text will take up on screen.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/mtar      �*{NAME}
  mtar - MiniTel ARchive library

*{DESCRIPTION}
  ${mtar}, the MiniTel ARchive, is a simple archive format created by magenta{Izaya}.  It is the same format used for the ULOS installer image.  See *{mtar}(*{5}) for details.

*{FUNCTIONS}
  blue{archive}(*{base}:green{FILE*}): *{stream}:green{table}
    Returns a stream that, when fed a filename and file data, will write the file header to the provided file stream.

  blue{unarchive}(*{base}:green{FILE*}): *{stream}:green{table}
    Returns a stream that, when blue{readfile}() is called on it, will return a file name and the file's data.

  The following methods are available on the green{stream} object:
    blue{readfile}(): red{string}, red{string}
      Returns a file name and file data for that file, read from an archive.

    blue{writefile}(*{name}:red{string}, *{data}:red{string}): magenta{boolean}
      Writes a header for the provided file name and file data to the base file stream, along with the file data.

    blue{close}(): magenta{boolean}
      Closes the base file stream.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/config      M*{NAME}
  config - configuration library

*{DESCRIPTION}
  *{config} is a library for generalized application configuration.  It uses configuration templates, or objects with :blue{load}() and :blue{save}() methods.

*{FUNCTIONS}
  These functions are common across all configuration templates.  All functions return magenta{nil} and an *{error}:red{string} on failure.

  blue{load}(*{file}:red{string}): green{table}
    Returns a format-specific table representation of the configuration file.

  blue{save}(*{file}:red{string}, *{data}:green{table}): magenta{boolean}
    Saves the provided green{data} to the specified red{file}.

*{FORMATS}
  The following formats are supported by the ${config} library.

  *{table}
    Serialized Lua tables.  The returned table will be identical to what is represented by the file.  Uses *{serializer}(*{3}) for saving.

  *{bracket}
    A style of configuration similar to that of the Refinement init system.  See the below example.

      cyan{[header]}
      *{key1}=magenta{value2}
      *{key2}=yellow{"value that is a string"}
      *{key10} = [yellow{"table"}, magenta{of},magenta{values}]

    The returned table will be in the format green{{} *{header} = green{{} *{key1} = yellow{"value2"}, *{key2} = yellow{"value that is a string"}, *{key10} = green{{} yellow{"table"}, yellow{"of"}, yellow{"values"} green{}} green{}} green{}}.

    Header order is not saved when reserializing.

*{COPYRIGHT}
  Config library copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/futil      *{NAME}
  futil - filesystem utilities

*{DESCRIPTION}
  ${futil} provides certain advanced filesystem-related functions.

*{FUNCTIONS}
  blue{tree}(*{dir}:red{string}[, *{modify}:green{table}])
    Returns a tree in the same style as ${find}(*{1}).  If green{modify} is present, results will be placed in green{modify} as well as returned.

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/tokenizer      �*{NAME}
  tokenizer - tokenization library

*{DESCRIPTION}
  This library is old, unsupported, and will not be documented.  It is used in *{sh}(*{1}) and may be removed in the future.

*{FUNCTIONS}
  -- no documentation --

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/3/path      �*{NAME}
  path - file path utilities

*{DESCRIPTION}
  ${path} is a simple library presenting a few functions for file path manipulation.

*{FUNCTIONS}
  blue{split}(*{path}:red{string}): green{table}
    Splits the provided red{path} into segments, compensating for all occurrences of #{..} and #{.} in the path.

  blue{clean}(*{path}:red{string}): red{string}
    Returns a concatenated form of the output of blue{path.split}(red{path}).

  blue{concat}(*{...}:red{string}): red{string}
    Concatenates all the provided paths with #{/}, then returns the cleaned result.

  blue{canonical}(*{path}:red{string}): red{string}
    Returns the absolute, cleaned version of the provided red{path}.  If red{path} does not have a #{/} preceding it, ${path} will concatenate the process working directory ($*{PWD}).

*{COPYRIGHT}
  ULOS Core Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/7/tfmt      )*{NAME}
  tfmt - simple colored text format

*{DESCRIPTION}
  This manual page documents the text formatting facilities used by the ${tfmt}(*{1}) command.  This format is used by all ULOS manual pages.

  All color specifications are wrapped in curly brackets (*{{}*{}}), thus:
    
    *{color specifier}*{{}text*{}}

  The following specifiers are supported:

    red{red}      VT100 color 91
    green{green}    VT100 color 92
    yellow{yellow}   VT100 color 93
    blue{blue}     VT100 color 94
    magenta{magenta}  VT100 color 95
    cyan{cyan}     VT100 color 96
    white{white}    VT100 color 97
    *{*}        Bold (identical to *{white})
    ${$}        Italic (identical to ${cyan})
    @{@}        Link (identical to @{blue})
    #{#}        File (identical to #{yellow})

  After each specifier's pair of brackets ends, the default color (VT100 color 39) will be inserted.

*{COPYRIGHT}
  Text format copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/7/.keepme        �� usr/man/1/shutdown      |*{NAME}
  shutdown - shut down or reboot

*{SYNOPSIS}
  ${shutdown} [*{options}]

*{DESCRIPTION}
  ${shutdown} will shut down or restart the system, or halt it if the operating system supports doing so, according to the options it is given.

  Accepted options are listed here in order of priority.  

    *{-k}
      Send the shutdown wall message but do not act on further options.

    *{-r}, *{--reboot}
      Restart the system.

    *{-h}, *{--halt}
      Halt the system, if halting is supported.  The system may restart if halting is unsupported.

    *{-p}, *{--poweroff}
      Power off the system.

*{BUGS}
  *{-k} currently does nothing but exit, as there is no support for system wall messages.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/less      F*{NAME}
  less - pager

*{SYNOPSIS}
  ${less} *{FILE ...}

*{DESCRIPTION}
  ${less} concatenates all *{FILE}s to its internal buffer, then displays a scrollable listing of the lines on screen.

  The Up and Down arrows will scroll by one line.  The Space-bar will scroll one screenful down.  The Q key will exit ${less}.

*{BUGS}
  Lines longer than the screen width will cause incorrect behavior.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/file      �*{NAME}
  file - print the type of a file

*{SYNOPSIS}
  ${file} *{FILE ...}

*{DESCRIPTION}
  For each *{FILE}, ${file} will print the type of the file (currently 'directory', 'file', and 'special' are supported).

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/lsh      M*{NAME}
  lsh - the Lisp-ish Shell

*{SYNOPSIS}
  ${lsh}

*{DESCRIPTION}
  ${lsh} is the ULOS default shell.  Its syntax mirrors a Lisp much more closely than the Bourne shell.

  At the core of ${lsh} is the idea of substitution - that is, substituting the output of one program as the arguments of another.  This is accomplished like a Lisp, with

    ${a} (${b} *{c d}) *{e f g}

  where the output of ${b} will be split by line and inserted into program ${a}'s argument list.

  This principle is used to simplify ${lsh}'s prompt system - it reads the shell prompt from *{$PS1}, with the default prompt being

    <(get USER)@(or (get HOSTNAME) localhost): (or (match (get PWD) "([^/]+)/?$") /)>

  String literals with spaces are supported between double quotes - otherwise, ${lsh} will split tokens on whitespace.  Expressions inside *{()} are evaluated first, recursively, with the output of each subcommand split by line and passed as an argument to the main command.  Enclosing a subcommand in square brackets (*{[]}) will capture the exit status of the command rather than its output.

  Variable declaration is not done through any dedicated syntax, but rather with the ${get} and ${set} builtins.

    ${get} *{KEY}
    ${set} *{KEY VALUE}

  Comments are preceded by a hash-mark (*{#}) and continue until the end of the line.

  ${lsh} supports shebangs of up to 32 characters in the same style as the Bourne shell.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/wc      �*{NAME}
  wc - print word, character, and line counts

*{SYNOPSIS}
  ${wc} *{FILE ...}
  ${wc} [*{-lwc}] *{FILE ...}

*{DESCRIPTION}
  If no options are specified, ${wc} prints line, word, and character counts in that order for each *{FILE} argument.  Otherwise, ${wc} will print whatever it was told to print, but adhering to the order specified previously.

  Options:
    *{-l}
      Enable printing of line counts.

    *{-w}
      Enable printing of word counts.

    *{-c}
      Enable printing of character counts.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/tfmt      i*{NAME}
  tfmt - format text

*{SYNOPSIS}
  ${tfmt} [*{options}] *{FILE ...}

*{DESCRIPTION}
  ${tfmt} formats text according to a simple format specification.  See *{tfmt}(*{7}) for details.

  Supported options:
    *{--wrap=N}
      Pre-wrap the output text at *{N} characters.  If this is not specified, the output text will not be pre-wrapped.

    *{--output=FILE}
      Send output to *{FILE} rather than the standard output.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/man      �*{NAME}
  man - system manual page browser

*{SYNOPSIS}
  ${man} [*{SECTION}] *{PAGE}

*{DESCRIPTION}
  ${man} is the ULOS manual page browser.  It will search #{/usr/man} for the specified *{PAGE}, place the formatted output in #{/tmp/manfmt}, and open it in the ${less}(*{1}) pager.

  The following table lists available *{SECTION}s, and their categories:

  *{1}  Shell commands and programs
  *{2}  Kernel-provided API
  *{3}  Core user libraries
  *{4}  Special files (found under #{/sys})
  *{5}  File formats and conventions, e.g. #{/etc/passwd}
  *{6}  Games
  *{7}  Miscellaneous (e.g. *{tfmt}(*{7}))

*{COPYRIGHT}
  This ${man} implementation and all manual pages are copyright (c) 2021 Ocawesome101 under the DSLv2.
�� usr/man/1/ls      *{NAME}
  ls - list files

*{SYNOPSIS}
  ${ls} [*{options] *{FILE ...}

*{DESCRIPTION}
  For each *{FILE}, ${ls} lists all files under that *{FILE} if it is a directory, and *{-d} is not specified, or will list information about that file.  Listed files are sorted alphabetically.  If no *{FILE} is specified, ${ls} will list the current directory.

  Supported options are:
    *{-1}
      Print one file per line.

    *{-a}
      Show hidden files (files whose names are preceded with a *{.}).

    *{--color=WHEN}
      If *{WHEN} is "no", ${ls} will not colorize its output;  if ${WHEN} is "always", ${ls} will print colored output even when the output device is not a terminal;  otherwise, ${ls} will print colored output only if the output device is a terminal.

    *{-d}
      List directories in the same way as files, rather than listing their contents.

    *{-h}
      Use human-readable file sizes rather than displaying them as bytes.

    *{-l}
      Display full file information (permissions, owner, size, last modification date) along with the filename, rather than just the filename.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/passwd      �*{NAME}
  passwd - manage users

*{SYNOPSIS}
  ${passwd} [*{options}]
  ${passwd} [*{options}] *{USER}

*{DESCRIPTION}
  ULOS's ${passwd} implementation rolls the more conventional ${usermod}, ${useradd}, ${passwd}, and ${userdel} commands all into one simpler package.

  *{USER} defaults to the current user, and a new user will be created if the specified user does not exist.

  Supported options:
    *{-i}, *{--info}
      Print information about the specified *{USER} and exit.

    *{--disable=ACL,ACL,...}
      For each *{ACL}, disable that permission for the specified *{USER}.

    *{--enable=ACL,ACL}
      For each *{ACL}, disable that permission for the specified *{USER}.

    *{--home=HOME}
      Set the specified *{USER}'s home directory to *{HOME}.

    *{--shell=SHELL}
      Set the specified *{USER}'s shell path to *{SHELL}.  The file extension must be omitted.  The file path must be absolute.

    *{-r}, *{--remove}
      Remove the specified *{USER} and exit.  Only root can perform this action.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/libm      �*{NAME}
  libm - library manager

*{SYNOPSIS}
  ${libm} *{library ...}
  ${libm} -r *{library ...}

*{DESCRIPTION}
  ${libm} is the ULOS Command-Line Library Manager.  It will load all specified libraries unless *{-r} is specified, in which case it will attempt to unload them.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/sv      C*{NAME}
  sv - manage services

*{SYNOPSIS}
  ${sv} [*{up}|*{down}] *{service}
  $[sv} *{list}

*{DESCRIPTION}
  ${sv} is the ULOS service manager.  It hooks directly into Refinement's *{sv}(*{3}) API.

  Commands:
    *{up}
      Start the specified *{service}, if it is not running.

    *{down}
      Stop the specified *{service}, if it is running.

    *{list}
      List running services.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/upm      �*{NAME}
  upm - the ULOS Package Manager

*{SYNOPSIS}
  ${upm} [*{options}] *{COMMAND} [*{...}]

*{DESCRIPTION}
  ${upm} is the ULOS package manager.  It requires a means of communication with a server from which to download packages, but can download them from anywhere as long as the protocol is supported by the kernel *{network}(*{2}) API.

  Available commands:
    *{install PACKAGE} [*{...}]
      Install the specified *{PACKAGE}(s), if found in the local package lists.

    *{remove PACKAGE} [*{...}]
      Remove the specified *{PACKAGE}(s), if installed.

    *{upgrade}
      Upgrade all local packages whose version is less than that offered by the remote repositories.

    *{update}
      Refresh the local package lists from each repository specified in the configuration file (see *{CONFIGURATION} below).

    *{search PACKAGE} [*{...}]
      For each *{PACKAGE}, search the local package lists and print information about that package.

    *{list} [*{TARGET}]
      List packages.

      If *{TARGET} is specified, it must be one of the following:
        *{installed} (default)
          List all installed packages.

        *{all}
          List all packages in the remote repositories.

        <*{repository}>
          List all packages in the specified repository.

      Other values of *{TARGET} will result in an error.

    *{help}
      See *{--help} below.

  Available options:
    *{-q}
      Suppresses all log output except errors.

    *{-v}
      Be verbose;  overrides *{-q}.

    *{-f}
      Skip checks for package installation status and package version differences.  Useful for reinstalling packages.

    *{-y}
      Assume 'yes' for all prompts;  do not present prompts.

    *{--root}=*{PATH}
      Specify *{PATH} to be treaded as the root directory, rather than #{/}.  This is mainly useful for bootstrapping another ULOS system, or for installing packages on another disk.

    *{--help}
      Print the built-in help text.

*{CONFIGURATION}
  ${upm}'s configuration is stored in #{/etc/upm.cfg}.  It should be fairly self-explanatory.

*{COPYRIGHT}
  ULOS Package Manager copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/install      e*{NAME}
  install - install the system to a writable medium

*{SYNOPSIS}
  ${install}

*{DESCRIPTION}
  ${install} is only available in the ULOS live image.

  ${install} will present the user with a list of available filesystems.  Once a filesystem is selected, ${install} will mount it at #{/mnt} and copy system files to it.

  Once installation is complete, the installation media should be removed and the system restarted.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/df      �*{NAME}
  df - list disk information

*{SYNOPSIS}
  ${df} [*{-h}]

*{DESCRIPTION}
  ${df} prints disk usage information about the filesystems installed in your computer.  Information is obtained from the sysfs.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/sh      �*{NAME}
  sh - bourne-ish shell

*{SYNOPSIS}
  ${sh} [*{-e}]

*{DESCRIPTION}
  ${sh} is a Bourne-shell clone.  It is deprecated in favor of *{lsh}(*{1}).

  There is half-implemented scripting and piping support.  ${sh} is unsupported and may be removed in a future release.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/cp      b*{NAME}
  cp - copy files

*{SYNOPSIS}
  ${cp} [*{-rv}] *{SOURCE ... DEST}

*{DESCRIPTION}
  ${cp} copies files.

  If only one *{SOURCE} is specified, then *{DEST} may be a file.  Otherwise, if multiple *{SOURCE}s are specified, *{DEST} must be a directory.

  ${cp} will not usually copy directories unless the *{-r} option is specified.

  If *{-v} is specified, ${cp} will print all 'SOURCE -> DEST' copies that it makes.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/.keepme        �� usr/man/1/rm      �*{NAME}
  rm - remove files

*{SYNOPSIS}
  ${rm} [*{-rfv}] *{FILE ...}

*{DESCRIPTION}
  ${rm} removes all specified *{FILE}s.

  Options:
    *{-r}
      Recurse into directories.  Required on most filesystems to remove directories.

    *{-f}
      Do not exit on failure.

    *{-v}
      Be verbose.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/mkdir      �*{NAME}
  mkdir - make directories

*{SYNOPSIS}
  ${mkdir} [*{options}] *{DIRECTORY ...}

*{DESCRIPTION}
  ${mkdir} creates each *{DIRECTORY} specified on the command line, in order.  If *{-p} is specified, ${mkdir} will automatically create nonexistent parent directories.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/env      n*{NAME}
  env - run a program in a modified environment

*{SYNOPSIS}
  ${env} [*{options}] *{PROGRAM ...}

*{DESCRIPTION}
  Executes programs with the specified options.  Primarily for compatibility.

  Supported options:

  *{--unset=KEY,KEY,...}
    For each *{KEY}, unsets that variable in the program's environment.

  *{--chdir=DIR}
    Sets the program's working directory to *{DIR}.

  *{-i}
    Empties the program's environment.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/clear      R*{NAME}
  clear - clear the screen

*{SYNOPSIS}
  ${clear}

*{DESCRIPTION}
  ${clear} clears the terminal screen.  No further functionality is available.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/sudo      "*{NAME}
  sudo - run a command as another user

*{SYNOPSIS}
  ${sudo} *{PROGRAM ...}
  ${sudo} *{--uid=UID} *{PROGRAM ...}

*{DESCRIPTION}
  $[sudo} will execute the specified *{PROGRAM} as either the root user, or the user whose uid is specified with *{--uid}.  Note that *{--uid} must be specified as the first argument to ${sudo}, or it will not take effect.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/ps      f*{NAME}
  ps - list process information

*{SYNOPSIS}
  ${ps}

*{DESCRIPTION}
 ${ps} formats process information from #{/sys/proc}.  It does not use the *{process}(*{2}) API.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/login      *{NAME}
  login - log into the system

*{SYNOPSIS}
  ${login}

*{DESCRIPTION}
  ${login} will ask the user for a username and a password, then execute the shell belonging to the specified user.  If the user is not found or the credentials are incorrect, ${login} will display an error message accordingly.

  ${login} may only be run as root.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/mount      �*{NAME}
  mount - mount and unmount filesystems

*{SYNOPSIS}
  ${mount}
  ${mount} *{NODE LOCATION} [*{FSTYPE}]
  ${mount} -u *{PATH}

*{DESCRIPTION}
  When executed with no arguments, ${mount} will print filesystem mount information equivalent to `*{cat /sys/mounts}'.  When executed with *{NODE} and *{LOCATION}, ${mount} will either use the *{FSTYPE} argument or attempt to automatically determine the filesystem type.  When executed with the *{-u} option, ${mount} will behave like other systems' ${umount}.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/touch      O*{NAME}
  touch - create a file

*{SYNOPSIS}
  ${touch} *{FILE ...}

*{DESCRIPTION}
  For each *{FILE}, if it does not exist, ${touch} will create it.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/pwd      ?*{NAME}
  pwd - print working directory

*{SYNOPSIS}
  ${pwd}

*{DESCRIPTION}
  ${pwd} prints the process working directory and exits.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/lua      B*{NAME}
  lua - lua REPL

*{SYNOPSIS}
  ${lua} [*{options}] [*{script} [*{args}]]

*{DESCRIPTION}
  ${lua} is a Lua interpreter and executor.

  Supported options:
    *{-e stat}
      Execute string *{stat}.

    *{-i}
      Enter interactive mode after executing *{script}.

    *{-l name}
      Require library *{name} into global *{name}.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.  Lua 5.3 copyright (c) 1994-2020 Lua.org, PUC-Rio.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/cat      Y*{NAME}
  cat - concatenate files to standard output

*{SYNOPSIS}
  ${cat} FILE1 FILE2 *{...}
  ${cat} --help

*{DESCRIPTION}
  ${cat} concatenates files to the standard output.

  For each of its arguments, ${cat} will attempt to open the file that this argument points to;  if it is not found, ${cat} will exit with an error message.  Otherwise, ${cat} will print the unmodified contents of the file to its output.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/free      �*{NAME}
  free - print memory information

*{SYNOPSIS}
  ${free} [*{-h}]

*{DESCRIPTION}
  Prints system memory usage information.  If *{-h} is specified, sizes will be printed human-readably.  Otherwise, they will be printed in bytes.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/1/find      �*{NAME}
  find - print a listing of all files under a subpath

*{SYNOPSIS}
  ${find} *{DIRECTORY ...}

*{DESCRIPTION}
  ${find} prints a tree of all files under each *{DIRECTORY}, with one file per line.  All printed file paths are absolute.

  No command-line options are supported.

*{COPYRIGHT}
  ULOS Core Utilities copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� usr/man/6/.keepme        �� usr/man/2/users      *{NAME}
  users - user management

*{DESCRIPTION}
  This API provides facilities for simple managements of users under Cynosure.

  All functions return magenta{nil} and an error message on failure.

*{FUNCTIONS}
  blue{prime}(*{data}:green{table}): magenta{boolean}
    Used internally.  Undocumented.

  blue{authenticate}(*{uid}:magenta{number}, *{pass}:red{string}): magenta{boolean}
    Checks whether the credentials provided are valid.

  blue{exec_as}(*{uid}:magenta{number}, *{pass}:red{string}, *{func}:blue{function}[, *{pname}:red{string}][, *{wait}:magenta{boolean}])
    Spawns a new process to execute the provided blue{func} as the user specified by magenta{uid}.  If red{pname} is specified the process name will be set to it, and if magenta{wait} is specified then blue{exec_as} will return the result of blue{process}(*{2})blue{.await}ing the new process.
  
  blue{get_uid}(*{uname}:red{string}): magenta{number}
    Returns the user ID associated with the specified username red{uname}.

  blue{attributes}(*{uid}:magenta{number}): green{table}
    Returns the attributes of the specified magenta{uid}:

      green{{}
        *{name} = red{string},
        *{home} = red{string},
        *{shell} = red{string},
        *{acls} = magenta{number}
      green{}}

    Perhaps the least self-explanatory field is magenta{acls}, which contains all the user's permissions OR'd together.

  blue{usermod}(*{attributes}:green{table}): magenta{boolean}
    Changes user attributes.  The provided table of green{attributes} should have a form identical to that returned by the blue{attributes} function, but with the ACL data as a table where [red{acl_name}] = magenta{true}, and with a UID and password field if not modifying the current user.

    The specified user will be created if it does not exist.

    Use of this function can be seen in *{passwd}(*{1}).

  blue{remove}(*{uid}:magenta{number}): magenta{boolean}
    Tries to remove the user whose ID is magenta{uid}.

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/pipe      �*{NAME}
  pipe - pipes!

*{DESCRIPTION}
  ${pipe} is a very simple library for creating unidirectional inter-process I/O streams, or pipes.

*{FUNCTIONS}
  blue{create}(): green{FILE*}
    Returns a pipe stream suitable for use as an input-output stream.

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/process      
�*{NAME}
  process - user-facing process management API

*{DESCRIPTION}
  ${process} is the Cynosure userspace process management API.  Information about running processes is mostly available from #{/sys/proc}.

*{FUNCTIONS}
  blue{spawn}(*{args}:green{table}): magenta{number}
    Spawns a new process.  green{args} may contain any of the following fields (blue{func} and red{name} are required):

      green{{}
        *{func} = blue{function},
        *{name} = red{string},
        *{stdin} = *{FILE*},
        *{stdout} = *{FILE*},
        *{stderr} = *{FILE*},
        *{input} = *{FILE*},
        *{output} = *{FILE*}
      green{}}

    Returns the process ID of the newly created process.

  blue{kill}(*{pid}:magenta{number}, *{signal}:magenta{number}): magenta{boolean}
    If the current user has permission, sends the provided magenta{signal} to the process whose PID is magenta{pid}.

  blue{list}(): green{table}
    Returns a list of all process IDs.

  blue{await}(*{pid}:magenta{number}): magenta{number}, red{string}
    Halts the current process until the specified magenta{pid} no longer exists, then returns its magenta{exit status} and red{exit reason}.

  blue{info}([*{pid}:magenta{number}]): green{table}
    Returns a table of information about the process with the specified magenta{pid}, defaulting to the current process if a magenta{pid} is not specified.

      green{{}
        *{pid} = magenta{number},
        *{name} = red{string},
        *{waiting} = magenta{boolean},
        *{stopped} = magenta{boolean},
        *{deadline} = magenta{number},
        *{n_threads} = magenta{number},
        *{status} = red{string},
        *{cputime} = magenta{number},
        *{owner} = magenta{number}
      green{}}

    If the magenta{pid} points to the current process or is unspecified (and thus has defaulted to the current process), then there will be an additional green{table} field, *{data}:

      green{{}
        *{io} = green{table},
        *{self} = *{process},
        *{handles} = green{table},
        *{coroutine} = green{table},
        *{env} = green{table}
      green{}}

    Of note is green{data.env}, the process's environment.  The other methods should be fairly self-explanatory.

*{SIGNALS}
  green{process.signals} = green{{}
    *{hangup} = magenta{number},
    *{interrupt} = magenta{number},
    *{kill} = magenta{number},
    *{stop} = magenta{number},
    *{kbdstop} = magenta{number},
    *{continue} = magenta{number}
  green{}}

  The magenta{kill}, magenta{stop}, and magenta{continue} signals are not blockable.  All other signals may be overridden.

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/filetypes      �*{NAME}
  filetypes - file types

*{DESCRIPTION}
  ${filetypes} is a table of supported file types:
    
    green{{}
      *{file} = magenta{number},
      *{directory} = magenta{number},
      *{link} = magenta{number},
      *{special} = magenta{number},
    green{}}

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/syslog      �*{NAME}
  syslog - get a handle to the system log

*{DESCRIPTION}
  The ${syslog} API provides a method for userspace programs to write to the system log.  Note that system log messages will usually only appear on the first terminal registered with the system, i.e. the one on which the boot console was presented.

*{FUNCTIONS}
  blue{open}([*{pname}:red{string}]): magenta{number}
    Returns a number which effectively acts as a file descriptor to the system log.

  blue{write}(*{n}:magenta{number}, *{...}): magenta{boolean}
    Writes the specified message to the system log, using the log descriptor magenta{n}.

  blue{close}(*{n}:magenta{number}): magenta{boolean}
    Closes (unregisters) the specified log descriptor magenta{n}.

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/.keepme        �� usr/man/2/sha3      �*{NAME}
  sha3 - sha3 library

*{FUNCTIONS}
  blue{sha256}(*{data}:red{string}): red{string}

  blue{sha512}(*{data}:red{string}): red{string}

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.  SHA-3 implementation copyright (c) 2018 Phil Leblanc, from @{https://github.com/philanc/plc}

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/acls      *{NAME}
  acls - some ACL-related data

*{DESCRIPTION}
  ${acls} is a table containing permission data for users and files.

  green{{}
    *{user} = green{{}
      *{SUDO} = magenta{number},
      *{MOUNT} = magenta{number},
      *{OPEN_UNOWNED} = magenta{number},
      *{COMPONENTS} = magenta{number},
      *{HWINFO} = magenta{number},
      *{SETARCH} = magenta{number},
      *{MANAGE_USERS} = magenta{number},
      *{BUUTADDR} = magenta{number},
    green{}},
    *{file} = green{{}
      *{OWNER_READ} = magenta{number},
      *{OWNER_WRITE} = magenta{number},
      *{OWNER_EXEC} = magenta{number},
      *{GROUP_READ} = magenta{number},
      *{GROUP_WRITE} = magenta{number},
      *{GROUP_EXEC} = magenta{number},
      *{OTHER_READ} = magenta{number},
      *{OTHER_WRITE} = magenta{number},
      *{OTHER_EXEC} = magenta{number},
    green{}}
  green{}}

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� usr/man/2/filesystem      ]*{NAME}
  filesystem - filesystem API

*{DESCRIPTION}
  ${filesystem} is the Cynosure-provided method of accessing any filesystem mounted to the filesystem tree.  It is similar in design to ${lfs}, though it is not exactly the same.  Some filesystem information can be had from the sysfs.

  All functions will return magenta{nil} and an error message on failure.  All file paths must be absolute - see *{path}(*{3}) for some helper functions related to path manipulation in general.

*{FUNCTIONS}
  blue{open}(*{file}:red{string}[, *{mode}:red{string}]): green{table}
    Attempts to open the provided red{file} using red{mode}.  On success, returns a table with blue{read}, blue{write}, blue{seek}, and blue{close} methods.

  blue{stat}(*{file}:red{string}): green{table}
    Returns a table of information about the provided file:

      green{{}
        *{permissions}  = magenta{number},
        *{type}         = magenta{number},
        *{isDirectory}  = magenta{boolean},
        *{owner}        = magenta{number},
        *{group}        = magenta{number},
        *{lastModified} = magenta{number},
        *{size}         = magenta{number}
      green{}}

    magenta{isDirectory} is primarily kept for convenience's sake and some degree of backwards compatibility.

  blue{touch}(*{file}:red{string}[, *{ftype}:magenta{number}]): magenta{boolean}
    Creates the provided red{file}, if it does not exist.  If magenta{ftype} is specified, the file will be of the specified type if supported by the filesystem.

  blue{list}(*{path}:red{string}): green{table}
    Returns a list of all files under the specified red{path}.
  
  blue{remove}(*{file}:red{string}): magenta{boolean}
    Tries to remove the specified red{file} from the filesystem.  Will not be able to remove directories on most filesystems.

  blue{mount}(*{node}:red{string} or green{table}, *{fstype}:magenta{number}, *{path}:red{string}): magenta{boolean}
    Mounts the provided yellow{node} at red{path}.

    If magenta{fstype} is magenta{filesystem.types.RAW}, then blue{mount} will try to automatically determine how it should tread yellow{node}.  If magenta{fstype} is magenta{filesystem.types.NODE}, blue{mount} will treat it as a filesystem node able to be directly mounted - see #{docs/fsapi.txt} for details.  Finally, if magenta{fstype} is magenta{filesystem.types.OVERLAY}, then the directory at yellow{node} will become available at red{path}.

  blue{umount}(*{path}:red{string}): magenta{boolean}
    Attempts to remove the node at *{path} from the filesystem mount tree.

  blue{mounts}(): green{table}
    Returns a list of all currently mounted filesystems, in the following format:
      
      green{{}
        [*{path}:red{string}] = *{fsname}:red{string},
        *{...}
      green{}}

*{TABLES}
  *{filesystem.types} = green{{}
    *{RAW} = magenta{number},
    *{NODE} = magenta{number},
    *{OVERLAY} = magenta{number}
  green{}}
    Contains all supported filesystem types.

*{COPYRIGHT}
  Cynosure kernel copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-cynosure/issues}.
�� lib/termio/cynosure.lua      _-- handler for the Cynosure terminal

local handler = {}

handler.keyBackspace = 8

function handler.setRaw(raw)
  if raw then
    io.write("\27?3;12c\27[8m")
  else
    io.write("\27?13;2c\27[28m")
  end
end

function handler.ttyIn()
  return not not io.input().tty
end

function handler.ttyOut()
  return not not io.output().tty
end

return handler
�� lib/termio/xterm-256color.lua      n-- xterm-256color handler --

local handler = {}

local termio = require("posix.termio")
local isatty = require("posix.unistd").isatty

handler.keyBackspace = 127
handler.keyDelete = 8

local default = termio.tcgetattr(0)
local raw = {}
for k,v in pairs(default) do raw[k] = v end
raw.oflag = 4
raw.iflag = 0
raw.lflag = 35376
default.cc[2] = 8

function handler.setRaw(_raw)
  if _raw then
    termio.tcsetattr(0, termio.TCSANOW, raw)
  else
    termio.tcsetattr(0, termio.TCSANOW, default)
  end
end

function handler.ttyIn() return isatty(0) == 1 end
function handler.ttyOut() return isatty(1) == 1 end

return handler
�� lib/tokenizer.lua      	i-- some sort of parser library

local lib = {}

local function esc(c)
  return c:gsub("[%[%]%(%)%.%+%-%*%%%^%$%?]", "%%%1")
end

function lib:matchToken()
  local tok = ""
  local splitter = "[" .. self.brackets .. self.splitters .. "]"
  if self.i >= #self.text then return nil end
  for i=self.i, #self.text, 1 do
    self.i = i + 1
    local c = self.text:sub(i,i)
    if #self.splitters > 0 and c:match(splitter) and #tok == 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if #self.brackets > 0 and c:match("["..self.brackets.."]") then
          return c, "bracket"
        elseif self.text:sub(i+1,i+1):match(splitter) then
          tok = c
        else
          return c, "splitter"
        end
      end
    elseif #self.splitters > 0 and c:match(splitter) and #tok > 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if tok:match("%"..c) then
          tok = tok .. c
        else
          self.i = self.i - 1
          return tok, (tok:match(splitter) and "splitter") or "word"
        end
      elseif #tok > 0 then
        return tok, (tok:match(splitter) and "splitter") or "word"
      end
    elseif #self.splitters > 0 and tok:match(splitter) and #tok > 0 then
      self.i = self.i - 1
      return tok, "splitter"
    else
      tok = tok .. c
      if self.text:sub(i+1,i+1):match(splitter) then
        for n, v in ipairs(self.words) do
          if tok == v.word then
            return tok, v.type
          end
        end
        for n, v in ipairs(self.matches) do
          if tok:match(v.pattern) then
            return tok, v.type
          end
        end
      end
    end
  end
  return ((#tok > 0 and tok) or nil), #tok > 0 and "word" or nil
end

function lib:addToken(ttype, pow, ptype)
  if ttype == "match" then
    self.matches[#self.matches + 1] = {
      pattern = pow,
      type = ptype or ttype
    }
  elseif ttype == "bracket" then
    self.brackets = self.brackets .. esc(pow)
    self.splitters = self.splitters .. esc(pow)
  elseif ttype == "splitter" then
    self.splitters = self.splitters .. esc(pow)
  else
    self.words[#self.words + 1] = {
      word = pow,
      type = ptype or ttype
    }
  end
end

function lib.new(text)
  return setmetatable({
    words={},
    matches={},
    i=0,
    text=text or"",
    splitters="",
    brackets=""},{__index=lib})
end

return lib
�� lib/text.lua      �-- text utilities

local lib = {}

function lib.escape(str)
  return (str:gsub("[%[%]%(%)%$%%%^%*%-%+%?%.]", "%%%1"))
end

function lib.split(text, split)
  checkArg(1, text, "string")
  checkArg(2, split, "string", "table")
  
  if type(split) == "string" then
    split = {split}
  end

  local words = {}
  local pattern = "[^" .. lib.escape(table.concat(split)) .. "]+"

  for word in text:gmatch(pattern) do
    words[#words + 1] = word
  end

  return words
end

function lib.padRight(n, text, c)
  return ("%s%s"):format((c or " "):rep(n - #text), text)
end

function lib.padLeft(n, text, c)
  return ("%s%s"):format(text, (c or " "):rep(n - #text))
end

-- default behavior is to fill rows first because that's much easier
-- TODO: implement column-first sorting
function lib.mkcolumns(items, args)
  checkArg(1, items, "table")
  checkArg(2, args, "table", "nil")
  
  local lines = {""}
  local text = {}
  args = args or {}
  -- default max width 50
  args.maxWidth = args.maxWidth or 50
  
  table.sort(items)
  
  if args.hook then
    for i=1, #items, 1 do
      text[i] = args.hook(items[i]) or items[i]
    end
  end

  local longest = 0
  for i=1, #items, 1 do
    longest = math.max(longest, #items[i])
  end

  longest = longest + (args.spacing or 1)

  local n = 0
  for i=1, #text, 1 do
    text[i] = string.format("%s%s", text[i], (" "):rep(longest - #items[i]))
    
    if longest * (n + 1) + 1 > args.maxWidth and #lines[#lines] > 0 then
      n = 0
      lines[#lines + 1] = ""
    end
    
    lines[#lines] = string.format("%s%s", lines[#lines], text[i])

    n = n + 1
  end

  return table.concat(lines, "\n")
end

-- wrap text, ignoring VT100 escape codes but preserving them.
function lib.wrap(text, width)
  checkArg(1, text, "string")
  checkArg(2, width, "number")
  local whitespace = "[ \t\n\r]"

  local odat = ""

  local len = 0
  local invt = false
  for c in text:gmatch(".") do
    odat = odat .. c
    if invt then
      if c:match("[a-zA-Z]") then invt = false end
    elseif c == "\27" then
      invt = true
    else
      len = len + 1
      if c == "\n" then
        len = 0
      elseif len >= width then
        odat = odat .. "\n"
        len = 0
      end
    end
  end

  return odat
end

return lib
�� lib/path.lua      T-- work with some paths!

local lib = {}

function lib.split(path)
  checkArg(1, path, "string")

  local segments = {}
  
  for seg in path:gmatch("[^\\/]+") do
    if seg == ".." then
      segments[#segments] = nil
    elseif seg ~= "." then
      segments[#segments + 1] = seg
    end
  end
  
  return segments
end

function lib.clean(path)
  checkArg(1, path, "string")

  return string.format("/%s", table.concat(lib.split(path), "/"))
end

function lib.concat(...)
  local args = table.pack(...)
  if args.n == 0 then return end

  for i=1, args.n, 1 do
    checkArg(i, args[i], "string")
  end

  return lib.clean("/" .. table.concat(args, "/"))
end

function lib.canonical(path)
  checkArg(1, path, "string")

  if path:sub(1,1) ~= "/" then
    path = lib.concat(os.getenv("PWD") or "/", path)
  end

  return lib.clean(path)
end

return lib
�� lib/mtar.lua      '-- mtar library --

local path = require("path")

local stream = {}

local formats = {
  [0] = { name = ">I2", len = ">I2" },
  [1] = { name = ">I2", len = ">I8" },
}

function stream:writefile(name, data)
  checkArg(1, name, "string")
  checkArg(2, data, "string")
  if self.mode ~= "w" then
    return nil, "cannot write to read-only stream"
  end

  return self.base:write(string.pack(">I2I1", 0xFFFF, 1)
    .. string.pack(formats[1].name, #name) .. name
    .. string.pack(formats[1].len, #data) .. data)
end

--[[
function stream:readfile()
  if self.mode ~= "r" then
    return nil, "cannot read from write-only stream"
  end

  local namelen = (self.base:read(2) or "\0\0")
  if #namelen == 0 then return end
  namelen = (">I2"):unpack(namelen)
  local version = 0
  local to_read = 0
  local file_path = ""
  if namelen == 0xFFFF then
    version = self.base:read(1):byte()
    namelen = formats[version].name:unpack(self.base:read(2))
  elseif namelen == 0 then
    return nil
  end

  if not formats[version] then
    return nil, "unsupported format version " .. version
  end

  file_path = self.base:read(namelen)
  if #file_path ~= namelen then
    return nil, "unexpected end-of-file reading filename from archive"
  end
  
  local file_len = self.base:read(string.packsize(formats[version].len))
  file_len = formats[version].len:unpack(file_len)
  local file_data = self.base:read(file_len)
  if #file_data ~= file_len then
    return nil, string.format("unexpected end-of-file reading file from archive (expected data of length %d, but got %d)", file_len, #file_data)
  end
  return file_path, file_data
end
--]]

function stream:close()
  self.base:close()
end

local mtar = {}

--[[
function mtar.unarchive(base)
  checkArg(1, base, "FILE*")
  return setmetatable({
    base = base,
    mode = "r",
  }, {__index = stream})
end
--]]

-- this is Izaya's MTAR parsing code because apparently mine sucks
-- however, this is re-indented in a sane way, with argument checking added
function mtar.unarchive(stream)
  checkArg(1, stream, "FILE*")
  local remain = 0
  local function read(n)
    local rb = stream:read(math.min(n,remain))
    if remain == 0 or not rb then
      return nil
    end
    remain = remain - rb:len()
    return rb
  end
  return function()
    while remain > 0 do
      remain=remain-#(stream:read(math.min(remain,2048)) or " ")
    end
    local version = 0
    local nd = stream:read(2) or "\0\0"
    if #nd < 2 then return end
    local nlen = string.unpack(">I2", nd)
    if nlen == 0 then
      return
    elseif nlen == 65535 then -- versioned header
      version = string.byte(stream:read(1))
      nlen = string.unpack(formats[version].name,
        stream:read(string.packsize(formats[version].name)))
    end
    local name = path.clean(stream:read(nlen))
    remain = string.unpack(formats[version].len,
      stream:read(string.packsize(formats[version].len)))
    return name, read, remain
  end
end

function mtar.archive(base)
  checkArg(1, base, "FILE*")
  return setmetatable({
    base = base,
    mode = "w"
  }, {__index = stream})
end

return mtar
�� lib/futil.lua      ~-- futil: file transfer utilities --

local fs = require("filesystem")
local path = require("path")
local text = require("text")

local lib = {}

-- recursively traverse a directory, generating a tree of all filenames
function lib.tree(dir, modify, rootfs)
  checkArg(1, dir, "string")
  checkArg(2, modify, "table", "nil")
  checkArg(3, rootfs, "string", "nil")

  local abs = path.canonical(dir)
  local mounts = fs.mounts()
  local nrootfs = "/"

  for k, v in pairs(mounts) do
    if #nrootfs < #k then
      if abs:match("^"..text.escape(k)) then
        nrootfs = k
      end
    end
  end

  rootfs = rootfs or nrootfs
  
  -- TODO: make this smarter
  if rootfs ~= nrootfs then
    io.stderr:write("futil: not leaving origin filesystem\n")
    return modify or {}
  end
  
  local files, err = fs.list(abs)
  
  if not files then
    return nil, dir .. ": " .. err
  end

  table.sort(files)

  local ret = modify or {}
  for i=1, #files, 1 do
    local full = string.format("%s/%s", abs, files[i], rootfs)
    local info, err = fs.stat(full)
    
    if not info then
      return nil, full .. ": " .. err
    end

    ret[#ret + 1] = path.clean(string.format("%s/%s", dir, files[i]))
    
    if info.isDirectory then
      local _, err = lib.tree(string.format("%s/%s", dir, files[i]), ret, root)
      if not _ then
        return nil, err
      end
    end
  end

  return ret
end

return lib
�� lib/serializer.lua      �-- serializer --

local function ser(va, seen)
  if type(va) ~= "table" then
    if type(va) == "string" then return string.format("%q", tostring(va))
    else return tostring(va) end end
  if seen[va] then return "{recursed}" end
  seen[va] = true
  local ret = "{"
  for k, v in pairs(va) do
    k = ser(k, seen)
    v = ser(v, seen)
    if k and v then
      ret = ret .. string.format("[%s]=%s,", k, v)
    end
  end
  return ret .. "}"
end

return function(tab)
  return ser(tab, {})
end
�� lib/lfs.lua      7-- LuaFileSystem compatibility layer --

local fs = require("filesystem")
local path = require("path")

local lfs = {}

function lfs.attributes(file, optional)
  checkArg(1, file, "string")
  checkArg(2, optional, "string", "table", "nil")
  file = path.canonical(file)

  local out = {}
  if type(optional) == "table" then out = optional end

  local data, err = fs.stat(file)
  if not data then return nil, err end

  out.dev = 0
  out.ino = 0
  out.mode = (data.isDirectory and "directory") or "file"
  out.uid = data.owner
  out.gid = data.group
  out.rdev = 0
  out.access = data.lastModified
  out.modification = data.lastModified
  out.change = data.lastModified
  out.size = data.size
  out.permissions = "rwxrwxrwx" -- TODO do this properly!!
  out.blksize = 0

  if type(optional) == "string" then
    return out[optional]
  end

  return out
end

function lfs.chdir(dir)
  dir = path.canonical(dir)
  if not fs.stat(dir) then
    return nil, "no such file or directory"
  end
  os.setenv("PWD", dir)
  return true
end

function lfs.lock_dir() end

function lfs.currentdir()
  return os.getenv("PWD")
end

function lfs.dir(dir)
  dir = path.canonical(dir)
  local files, err = fs.list(dir)
  if not files then return nil, err end
  local i = 0
  return function()
    i = i + 1
    return files[i]
  end
end

function lfs.lock() end

function lfs.link() end

function lfs.mkdir(dir)
  dir = path.canonical(dir)
  local ok, err = fs.touch(dir, 2)
  if not ok then return nil, err end
  return true
end

function lfs.rmdir(dir)
  dir = path.canonical(dir)
  local ok, err = fs.remove(dir)
  if not ok then return nil, err end
  return true
end

function lfs.setmode() return "binary" end

lfs.symlinkattributes = lfs.attributes

function lfs.touch(f)
  f = path.canonical(f)
  return fs.touch(f)
end

function lfs.unlock() end

return lfs
�� lib/argutil.lua      ?-- argutil: common argument parsing library

local lib = {}

function lib.parse(...)
  local top = table.pack(...)
  local do_done = true
  
  if type(top[1]) == "boolean" then
    do_done = top[1]
    table.remove(top, 1)
  end

  local args, opts = {}, {}
  local done = false
  
  for i=1, #top, 1 do
    local arg = top[i]
    
    if done or arg:sub(1,1) ~= "-" then
      args[#args+1] = arg
    else
      if arg == "--" and do_done then
        done = true
      elseif arg:sub(1,2) == "--" and #arg > 2 then
        local opt, oarg = arg:match("^%-%-(.-)=(.+)")
  
        opt, oarg = opt or arg:sub(3), oarg or true
        opts[opt] = oarg
      elseif arg:sub(1,2) ~= "--" then
        for c in arg:sub(2):gmatch(".") do
          opts[c] = true
        end
      end
    end
  end

  return args, opts
end

return lib
�� lib/sh/builtins.lua      	�-- shell builtins

local path = require("path")
local users = require("users")
local fs = require("filesystem")

local builtins = {}

------------------ Some builtins -----------------
function builtins:cd(dir)
  if dir == "-" then
    if not self.env.OLDPWD then
      io.stderr:write("sh: cd: OLDPWD not set\n")
      os.exit(1)
    end
    dir = self.env.OLDPWD
    print(dir)
  elseif not dir then
    if not self.env.HOME then
      io.stderr:write("sh: cd: HOME not set\n")
      os.exit(1)
    end
    dir = self.env.HOME
  end
  local cdir = path.canonical(dir)
  local ok, err = fs.stat(cdir)
  if ok then
    self.env.OLDPWD = self.env.PWD
    self.env.PWD = cdir
  else
    io.stderr:write("sh: cd: ", dir, ": ", err, "\n")
    os.exit(1)
  end
end

function builtins:echo(...)
  print(table.concat(table.pack(...), " "))
end

function builtins:builtin(b, ...)
  if not builtins[b] then
    io.stderr:write("sh: builtin: ", b, ": not a shell builtin\n")
    os.exit(1)
  end
  builtins[b](self, ...)
end

function builtins:builtins()
  for k in pairs(builtins) do print(k) end
end

function builtins:exit(n)
  n = tonumber(n) or 0
  self.exit = n
end

--------------- Scripting builtins ---------------
local state = {
  ifs = {},
  fors = {},
  cases = {},
  whiles = {},
}

local function push(t, i)
  t[#t+1] = i
end

local function pop(t)
  local x = t[#t]
  t[#t] = nil
  return x
end

builtins["if"] = function(self, ...)
  local args = table.pack(...)
  local _, status = self.execute(table.concat(args, " ",
    args[1] == "!" and 2 or 1))

  push(state.ifs, {id = #state.ifs + 1, cond = (args[1] == "!" and status ~= 0
    or args[1] ~= "!" and status == 0)})
end

builtins["then"] = function(self, ...)
  local args = table.pack(...)
  if #args > 0 then
    io.stderr:write("sh: syntax error near unexpected token '", args[1], "'\n")
    os.exit(1)
  end

  if not state.ifs[#state.ifs + 1].cond then
    self.skip_until = "else"
  end
end

builtins["else"] = function(self, ...)
  local args = table.pack(...)
  if #args > 0 then
    io.stderr:write("sh: syntax error near unexpected token '", args[1], "'\n")
    os.exit(1)
  end
end

builtins["fi"] = function(self, ...)
  if #state.ifs == 0 then
    io.stderr:write("sh: syntax error near unexpected token 'fi'\n")
    os.exit(1)
  end

  pop(state.ifs)
end

builtins["true"] = function()
  os.exit(0)
end

builtins["false"] = function()
  os.exit(1)
end

return builtins
�� lib/termio.lua      o-- terminal I/O library --

local lib = {}

local function getHandler()
  local term = os.getenv("TERM") or "generic"
  return require("termio."..term)
end

-------------- Cursor manipulation ---------------
function lib.setCursor(x, y)
  if not getHandler().ttyOut() then
    return
  end
  io.write(string.format("\27[%d;%dH", y, x))
end

function lib.getCursor(x, y)
  if not (getHandler().ttyIn() and getHandler().ttyOut()) then
    return 1, 1
  end

  io.write("\27[6n")
  
  getHandler().setRaw(true)
  local resp = ""
  
  repeat
    local c = io.read(1)
    resp = resp .. c
  until c == "R"

  getHandler().setRaw(false)
  local y, x = resp:match("\27%[(%d+);(%d+)R")

  return tonumber(x), tonumber(y)
end

function lib.getTermSize()
  local cx, cy = lib.getCursor()
  lib.setCursor(9999, 9999)
  
  local w, h = lib.getCursor()
  lib.setCursor(cx, cy)

  return w, h
end

----------------- Keyboard input -----------------
local patterns = {}

local substitutions = {
  A = "up",
  B = "down",
  C = "right",
  D = "left",
  ["5"] = "pageUp",
  ["6"] = "pageDown"
}

local function getChar(char)
  return string.char(96 + char:byte())
end

function lib.readKey()
  getHandler().setRaw(true)
  local data = io.stdin:read(1)
  local key, flags

  if data == "\27" then
    local intermediate = io.stdin:read(1)
    if intermediate == "[" then
      data = ""

      repeat
        local c = io.stdin:read(1)
        data = data .. c
        if c:match("[a-zA-Z]") then
          key = c
        end
      until c:match("[a-zA-Z]")

      flags = {}

      for pat, keys in pairs(patterns) do
        if data:match(pat) then
          flags = keys
        end
      end

      key = substitutions[key] or "unknown"
    else
      key = io.stdin:read(1)
      flags = {alt = true}
    end
  elseif data:byte() > 31 and data:byte() < 127 then
    key = data
  elseif data:byte() == (getHandler().keyBackspace or 127) then
    key = "backspace"
  elseif data:byte() == (getHandler().keyDelete or 8) then
    key = "delete"
  else
    key = getChar(data)
    flags = {ctrl = true}
  end

  getHandler().setRaw(false)

  return key, flags
end

return lib
�� lib/config.lua      
�-- config --

local serializer = require("serializer")

local lib = {}

local function read_file(f)
  local handle, err = io.open(f, "r")
  if not handle then return nil, err end
  return handle:read("a"), handle:close()
end

local function write_file(f, d)
  local handle, err = io.open(f, "w")
  if not handle then return nil, err end
  return true, handle:write(d), handle:close()
end

local function new(self)
  return setmetatable({}, {__index = self})
end

---- table: serialized lua tables ----
lib.table = {new = new}

function lib.table:load(file)
  checkArg(1, file, "string")
  local data, err = read_file(file)
  if not data then return nil, err end
  local ok, err = load("return " .. data, "=(config@"..file..")", "t", _G)
  if not ok then return nil, err end
  return ok()
end

function lib.table:save(file, data)
  checkArg(1, file, "string")
  checkArg(2, data, "table")
  return write_file(file, serializer(data))
end

---- bracket: see example ----
-- [header]
-- key1=value2
-- key2 = [ value1, value3,"value_fortyTwo"]
-- key15=[val5,v7 ]
lib.bracket = {new=new}

local patterns = {
  bktheader = "^%[([%w_-]+)%]$",
  bktkeyval = "^([%w_-]+)=(.+)",
}

local function pval(v)
  if v:sub(1,1):match("[\"']") and v:sub(1,1) == v:sub(-1) then
    v = v:sub(2,-2)
  else
    v = tonumber(v) or v
  end
  return v
end

function lib.bracket:load(file)
  checkArg(1, file, "string")
  local handle, err = io.open(file, "r")
  if not handle then return nil, err end
  local cfg = {}
  local header
  for line in handle:lines("l") do
    if line:match(patterns.bktheader) then
      header = line:match(patterns.bktheader)
      cfg[header] = {}
    elseif line:match(patterns.bktkeyval) and header then
      local key, val = line:match(patterns.bktkeyval)
      if val:sub(1,1)=="[" and val:sub(-1)=="]" then
        local _v = val:sub(2,-2)
        val = {}
        for _val in _v:gmatch("[^,]+") do
          val[#val+1] = pval(_val)
        end
      else
        val = pval(val)
      end
      cfg[header][key] = val
    end
  end
  handle:close()
  return cfg
end

function lib.bracket:save(file, cfg)
  checkArg(1, file, "string")
  checkArg(2, cfg, "table")
  local data = ""
  for k, v in pairs(cfg) do
    data = data .. string.format("%s[%s]", #data > 0 and "\n\n" or "", k)
    for _k, _v in pairs(v) do
      data = data .. "\n" .. _k .. "="
      if type(_v) == "table" then
        data = data .. "["
        for kk, vv in ipairs(_v) do
          data = data .. serializer(vv) .. (kk < #_v and "," or "")
        end
        data = data .. "]"
      elseif _v then
        data = data .. serializer(_v)
      end
    end
  end

  data = data .. "\n"

  return write_file(file, data)
end

return lib
�� lib/readline.lua      v-- at long last, a proper readline library --

local termio = require("termio")

local function readline(opts)
  checkArg(1, opts, "table", "nil")
  
  opts = opts or {}
  if opts.prompt then io.write(opts.prompt) end

  local history = opts.history or {}
  history[#history+1] = ""
  local hidx = #history
  
  local buffer = ""
  local cpos = 0

  local w, h = termio.getTermSize()
  
  while true do
    local key, flags = termio.readKey()
    flags = flags or {}
    if not (flags.ctrl or flags.alt) then
      if key == "up" then
        if hidx > 1 then
          if hidx == #history then
            history[#history] = buffer
          end
          hidx = hidx - 1
          local olen = #buffer - cpos
          cpos = 0
          buffer = history[hidx]
          if olen > 0 then io.write(string.format("\27[%dD", olen)) end
          local cx, cy = termio.getCursor()
          if cy < h then
            io.write(string.format("\27[K\27[B\27[J\27[A%s", buffer))
          else
            io.write(string.format("\27[K%s", buffer))
          end
        end
      elseif key == "down" then
        if hidx < #history then
          hidx = hidx + 1
          local olen = #buffer - cpos
          cpos = 0
          buffer = history[hidx]
          if olen > 0 then io.write(string.format("\27[%dD", olen)) end
          local cx, cy = termio.getCursor()
          if cy < h then
            io.write(string.format("\27[K\27[B\27[J\27[A%s", buffer))
          else
            io.write(string.format("\27[K%s", buffer))
          end
        end
      elseif key == "left" then
        if cpos < #buffer then
          cpos = cpos + 1
          io.write("\27[D")
        end
      elseif key == "right" then
        if cpos > 0 then
          cpos = cpos - 1
          io.write("\27[C")
        end
      elseif key == "backspace" then
        if cpos == 0 and #buffer > 0 then
          buffer = buffer:sub(1, -2)
          io.write("\27[D \27[D")
        elseif cpos < #buffer then
          buffer = buffer:sub(0, #buffer - cpos - 1) .. buffer:sub(#buffer - cpos + 1)
          local tw = buffer:sub((#buffer - cpos) + 1)
          io.write(string.format("\27[D%s \27[%dD", tw, cpos + 1))
        end
      elseif #key == 1 then
        local wr = true
        if cpos == 0 then
          buffer = buffer .. key
          io.write(key)
          wr = false
        elseif cpos == #buffer then
          buffer = key .. buffer
        else
          buffer = buffer:sub(1, #buffer - cpos) .. key .. buffer:sub(#buffer - cpos + 1)
        end
        if wr then
          local tw = buffer:sub(#buffer - cpos)
          io.write(string.format("%s\27[%dD", tw, #tw - 1))
        end
      end
    elseif flags.ctrl then
      if key == "m" then
        if cpos > 0 then io.write(string.format("\27[%dC", cpos)) end
        io.write("\n")
        break
      elseif key == "a" and cpos < #buffer then
        io.write(string.format("\27[%dD", #buffer - cpos))
        cpos = #buffer
      elseif key == "e" and cpos > 0 then
        io.write(string.format("\27[%dC", cpos))
        cpos = 0
      end
    end
  end

  history[#history] = nil
  return buffer
end

return readline
�� lib/size.lua      �-- size calculations

local lib = {}

-- if you need more sizes than this, @ me
local sizes = {"K", "M", "G", "T", "P", "E"}
setmetatable(sizes, {
  __index = function(_, k)
    if k > 0 then return "?" end
  end
})

-- override this if you must, but 2^10 is precious.
local UNIT = 1024

function lib.format(n, _)
  if _ then return tostring(n) end
  local i = 0
  
  while n >= UNIT do
    n = n / UNIT
    i = i + 1
  end
  
  return string.format("%.1f%s", n, sizes[i] or "")
end

return lib
�� boot/cynosure.lua     �_-- Cynosure kernel.  Should (TM) be mostly drop-in compatible with Paragon. --
-- Might even be better.  Famous last words!
-- Copyright (c) 2021 i develop things under the DSLv1.

_G.k = { cmdline = table.pack(...) }
do
  local start = computer.uptime()
  function k.uptime()
    return computer.uptime() - start
  end
end
-- kernel arguments

do
  local arg_pattern = "^(.-)=(.+)$"
  local orig_args = k.cmdline
  k.cmdline = {}

  for i=1, #orig_args, 1 do
    local karg = orig_args[i]
    
    if karg:match(arg_pattern) then
      local ka, v = karg:match(arg_pattern)
    
      if ka and v then
        k.cmdline[ka] = tonumber(v) or v
      end
    else
      k.cmdline[karg] = true
    end
  end
end
--#include "base/args.lua"
-- kernel version info --

do
  k._NAME = "Cynosure"
  k._RELEASE = "1.03"
  k._VERSION = "2021.06.28"
  _G._OSVERSION = string.format("%s r%s-%s", k._NAME, k._RELEASE, k._VERSION)
end
--#include "base/version.lua"
-- object-based tty streams --

do
  local colors = {
    0x000000,
    0xaa0000,
    0x00aa00,
    0xaa5500,
    0x0000aa,
    0xaa00aa,
    0x00aaaa,
    0xaaaaaa,
    0x555555,
    0xff5555,
    0x55ff55,
    0xffff55,
    0x5555ff,
    0xff55ff,
    0x55ffff,
    0xffffff
  }

  -- pop characters from the end of a string
  local function pop(str, n)
    local ret = str:sub(1, n)
    local also = str:sub(#ret + 1, -1)
 
    return also, ret
  end

  local function wrap_cursor(self)
    while self.cx > self.w do
    --if self.cx > self.w then
      self.cx, self.cy = math.max(1, self.cx - self.w), self.cy + 1
    end
    
    while self.cx < 1 do
      self.cx, self.cy = self.w + self.cx, self.cy - 1
    end
    
    while self.cy < 1 do
      self.cy = self.cy + 1
      self.gpu.copy(1, 1, self.w, self.h, 0, 1)
      self.gpu.fill(1, 1, self.w, 1, " ")
    end
    
    while self.cy > self.h do
      self.cy = self.cy - 1
      self.gpu.copy(1, 1, self.w, self.h, 0, -1)
      self.gpu.fill(1, self.h, self.w, 1, " ")
    end
  end

  local function writeline(self, rline)
    local wrapped = false
    while #rline > 0 do
      local to_write
      rline, to_write = pop(rline, self.w - self.cx + 1)
      
      self.gpu.set(self.cx, self.cy, to_write)
      
      self.cx = self.cx + #to_write
      wrapped = self.cx > self.w
      
      wrap_cursor(self)
    end
    return wrapped
  end

  local function write(self, lines)
    while #lines > 0 do
      local next_nl = lines:find("\n")

      if next_nl then
        local ln
        lines, ln = pop(lines, next_nl - 1)
        lines = lines:sub(2) -- take off the newline
        
        local w = writeline(self, ln)

        if not w then
          self.cx, self.cy = 1, self.cy + 1
        end

        wrap_cursor(self)
      else
        writeline(self, lines)
        break
      end
    end
  end

  local commands, control = {}, {}
  local separators = {
    standard = "[",
    control = "?"
  }

  -- move cursor up N[=1] lines
  function commands:A(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy - n
  end

  -- move cursor down N[=1] lines
  function commands:B(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy + n
  end

  -- move cursor right N[=1] lines
  function commands:C(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx + n
  end

  -- move cursor left N[=1] lines
  function commands:D(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx - n
  end

  function commands:G()
    self.cx = 1
  end

  function commands:H(args)
    local y, x = 1, 1
    y = args[1] or y
    x = args[2] or x
  
    self.cx = math.max(1, math.min(self.w, x))
    self.cy = math.max(1, math.min(self.h, y))
    
    wrap_cursor(self)
  end

  -- clear a portion of the screen
  function commands:J(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(1, self.cy, self.w, self.h, " ")
    elseif n == 1 then
      self.gpu.fill(1, 1, self.w, self.cy, " ")
    elseif n == 2 then
      self.gpu.fill(1, 1, self.w, self.h, " ")
    end
  end
  
  -- clear a portion of the current line
  function commands:K(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(self.cx, self.cy, self.w, 1, " ")
    elseif n == 1 then
      self.gpu.fill(1, self.cy, self.cx, 1, " ")
    elseif n == 2 then
      self.gpu.fill(1, self.cy, self.w, 1, " ")
    end
  end

  -- adjust some terminal attributes - foreground/background color and local
  -- echo.  for more control {ESC}?c may be desirable.
  function commands:m(args)
    args[1] = args[1] or 0
    for i=1, #args, 1 do
      local n = args[i]
      if n == 0 then
        self.fg = colors[8]
        self.bg = colors[1]
        self.attributes.echo = true
      elseif n == 8 then
        self.attributes.echo = false
      elseif n == 28 then
        self.attributes.echo = true
      elseif n > 29 and n < 38 then
        self.fg = colors[n - 29]
        self.gpu.setForeground(self.fg)
      elseif n == 39 then
        self.fg = colors[8]
        self.gpu.setForeground(self.fg)
      elseif n > 39 and n < 48 then
        self.bg = colors[n - 39]
        self.gpu.setBackground(self.bg)
      elseif n == 49 then
        self.bg = colors[1]
        self.gpu.setBackground(self.bg)
      elseif n > 89 and n < 98 then
        self.fg = colors[n - 81]
        self.gpu.setForeground(self.fg)
      elseif n > 99 and n < 108 then
        self.bg = colors[n - 91]
        self.gpu.setBackground(self.bg)
      end
    end
  end

  function commands:n(args)
    local n = args[1] or 0

    if n == 6 then
      self.rb = string.format("%s\27[%d;%dR", self.rb, self.cy, self.cx)
    end
  end

  function commands:S(args)
    local n = args[1] or 1
    self.gpu.copy(1, 1, self.w, self.h, 0, -n)
    self.gpu.fill(1, self.h, self.w, n, " ")
  end

  function commands:T(args)
    local n = args[1] or 1
    self.gpu.copy(1, 1, self.w, self.h, 0, n)
    self.gpu.fill(1, 1, self.w, n, " ")
  end

  -- adjust more terminal attributes
  -- codes:
  --   - 0: reset
  --   - 1: enable echo
  --   - 2: enable line mode
  --   - 3: enable raw mode
  --   - 11: disable echo
  --   - 12: disable line mode
  --   - 13: disable raw mode
  function control:c(args)
    args[1] = args[1] or 0
    
    for i=1, #args, 1 do
      local n = args[i]

      if n == 0 then -- (re)set configuration to sane defaults
        -- echo text that the user has entered?
        self.attributes.echo = true
        
        -- buffer input by line?
        self.attributes.line = true
        
        -- whether to send raw key input data according to the VT100 spec,
        -- rather than e.g. changing \r -> \n and capturing backspace
        self.attributes.raw = false

        -- whether to show the terminal cursor
        self.attributes.cursor = true
      elseif n == 1 then
        self.attributes.echo = true
      elseif n == 2 then
        self.attributes.line = true
      elseif n == 3 then
        self.attributes.raw = true
      elseif n == 4 then
        self.attributes.cursor = true
      elseif n == 11 then
        self.attributes.echo = false
      elseif n == 12 then
        self.attributes.line = false
      elseif n == 13 then
        self.attributes.raw = false
      elseif n == 14 then
        self.attributes.cursor = false
      end
    end
  end

  -- adjust signal behavior
  -- 0: reset
  -- 1: disable INT on ^C
  -- 2: disable keyboard STOP on ^Z
  -- 3: disable HUP on ^D
  -- 11: enable INT
  -- 12: enable STOP
  -- 13: enable HUP
  function control:s(args)
    args[1] = args[1] or 0
    for i=1, #args, 1 do
      local n = args[i]
      if n == 0 then
        self.disabled = {}
      elseif n == 1 then
        self.disabled.C = true
      elseif n == 2 then
        self.disabled.Z = true
      elseif n == 3 then
        self.disabled.D = true
      elseif n == 11 then
        self.disabled.C = false
      elseif n == 12 then
        self.disabled.Z = false
      elseif n == 13 then
        self.disabled.D = false
      end
    end
  end

  local _stream = {}

  local function temp(...)
    return ...
  end

  function _stream:write(...)
    checkArg(1, ..., "string")

    local str = (k.util and k.util.concat or temp)(...)

    if self.attributes.line and not k.cmdline.nottylinebuffer then
      self.wb = self.wb .. str
      if self.wb:find("\n") then
        local ln = self.wb:match("(.-\n)")
        self.wb = self.wb:sub(#ln + 1)
        return self:write_str(ln)
      end
    else
      return self:write_str(str)
    end
  end

  -- This is where most of the heavy lifting happens.  I've attempted to make
  -- this function fairly optimized, but there's only so much one can do given
  -- OpenComputers's call budget limits and wrapped string library.
  function _stream:write_str(str)
    local gpu = self.gpu
    local time = computer.uptime()
    
    -- TODO: cursor logic is a bit brute-force currently, there are certain
    -- TODO: scenarios where cursor manipulation is unnecessary
    if self.attributes.cursor then
      local c, f, b = gpu.get(self.cx, self.cy)
      gpu.setForeground(b)
      gpu.setBackground(f)
      gpu.set(self.cx, self.cy, c)
      gpu.setForeground(self.fg)
      gpu.setBackground(self.bg)
    end
    
    -- lazily convert tabs
    str = str:gsub("\t", "  ")
    
    while #str > 0 do
      if computer.uptime() - time >= 4.8 then -- almost TLWY
        time = computer.uptime()
        computer.pullSignal(0) -- yield so we don't die
      end

      if self.in_esc then
        local esc_end = str:find("[a-zA-Z]")

        if not esc_end then
          self.esc = string.format("%s%s", self.esc, str)
        else
          self.in_esc = false

          local finish
          str, finish = pop(str, esc_end)

          local esc = string.format("%s%s", self.esc, finish)
          self.esc = ""

          local separator, raw_args, code = esc:match(
            "\27([%[%?])([%d;]*)([a-zA-Z])")
          raw_args = raw_args or "0"
          
          local args = {}
          for arg in raw_args:gmatch("([^;]+)") do
            args[#args + 1] = tonumber(arg) or 0
          end
          
          if separator == separators.standard and commands[code] then
            commands[code](self, args)
          elseif separator == separators.control and control[code] then
            control[code](self, args)
          end
          
          wrap_cursor(self)
        end
      else
        -- handle BEL and \r
        if str:find("\a") then
          computer.beep()
        end
        str = str:gsub("\a", "")
        str = str:gsub("\r", "\27[G")

        local next_esc = str:find("\27")
        
        if next_esc then
          self.in_esc = true
          self.esc = ""
        
          local ln
          str, ln = pop(str, next_esc - 1)
          
          write(self, ln)
        else
          write(self, str)
          str = ""
        end
      end
    end

    if self.attributes.cursor then
      c, f, b = gpu.get(self.cx, self.cy)
    
      gpu.setForeground(b)
      gpu.setBackground(f)
      gpu.set(self.cx, self.cy, c)
      gpu.setForeground(self.fg)
      gpu.setBackground(self.bg)
    end
    
    return true
  end

  function _stream:flush()
    if #self.wb > 0 then
      self:write_str(self.wb)
      self.wb = ""
    end
    return true
  end

  -- aliases of key scan codes to key inputs
  local aliases = {
    [200] = "\27[A", -- up
    [208] = "\27[B", -- down
    [205] = "\27[C", -- right
    [203] = "\27[D", -- left
  }

  local sigacts = {
    D = 1, -- hangup, TODO: check this is correct
    C = 2, -- interrupt
    Z = 18, -- keyboard stop
  }

  function _stream:key_down(...)
    local signal = table.pack(...)

    if not self.keyboards[signal[2]] then
      return
    end

    if signal[3] == 0 and signal[4] == 0 then
      return
    end
    
    local char = aliases[signal[4]] or
              (signal[3] > 255 and unicode.char or string.char)(signal[3])
    local ch = signal[3]
    local tw = char

    if ch == 0 and not aliases[signal[4]] then
      return
    end
    
    if #char == 1 and ch == 0 then
      char = ""
      tw = ""
    elseif char:match("\27%[[ABCD]") then
      tw = string.format("^[%s", char:sub(-1))
    elseif #char == 1 and ch < 32 then
      local tch = string.char(
          (ch == 0 and 32) or
          (ch < 27 and ch + 96) or
          (ch == 27 and 91) or -- [
          (ch == 28 and 92) or -- \
          (ch == 29 and 93) or -- ]
          (ch == 30 and 126) or
          (ch == 31 and 63) or ch
        ):upper()
    
      if sigacts[tch] and not self.disabled[tch] and k.scheduler.processes then
        -- fairly stupid method of determining the foreground process:
        -- find the highest PID associated with this TTY
        -- yeah, it's stupid, but it should work in most cases.
        -- and where it doesn't the shell should handle it.
        local mxp = 0

        for k, v in pairs(k.scheduler.processes) do
          if v.io.stdout.base and v.io.stdout.base.ttyn == self.ttyn then
            mxp = math.max(mxp, k)
          elseif v.io.stdin.base and v.io.stdin.base.ttyn == self.ttyn then
            mxp = math.max(mxp, k)
          elseif v.io.stderr.base and v.io.stderr.base.ttyn == self.ttyn then
            mxp = math.max(mxp, k)
          end
        end

        --k.log(k.loglevels.info, "sending", sigacts[tch], "to", k.scheduler.processes[mxp].name)

        k.scheduler.processes[mxp]:signal(sigacts[tch])

        self.rb = ""
        if tch == "\4" then self.rb = tch end
        char = ""
      end

      tw = "^" .. tch
    end
    
    if not self.attributes.raw then
      if ch == 13 then
        char = "\n"
        tw = "\n"
      elseif ch == 8 then
        if #self.rb > 0 then
          tw = "\27[D \27[D"
          self.rb = self.rb:sub(1, -2)
        else
          tw = ""
        end
        char = ""
      end
    end
    
    if self.attributes.echo then
      self:write_str(tw or "")
    end
    
    self.rb = string.format("%s%s", self.rb, char)
  end

  function _stream:clipboard(...)
    local signal = table.pack(...)

    for c in signal[3]:gmatch(".") do
      self:key_down(signal[1], signal[2], c:byte(), 0)
    end
  end
  
  function _stream:read(n)
    checkArg(1, n, "number")

    self:flush()

    if self.attributes.line then
      while (not self.rb:find("\n")) or (self.rb:find("\n") < n)
          and not self.rb:find("\4") do
        coroutine.yield()
      end
    else
      while #self.rb < n and (self.attributes.raw or not self.rb:find("\4")) do
        coroutine.yield()
      end
    end

    if self.rb:find("\4") then
      self.rb = ""
      return nil
    end

    local data = self.rb:sub(1, n)
    self.rb = self.rb:sub(n + 1)
    -- component.invoke(component.list("ocemu")(), "log", '"'..data..'"', #data)
    return data
  end

  local function closed()
    return nil, "stream closed"
  end

  function _stream:close()
    self.closed = true
    self.read = closed
    self.write = closed
    self.flush = closed
    self.close = closed
    k.event.unregister(self.key_handler_id)
    k.event.unregister(self.clip_handler_id)
    if self.ttyn then k.sysfs.unregister("/dev/tty"..self.ttyn) end
    return true
  end

  local ttyn = 0

  -- this is the raw function for creating TTYs over components
  -- userspace gets somewhat-abstracted-away stuff
  function k.create_tty(gpu, screen)
    checkArg(1, gpu, "string")
    checkArg(2, screen, "string")

    local proxy = component.proxy(gpu)

    proxy.bind(screen)
    proxy.setForeground(colors[8])
    proxy.setBackground(colors[1])

    proxy.setDepth(proxy.maxDepth())
    -- optimizations for no color on T1
    if proxy.getDepth() == 1 then
      local fg, bg = proxy.setForeground, proxy.setBackground
      local f, b = colors[1], colors[8]
      function proxy.setForeground(c)
        if c >= 0xAAAAAA or c <= 0x111111 and f ~= c then
          fg(c)
        end
        f = c
      end
      function proxy.setBackground(c)
        if c >= 0xAAAAAA or c <= 0x111111 and b ~= c then
          bg(c)
        end
        b = c
      end
      proxy.getBackground = function()return f end
      proxy.getForeground = function()return b end
    end

    -- userspace will never directly see this, so it doesn't really matter what
    -- we put in this table
    local new = setmetatable({
      attributes = {echo=true,line=true,raw=false,cursor=false}, -- terminal attributes
      disabled = {}, -- disabled signals
      keyboards = {}, -- all attached keyboards on terminal initialization
      in_esc = false, -- was a partial escape sequence written
      gpu = proxy, -- the associated GPU
      esc = "", -- the escape sequence buffer
      cx = 1, -- the cursor's X position
      cy = 1, -- the cursor's Y position
      fg = colors[8], -- the current foreground color
      bg = colors[1], -- the current background color
      rb = "", -- a buffer of characters read from the input
      wb = "", -- line buffering at its finest
    }, {__index = _stream})

    -- avoid gpu.getResolution calls
    new.w, new.h = proxy.maxResolution()

    proxy.setResolution(new.w, new.h)
    proxy.fill(1, 1, new.w, new.h, " ")
    
    -- register all keyboards attached to the screen
    for _, keyboard in pairs(component.invoke(screen, "getKeyboards")) do
      new.keyboards[keyboard] = true
    end
    
    -- register a keypress handler
    new.key_handler_id = k.event.register("key_down", function(...)
      return new:key_down(...)
    end)

    new.clip_handler_id = k.event.register("clipboard", function(...)
      return new:clipboard(...)
    end)
    
    -- register the TTY with the sysfs
    if k.sysfs then
      k.sysfs.register(k.sysfs.types.tty, new, "/dev/tty"..ttyn)
      new.ttyn = ttyn
    end
    
    ttyn = ttyn + 1
    
    return new
  end
end
--#include "base/tty.lua"
-- event handling --

do
  local event = {}
  local handlers = {}

  function event.handle(sig)
    for _, v in pairs(handlers) do
      if v.signal == sig[1] then
        v.callback(table.unpack(sig))
      end
    end
  end

  local n = 0
  function event.register(sig, call)
    checkArg(1, sig, "string")
    checkArg(2, call, "function")
    
    n = n + 1
    handlers[n] = {signal=sig,callback=call}
    return n
  end

  function event.unregister(id)
    checkArg(1, id, "number")
    handlers[id] = nil
    return true
  end

  k.event = event
end
--#include "base/event.lua"
-- early boot logger

do
  local levels = {
    debug = 0,
    info = 1,
    warn = 64,
    error = 128,
    panic = 256,
  }
  k.loglevels = levels

  local lgpu = component.list("gpu", true)()
  local lscr = component.list("screen", true)()

  local function safe_concat(...)
    local args = table.pack(...)
    local msg = ""
  
    for i=1, args.n, 1 do
      msg = string.format("%s%s%s", msg, tostring(args[i]), i < args.n and " " or "")
    end
    return msg
  end

  if lgpu and lscr then
    k.logio = k.create_tty(lgpu, lscr)
    
    function k.log(level, ...)
      local msg = safe_concat(...)
      msg = msg:gsub("\t", "  ")

      if k.util and not k.util.concat then
        k.util.concat = safe_concat
      end
    
      if (tonumber(k.cmdline.loglevel) or 1) <= level then
        k.logio:write(string.format("[\27[35m%4.4f\27[37m] %s\n", k.uptime(),
          msg))
      end
      return true
    end
  else
    k.logio = nil
    function k.log()
    end
  end

  local raw_pullsignal = computer.pullSignal
  
  function k.panic(...)
    local msg = safe_concat(...)
  
    computer.beep(440, 0.25)
    computer.beep(380, 0.25)

    -- if there's no log I/O, just die
    if not k.logio then
      error(msg)
    end
    
    k.log(k.loglevels.panic, "-- \27[91mbegin stacktrace\27[37m --")
    
    local traceback = debug.traceback(msg, 2)
      :gsub("\t", "  ")
      :gsub("([^\n]+):(%d+):", "\27[96m%1\27[37m:\27[95m%2\27[37m:")
      :gsub("'([^']+)'\n", "\27[93m'%1'\27[37m\n")
    
    for line in traceback:gmatch("[^\n]+") do
      k.log(k.loglevels.panic, line)
    end

    k.log(k.loglevels.panic, "-- \27[91mend stacktrace\27[37m --")
    k.log(k.loglevels.panic, "\27[93m!! \27[91mPANIC\27[93m !!\27[37m")
    
    while true do raw_pullsignal() end
  end
end

k.log(k.loglevels.info, "Starting\27[93m", _OSVERSION, "\27[37m")
--#include "base/logger.lua"
-- kernel hooks

k.log(k.loglevels.info, "base/hooks")

do
  local hooks = {}
  k.hooks = {}
  
  function k.hooks.add(name, func)
    checkArg(1, name, "string")
    checkArg(2, func, "function")
  
    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], func)
  end

  function k.hooks.call(name, ...)
    checkArg(1, name, "string")

    if hooks[name] then
      for k, v in ipairs(hooks[name]) do
        v(...)
      end
    end
  end
end
--#include "base/hooks.lua"
-- some utilities --

k.log(k.loglevels.info, "base/util")

do
  local util = {}
  
  function util.merge_tables(a, b)
    for k, v in pairs(b) do
      if not a[k] then
        a[k] = v
      end
    end
  
    return a
  end

  -- here we override rawset() in order to properly protect tables
  local _rawset = rawset
  local blacklist = setmetatable({}, {__mode = "k"})
  
  function _G.rawset(t, k, v)
    if not blacklist[t] then
      return _rawset(t, k, v)
    else
      -- this will error
      t[k] = v
    end
  end

  local function protecc()
    error("attempt to modify a write-protected table")
  end

  function util.protect(tbl)
    local new = {}
    local mt = {
      __index = tbl,
      __newindex = protecc,
      __pairs = tbl,
      __metatable = {}
    }
  
    return setmetatable(new, mt)
  end

  -- create hopefully memory-friendly copies of tables
  -- uses metatable magic
  -- this is a bit like util.protect except tables are still writable
  -- even i still don't fully understand how this works, but it works
  -- nonetheless
  --[[disabled due to some issues i was having
  if computer.totalMemory() < 262144 then
    -- if we have 256k or less memory, use the mem-friendly function
    function util.copy_table(tbl)
      if type(tbl) ~= "table" then return tbl end
      local shadow = {}
      local copy_mt = {
        __index = function(_, k)
          local item = rawget(shadow, k) or rawget(tbl, k)
          return util.copy(item)
        end,
        __pairs = function()
          local iter = {}
          for k, v in pairs(tbl) do
            iter[k] = util.copy(v)
          end
          for k, v in pairs(shadow) do
            iter[k] = v
          end
          return pairs(iter)
        end
        -- no __metatable: leaving this metatable exposed isn't a huge
        -- deal, since there's no way to access `tbl` for writing using any
        -- of the functions in it.
      }
      copy_mt.__ipairs = copy_mt.__pairs
      return setmetatable(shadow, copy_mt)
    end
  else--]] do
    -- from https://lua-users.org/wiki/CopyTable
    local function deepcopy(orig, copies)
      copies = copies or {}
      local orig_type = type(orig)
      local copy
    
      if orig_type == 'table' then
        if copies[orig] then
          copy = copies[orig]
        else
          copy = {}
          copies[orig] = copy
      
          for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
          end
          
          setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
      else -- number, string, boolean, etc
        copy = orig
      end

      return copy
    end

    function util.copy_table(t)
      return deepcopy(t)
    end
  end

  function util.to_hex(str)
    local ret = ""
    
    for char in str:gmatch(".") do
      ret = string.format("%s%02x", ret, string.byte(char))
    end
    
    return ret
  end

  -- lassert: local assert
  -- removes the "init:123" from errors (fires at level 0)
  function util.lassert(a, ...)
    if not a then error(..., 0) else return a, ... end
  end

  -- pipes for IPC and shells and things
  do
    local _pipe = {}

    function _pipe:read(n)
      if self.closed and #self.rb == 0 then
        return nil
      end
      while #self.rb < n and not self.closed do
        if self.from ~= 0 then
          k.scheduler.info().data.self.resume_next = self.from
        end
        coroutine.yield()
      end
      local data = self.rb:sub(1, n)
      self.rb = self.rb:sub(n + 1)
      return data
    end

    function _pipe:write(dat)
      if self.closed then
        return nil
      end
      self.rb = self.rb .. dat
      return true
    end

    function _pipe:flush()
      return true
    end

    function _pipe:close()
      self.closed = true
      return true
    end

    function util.make_pipe()
      return k.create_fstream(setmetatable({
        from = 0, -- the process providing output
        to = 0, -- the process reading input
        rb = "",
      }, {__index = _pipe}), "rw")
    end

    k.hooks.add("sandbox", function()
      k.userspace.package.loaded.pipe = {
        create = util.make_pipe
      }
    end)
  end

  k.util = util
end
--#include "base/util.lua"
-- some security-related things --

k.log(k.loglevels.info, "base/security")

k.security = {}

-- users --

k.log(k.loglevels.info, "base/security/users")

-- from https://github.com/philanc/plc iirc

k.log(k.loglevels.info, "base/security/sha3.lua")

do
-- sha3 / keccak

local char	= string.char
local concat	= table.concat
local spack, sunpack = string.pack, string.unpack

-- the Keccak constants and functionality

local ROUNDS = 24

local roundConstants = {
0x0000000000000001,
0x0000000000008082,
0x800000000000808A,
0x8000000080008000,
0x000000000000808B,
0x0000000080000001,
0x8000000080008081,
0x8000000000008009,
0x000000000000008A,
0x0000000000000088,
0x0000000080008009,
0x000000008000000A,
0x000000008000808B,
0x800000000000008B,
0x8000000000008089,
0x8000000000008003,
0x8000000000008002,
0x8000000000000080,
0x000000000000800A,
0x800000008000000A,
0x8000000080008081,
0x8000000000008080,
0x0000000080000001,
0x8000000080008008
}

local rotationOffsets = {
-- ordered for [x][y] dereferencing, so appear flipped here:
{0, 36, 3, 41, 18},
{1, 44, 10, 45, 2},
{62, 6, 43, 15, 61},
{28, 55, 25, 21, 56},
{27, 20, 39, 8, 14}
}



-- the full permutation function
local function keccakF(st)
	local permuted = st.permuted
	local parities = st.parities
	for round = 1, ROUNDS do
--~ 		local permuted = permuted
--~ 		local parities = parities

		-- theta()
		for x = 1,5 do
			parities[x] = 0
			local sx = st[x]
			for y = 1,5 do parities[x] = parities[x] ~ sx[y] end
		end
		--
		-- unroll the following loop
		--for x = 1,5 do
		--	local p5 = parities[(x)%5 + 1]
		--	local flip = parities[(x-2)%5 + 1] ~ ( p5 << 1 | p5 >> 63)
		--	for y = 1,5 do st[x][y] = st[x][y] ~ flip end
		--end
		local p5, flip, s
		--x=1
		p5 = parities[2]
		flip = parities[5] ~ (p5 << 1 | p5 >> 63)
		s = st[1]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=2
		p5 = parities[3]
		flip = parities[1] ~ (p5 << 1 | p5 >> 63)
		s = st[2]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=3
		p5 = parities[4]
		flip = parities[2] ~ (p5 << 1 | p5 >> 63)
		s = st[3]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=4
		p5 = parities[5]
		flip = parities[3] ~ (p5 << 1 | p5 >> 63)
		s = st[4]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=5
		p5 = parities[1]
		flip = parities[4] ~ (p5 << 1 | p5 >> 63)
		s = st[5]
		for y = 1,5 do s[y] = s[y] ~ flip end

		-- rhopi()
		for y = 1,5 do
			local py = permuted[y]
			local r
			for x = 1,5 do
				s, r = st[x][y], rotationOffsets[x][y]
				py[(2*x + 3*y)%5 + 1] = (s << r | s >> (64-r))
			end
		end

		local p, p1, p2
		--x=1
		s, p, p1, p2 = st[1], permuted[1], permuted[2], permuted[3]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=2
		s, p, p1, p2 = st[2], permuted[2], permuted[3], permuted[4]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=3
		s, p, p1, p2 = st[3], permuted[3], permuted[4], permuted[5]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=4
		s, p, p1, p2 = st[4], permuted[4], permuted[5], permuted[1]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=5
		s, p, p1, p2 = st[5], permuted[5], permuted[1], permuted[2]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end

		-- iota()
		st[1][1] = st[1][1] ~ roundConstants[round]
	end
end


local function absorb(st, buffer)

	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 8

	-- append 0x01 byte and pad with zeros to block size (rate/8 bytes)
	local totalBytes = #buffer + 1
	-- SHA3:
	buffer = buffer .. ( '\x06' .. char(0):rep(blockBytes - (totalBytes % blockBytes)))
	totalBytes = #buffer

	--convert data to an array of u64
	local words = {}
	for i = 1, totalBytes - (totalBytes % 8), 8 do
		words[#words + 1] = sunpack('<I8', buffer, i)
	end

	local totalWords = #words
	-- OR final word with 0x80000000 to set last bit of state to 1
	words[totalWords] = words[totalWords] | 0x8000000000000000

	-- XOR blocks into state
	for startBlock = 1, totalWords, blockWords do
		local offset = 0
		for y = 1, 5 do
			for x = 1, 5 do
				if offset < blockWords then
					local index = startBlock+offset
					st[x][y] = st[x][y] ~ words[index]
					offset = offset + 1
				end
			end
		end
		keccakF(st)
	end
end


-- returns [rate] bits from the state, without permuting afterward.
-- Only for use when the state will immediately be thrown away,
-- and not used for more output later
local function squeeze(st)
	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 4
	-- fetch blocks out of state
	local hasht = {}
	local offset = 1
	for y = 1, 5 do
		for x = 1, 5 do
			if offset < blockWords then
				hasht[offset] = spack("<I8", st[x][y])
				offset = offset + 1
			end
		end
	end
	return concat(hasht)
end


-- primitive functions (assume rate is a whole multiple of 64 and length is a whole multiple of 8)

local function keccakHash(rate, length, data)
	local state = {	{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
	}
	state.rate = rate
	-- these are allocated once, and reused
	state.permuted = { {}, {}, {}, {}, {}, }
	state.parities = {0,0,0,0,0}
	absorb(state, data)
	return squeeze(state):sub(1,length/8)
end

-- output raw bytestrings
local function keccak256Bin(data) return keccakHash(1088, 256, data) end
local function keccak512Bin(data) return keccakHash(576, 512, data) end

k.sha3 = {
	sha256 = keccak256Bin,
	sha512 = keccak512Bin,
}
end
--#include "base/security/sha3.lua"

do
  local api = {}

  -- default root data so we can at least run init as root
  -- the kernel should overwrite this with `users.prime()`
  -- and data from /etc/passwd later on
  -- but for now this will suffice
  local passwd = {
    [0] = {
      name = "root",
      home = "/root",
      shell = "/bin/lsh",
      acls = 8191,
      pass = k.util.to_hex(k.sha3.sha256("root")),
    }
  }

  k.hooks.add("shutdown", function()
    -- put this here so base/passwd_init can have it
    k.passwd = passwd
  end)

  function api.prime(data)
    checkArg(1, data, "table")
 
    api.prime = nil
    passwd = data
    k.passwd = data
    
    return true
  end

  function api.authenticate(uid, pass)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    
    pass = k.util.to_hex(k.sha3.sha256(pass))
    
    local udata = passwd[uid]
    
    if not udata then
      os.sleep(1)
      return nil, "no such user"
    end
    
    if pass == udata.pass then
      return true
    end
    
    os.sleep(1)
    return nil, "invalid password"
  end

  function api.exec_as(uid, pass, func, pname, wait)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    checkArg(3, func, "function")
    checkArg(4, pname, "string", "nil")
    checkArg(5, wait, "boolean", "nil")
    
    if not k.security.acl.user_has_permission(k.scheduler.info().owner,
        k.security.acl.permissions.user.SUDO) then
      return nil, "permission denied: no permission"
    end
    
    if not api.authenticate(uid, pass) then
      return nil, "permission denied: bad login"
    end
    
    local new = {
      func = func,
      name = pname or tostring(func),
      owner = uid,
      env = {
        USER = passwd[uid].name,
        UID = tostring(uid),
        SHELL = passwd[uid].shell,
        HOME = passwd[uid].home,
      }
    }
    
    local p = k.scheduler.spawn(new)
    
    if not wait then return end

    -- this is the only spot in the ENTIRE kernel where process.await is used
    return k.userspace.package.loaded.process.await(p.pid)
  end

  function api.get_uid(uname)
    checkArg(1, uname, "string")
    
    for uid, udata in pairs(passwd) do
      if udata.name == uname then
        return uid
      end
    end
    
    return nil, "no such user"
  end

  function api.attributes(uid)
    checkArg(1, uid, "number")
    
    local udata = passwd[uid]
    
    if not udata then
      return nil, "no such user"
    end
    
    return {
      name = udata.name,
      home = udata.home,
      shell = udata.shell,
      acls = udata.acls
    }
  end

  function api.usermod(attributes)
    checkArg(1, attributes, "table")
    attributes.uid = tonumber(attributes.uid) or (#passwd + 1)
    
    local current = k.scheduler.info().owner or 0
    
    if not passwd[attributes.uid] then
      assert(attributes.name, "usermod: a username is required")
      assert(attributes.pass, "usermod: a password is required")
      assert(attributes.acls, "usermod: ACL data is required")
      assert(type(attributes.acls) == "table","usermod: ACL data must be a table")
    else
      if attributes.pass and current ~= 0 and current ~= attributes.uid then
        -- only root can change someone else's password
        return nil, "cannot change password: permission denied"
      end
      for k, v in pairs(passwd[attributes.uid]) do
        attributes[k] = v
      end
    end

    attributes.home = attributes.home or "/home/" .. attributes.name
    attributes.shell = (attributes.shell or "/bin/lsh"):gsub("%.lua$", "")

    local acl = k.security.acl
    local acls = 0
    for k, v in pairs(attributes.acls) do
      if acl.permissions.user[k] and v then
        acls = acls & acl.permissions.user[k]
        if not acl.user_has_permission(current, acl.permissions.user[k])
            and current ~= 0 then
          return nil, k .. ": ACL permission denied"
        end
      else
        return nil, k .. ": no such ACL"
      end
    end

    attributes.acls = acls

    passwd[attributes.uid] = attributes

    return true
  end

  function api.remove(uid)
    checkArg(1, uid, "number")
    if not passwd[uid] then
      return nil, "no such user"
    end

    if not k.security.acl.user_has_permission(k.scheduler.info().owner,
        k.security.acl.permissions.user.MANAGE_USERS) then
      return nil, "permission denied"
    end

    passwd[uid] = nil
    
    return true
  end
  
  k.security.users = api
end
--#include "base/security/users.lua"
-- access control lists, mostly --

k.log(k.loglevels.info, "base/security/access_control")

do
  -- this implementation of ACLs is fairly basic.
  -- it only supports boolean on-off permissions rather than, say,
  -- allowing users only to log on at certain times of day.
  local permissions = {
    user = {
      SUDO = 1,
      MOUNT = 2,
      OPEN_UNOWNED = 4,
      COMPONENTS = 8,
      HWINFO = 16,
      SETARCH = 32,
      MANAGE_USERS = 64,
      BOOTADDR = 128
    },
    file = {
      OWNER_READ = 1,
      OWNER_WRITE = 2,
      OWNER_EXEC = 4,
      GROUP_READ = 8,
      GROUP_WRITE = 16,
      GROUP_EXEC = 32,
      OTHER_READ = 64,
      OTHER_WRITE = 128,
      OTHER_EXEC = 256
    }
  }

  local acl = {}

  acl.permissions = permissions

  function acl.user_has_permission(uid, permission)
    checkArg(1, uid, "number")
    checkArg(2, permission, "number")
  
    local attributes, err = k.security.users.attributes(uid)
    
    if not attributes then
      return nil, err
    end
    
    return acl.has_permission(attributes.acls, permission)
  end

  function acl.has_permission(perms, permission)
    checkArg(1, perms, "number")
    checkArg(2, permission, "number")
    
    return perms & permission ~= 0
  end

  k.security.acl = acl
end
--#include "base/security/access_control.lua"
--#include "base/security.lua"
-- some shutdown related stuff

k.log(k.loglevels.info, "base/shutdown")

do
  local shutdown = computer.shutdown
  
  function k.shutdown(rbt)
    k.is_shutting_down = true
    k.hooks.call("shutdown", rbt)
    k.log(k.loglevels.info, "shutdown: shutting down")
    shutdown(rbt)
  end

  computer.shutdown = k.shutdown
end
--#include "base/shutdown.lua"
-- some component API conveniences

k.log(k.loglevels.info, "base/component")

do
  function component.get(addr, mkpx)
    checkArg(1, addr, "string")
    checkArg(2, mkpx, "boolean", "nil")
    
    for k, v in component.list() do
      if k:sub(1, #addr) == addr then
        return mkpx and component.proxy(k) or k
      end
    end
    
    return nil, "no such component"
  end

  setmetatable(component, {
    __index = function(t, k)
      local addr = component.list(k)()
      if not addr then
        error(string.format("no component of type '%s'", k))
      end
    
      return component.proxy(addr)
    end
  })
end
--#include "base/component.lua"
-- fsapi: VFS and misc filesystem infrastructure

k.log(k.loglevels.info, "base/fsapi")

do
  local fs = {}

  -- common error codes
  fs.errors = {
    file_not_found = "no such file or directory",
    is_a_directory = "is a directory",
    not_a_directory = "not a directory",
    read_only = "target is read-only",
    failed_read = "failed opening file for reading",
    failed_write = "failed opening file for writing",
    file_exists = "file already exists"
  }

  -- standard file types
  fs.types = {
    file = 1,
    directory = 2,
    link = 3,
    special = 4
  }

  -- This VFS should support directory overlays, fs mounting, and directory
  --    mounting, hopefully all seamlessly.
  -- mounts["/"] = { node = ..., children = {["bin"] = "usr/bin", ...}}
  local mounts = {}
  fs.mounts = mounts

  local function split(path)
    local segments = {}
    
    for seg in path:gmatch("[^/]+") do
      if seg == ".." then
        segments[#segments] = nil
      elseif seg ~= "." then
        segments[#segments + 1] = seg
      end
    end
    
    return segments
  end

  fs.split = split

  -- "clean" a path
  local function clean(path)
    return table.concat(split(path), "/")
  end

  local faux = {children = mounts}
  local resolving = {}

  local function resolve(path, must_exist)
    if resolving[path] then
      return nil, "recursive mount detected"
    end
    
    path = clean(path)
    resolving[path] = true

    local current, parent = mounts["/"] or faux

    if not mounts["/"] then
      resolving[path] = nil
      return nil, "root filesystem is not mounted!"
    end

    if path == "" or path == "/" then
      resolving[path] = nil
      return mounts["/"], nil, ""
    end
    
    if current.children[path] then
      resolving[path] = nil
      return current.children[path], nil, ""
    end
    
    local segments = split(path)
    
    local base_n = 1 -- we may have to traverse multiple mounts
    
    for i=1, #segments, 1 do
      local try = table.concat(segments, "/", base_n, i)
    
      if current.children[try] then
        base_n = i + 1 -- we are now at this stage of the path
        local next_node = current.children[try]
      
        if type(next_node) == "string" then
          local err
          next_node, err = resolve(next_node)
        
          if not next_node then
            resolving[path] = false
            return nil, err
          end
        end
        
        parent = current
        current = next_node
      elseif not current.node:stat(try) then
        resolving[path] = false

        return nil, fs.errors.file_not_found
      end
    end
    
    resolving[path] = false
    local ret = "/"..table.concat(segments, "/", base_n, #segments)
    
    if must_exist and not current.node:stat(ret) then
      return nil, fs.errors.file_not_found
    end
    
    return current, parent, ret
  end

  local registered = {partition_tables = {}, filesystems = {}}

  local _managed = {}
  function _managed:info()
    return {
      read_only = self.node.isReadOnly(),
      address = self.node.address
    }
  end

  function _managed:stat(file)
    checkArg(1, file, "string")

    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    local info = {
      permissions = self:info().read_only and 365 or 511,
      type        = self.node.isDirectory(file) and fs.types.directory or fs.types.file,
      isDirectory = self.node.isDirectory(file),
      owner       = -1,
      group       = -1,
      lastModified= self.node.lastModified(file),
      size        = self.node.size(file)
    }

    if file:sub(1, -4) == ".lua" then
      info.permissions = info.permissions | k.security.acl.permissions.file.OWNER_EXEC
      info.permissions = info.permissions | k.security.acl.permissions.file.GROUP_EXEC
      info.permissions = info.permissions | k.security.acl.permissions.file.OTHER_EXEC
    end

    return info
  end

  function _managed:touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    if self.node.isReadOnly() then
      return nil, fs.errors.read_only
    end
    
    if self.node.exists(file) then
      return nil, fs.errors.file_exists
    end
    
    if ftype == fs.types.file or not ftype then
      local fd = self.node.open(file, "w")
    
      if not fd then
        return nil, fs.errors.failed_write
      end
      
      self.node.write(fd, "")
      self.node.close(fd)
    elseif ftype == fs.types.directory then
      local ok, err = self.node.makeDirectory(file)
      
      if not ok then
        return nil, err or "unknown error"
      end
    elseif ftype == fs.types.link then
      return nil, "unsupported operation"
    end
    
    return true
  end
  
  function _managed:remove(file)
    checkArg(1, file, "string")
    
    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    if self.node.isDirectory(file) and #(self.node.list(file) or {}) > 0 then
      return nil, fs.errors.is_a_directory
    end
    
    return self.node.remove(file)
  end

  function _managed:list(path)
    checkArg(1, path, "string")
    
    if not self.node.exists(path) then
      return nil, fs.errors.file_not_found
    elseif not self.node.isDirectory(path) then
      return nil, fs.errors.not_a_directory
    end
    
    local files = self.node.list(path) or {}
    
    return files
  end
  
  local function fread(s, n)
    return s.node.read(s.fd, n)
  end

  local function fwrite(s, d)
    return s.node.write(s.fd, d)
  end

  local function fseek(s, w, o)
    return s.node.seek(s.fd, w, o)
  end

  local function fclose(s)
    return s.node.close(s.fd)
  end

  function _managed:open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    
    if (mode == "r" or mode == "a") and not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    local fd = {
      fd = self.node.open(file, mode or "r"),
      node = self.node,
      read = fread,
      write = fwrite,
      seek = fseek,
      close = fclose
    }
    
    return fd
  end
  
  local fs_mt = {__index = _managed}
  local function create_node_from_managed(proxy)
    return setmetatable({node = proxy}, fs_mt)
  end

  local function create_node_from_unmanaged(proxy)
    local fs_superblock = proxy.readSector(1)
    
    for k, v in pairs(registered.filesystems) do
      if v.is_valid_superblock(superblock) then
        return v.new(proxy)
      end
    end
    
    return nil, "no compatible filesystem driver available"
  end

  fs.PARTITION_TABLE = "partition_tables"
  fs.FILESYSTEM = "filesystems"
  
  function fs.register(category, driver)
    if not registered[category] then
      return nil, "no such category: " .. category
    end
  
    table.insert(registered[category], driver)
    return true
  end

  function fs.get_partition_table_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return nil, "managed filesystem has no partition table"
    else -- unmanaged drive - perfect
      for k, v in pairs(registered.partition_tables) do
        if v.has_valid_superblock(proxy) then
          return v.create(proxy)
        end
      end
    end
    
    return nil, "no compatible partition table driver available"
  end

  function fs.get_filesystem_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return create_node_from_managed(filesystem)
    else
      return create_node_from_unmanaged(filesystem)
    end
  end

  -- actual filesystem API now
  fs.api = {}
  
  function fs.api.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
  
    mode = mode or "r"

    if mode:match("[wa]") then
      fs.api.touch(file)
    end

    local node, err, path = resolve(file)
    if not node then
      return nil, err
    end
    
    local data = node.node:stat(path)
    local user = (k.scheduler.info() or {owner=0}).owner
    -- TODO: groups
    
    do
      local perms = k.security.acl.permissions.file
      local rperm, wperm
    
      if data.owner ~= user then
        rperm = perms.OTHER_READ
        wperm = perms.OTHER_WRITE
      else
        rperm = perms.OWNER_READ
        wperm = perms.OWNER_WRITE
      end
      
      if ((mode == "r" and not
          k.security.acl.has_permission(data.permissions, rperm)) or
          ((mode == "w" or mode == "a") and not
          k.security.acl.has_permission(data.permissions, wperm))) and not
          k.security.acl.user_has_permission(user,
          k.security.acl.permissions.OPEN_UNOWNED) then
        return nil, "permission denied"
      end
    end
    
    return node.node:open(path, mode)
  end

  function fs.api.stat(file)
    checkArg(1, file, "string")
    
    local node, err, path = resolve(file)
    
    if not node then
      return nil, err
    end

    return node.node:stat(path)
  end

  function fs.api.touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    ftype = ftype or fs.types.file
    
    local root, base = file:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    base = base or file
    
    local node, err, path = resolve(root)
    
    if not node then
      return nil, err
    end
    
    return node.node:touch(path .. "/" .. base, ftype)
  end

  local n = {}
  function fs.api.list(path)
    checkArg(1, path, "string")
    
    local node, err, fpath = resolve(path, true)

    if not node then
      return nil, err
    end

    local ok, err = node.node:list(fpath)
    if not ok and err then
      return nil, err
    end

    ok = ok or {}
    local used = {}
    for _, v in pairs(ok) do used[v] = true end

    if node.children then
      for k in pairs(node.children) do
        if not k:match(".+/.+") then
          local info = fs.api.stat(path.."/"..k)
          if (info or n).isDirectory then
            k = k .. "/"
          end
          if info and not used[k] then
            ok[#ok + 1] = k
          end
        end
      end
    end
   
    return ok
  end

  function fs.api.remove(file)
    checkArg(1, file, "string")
    
    local node, err, path = resolve(file)
    
    if not node then
      return nil, err
    end
    
    return node.node:remove(path)
  end

  local mounted = {}

  fs.api.types = {
    RAW = 0,
    NODE = 1,
    OVERLAY = 2,
  }
  
  function fs.api.mount(node, fstype, path)
    checkArg(1, node, "string", "table")
    checkArg(2, fstype, "number")
    checkArg(2, path, "string")
    
    local device, err = node
    
    if fstype ~= fs.api.types.RAW then
      -- TODO: properly check object methods first
      goto skip
    end
    
    device, err = fs.get_filesystem_driver(node)
    if k.sysfs and not device then
      local sdev, serr = k.sysfs.retrieve(node)
      if not sdev then return nil, serr end
      device, err = fs.get_filesystem_driver(sdev)
    end
    
    ::skip::

    if type(device) == "string" and fstype ~= fs.types.OVERLAY then
      device = component.proxy(device)
      if (not device) then
        return nil, "no such component"
      elseif device.type ~= "filesystem" and device.type ~= "drive" then
        return nil, "component is not a drive or filesystem"
      end

      if device.type == "filesystem" then
        device = create_node_from_managed(device)
      else
        device = create_node_from_unmanaged(device)
      end
    end

    if not device then
      return nil, err
    end

    if device.type == "filesystem" then
    end
    
    path = clean(path)
    if path == "" then path = "/" end
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local pnode, err, rpath
    
    if path == "/" then
      mounts["/"] = {node = device, children = {}}
      mounted["/"] = (device.node and device.node.getLabel
        and device.node.getLabel()) or device.node
        and device.node.address or "unknown"
      return true
    else
      pnode, err, rpath = resolve(root)
    end

    if not pnode then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    if full == "" then full = "/" end

    if type(device) == "string" then
      pnode.children[full] = device
    else
      pnode.children[full] = {node=device, children={}}
      mounted[path]=(device.node and device.node.getLabel
        and device.node.getLabel()) or device.node
        and device.node.address or "unknown"
    end
    
    return true
  end

  function fs.api.umount(path)
    checkArg(1, path, "string")
    
    path = clean(path)
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local node, err, rpath = resolve(root)
    
    if not node then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    node.children[full] = nil
    mounted[path] = nil
    
    return true
  end

  function fs.api.mounts()
    local new = {}
    -- prevent programs from meddling with these
    for k,v in pairs(mounted) do new[("/"..k):gsub("[\\/]+", "/")] = v end
    return new
  end

  k.fs = fs
end
--#include "base/fsapi.lua"
-- the Lua standard library --

-- stdlib: os

do
  function os.execute()
    error("os.execute must be implemented by userspace", 0)
  end

  function os.setenv(K, v)
    local info = k.scheduler.info()
    info.data.env[K] = v
  end

  function os.getenv(K)
    local info = k.scheduler.info()
    
    if not K then
      return info.data.env
    end

    return info.data.env[K]
  end

  function os.sleep(n)
    checkArg(1, n, "number")

    local max = computer.uptime() + n
    repeat
      coroutine.yield(max - computer.uptime())
    until computer.uptime() >= max

    return true
  end

  function os.exit(n)
    coroutine.yield("__internal_process_exit", n)
  end
end
--#include "base/stdlib/os.lua"
-- implementation of the FILE* API --

k.log(k.loglevels.info, "base/stdlib/FILE*")

do
  local buffer = {}
 
  function buffer:read_byte()
    if self.buffer_mode ~= "none" then
      if (not self.read_buffer) or #self.read_buffer == 0 then
        self.read_buffer = self.base:read(self.buffer_size)
      end
  
      if not self.read_buffer then
        self.closed = true
        return nil
      end
      
      local dat = self.read_buffer:sub(1,1)
      self.read_buffer = self.read_buffer:sub(2, -1)
      
      return dat
    else
      return self.base:read(1)
    end
  end

  function buffer:write_byte(byte)
    if self.buffer_mode ~= "none" then
      if #self.write_buffer >= self.buffer_size then
        self.base:write(self.write_buffer)
        self.write_buffer = ""
      end
      
      self.write_buffer = string.format("%s%s", self.write_buffer, byte)
    else
      return self.base:write(byte)
    end

    return true
  end

  function buffer:read_line()
    local line = ""
    
    repeat
      local c = self:read_byte()
      line = line .. (c or "")
    until c == "\n" or not c
    
    return line
  end

  local valid = {
    a = true,
    l = true,
    L = true,
    n = true
  }

  function buffer:read_formatted(fmt)
    checkArg(1, fmt, "string", "number")
    
    if type(fmt) == "number" then
      if fmt == 0 then return "" end
      local read = ""
    
      repeat
        local byte = self:read_byte()
        read = read .. (byte or "")
      until #read >= fmt or not byte
      
      return read
    else
      fmt = fmt:gsub("%*", ""):sub(1,1)
      
      if #fmt == 0 or not valid[fmt] then
        error("bad argument to 'read' (invalid format)")
      end
      
      if fmt == "l" or fmt == "L" then
        local line = self:read_line()
      
        if fmt == "l" then
          line = line:sub(1, -2)
        end
        
        return line
      elseif fmt == "a" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          read = read .. (byte or "")
        until not byte
        
        return read
      elseif fmt == "n" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          if not tonumber(byte) then
            -- TODO: this breaks with no buffering
            self.read_buffer = byte .. self.read_buffer
          else
            read = read .. (byte or "")
          end
        until not tonumber(byte)
        
        return tonumber(read)
      end

      error("bad argument to 'read' (invalid format)")
    end
  end

  function buffer:read(...)
    if self.closed or not self.mode.r then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    if args.n == 0 then args[1] = "l" args.n = 1 end
    
    local read = {}
    for i=1, args.n, 1 do
      read[i] = self:read_formatted(args[i])
    end
    
    return table.unpack(read)
  end

  function buffer:lines(format)
    format = format or "l"
    
    return function()
      return self:read(format)
    end
  end

  function buffer:write(...)
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    local write = ""
    
    for i=1, #args, 1 do
      checkArg(i, args[i], "string", "number")
    
      args[i] = tostring(args[i])
      write = string.format("%s%s", write, args[i])
    end
    
    if self.buffer_mode == "none" then
      -- a-ha! performance shortcut!
      -- because writing in a chunk is much faster
      return self.base:write(write)
    end

    for i=1, #write, 1 do
      local char = write:sub(i,i)
      self:write_byte(char)
    end

    return true
  end

  function buffer:seek(whence, offset)
    checkArg(1, whence, "string")
    checkArg(2, offset, "number")
    
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    self:flush()
    return self.base:seek()
  end

  function buffer:flush()
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    if #self.write_buffer > 0 then
      self.base:write(self.write_buffer)
      self.write_buffer = ""
    end

    if self.base.flush then
      self.base:flush()
    end
    
    return true
  end

  function buffer:close()
    self:flush()
    self.closed = true
  end

  local fmt = {
    __index = buffer,
    -- __metatable = {},
    __name = "FILE*"
  }

  function k.create_fstream(base, mode)
    checkArg(1, base, "table")
    checkArg(2, mode, "string")
  
    local new = {
      base = base,
      buffer_size = 512,
      read_buffer = "",
      write_buffer = "",
      buffer_mode = "standard", -- standard, line, none
      closed = false,
      mode = {}
    }
    
    for c in mode:gmatch(".") do
      new.mode[c] = true
    end
    
    setmetatable(new, fmt)
    return new
  end
end
--#include "base/stdlib/FILE.lua"
-- io library --

k.log(k.loglevels.info, "base/stdlib/io")

do
  local fs = k.fs.api
  local im = {stdin = 0, stdout = 1, stderr = 2}
 
  local mt = {
    __index = function(t, f)
      if not k.scheduler then return k.logio end
      local info = k.scheduler.info()
  
      if info and info.data and info.data.io then
        return info.data.io[f]
      end
      
      return nil
    end,
    __newindex = function(t, f, v)
      local info = k.scheduler.info()
      if not info then return nil end
      info.data.io[f] = v
      info.data.handles[im[f]] = v
    end
  }

  _G.io = {}
  
  function io.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
  
    mode = mode or "r"

    local handle, err = fs.open(file, mode)
    if not handle then
      return nil, err
    end

    local fstream = k.create_fstream(handle, mode)

    local info = k.scheduler.info()
    if info then
      info.data.handles[#info.data.handles + 1] = fstream
      fstream.n = #info.data.handles
      
      local close = fstream.close
      function fstream:close()
        close(self)
        info.data.handles[self.n] = nil
      end
    end
    
    return fstream
  end

  -- popen should be defined in userspace so the shell can handle it.
  -- tmpfile should be defined in userspace also.
  -- it turns out that defining things PUC Lua can pass off to the shell
  -- *when you don't have a shell* is rather difficult and so, instead of
  -- weird hacks like in Paragon or Monolith, I just leave it up to userspace.
  function io.popen()
    return nil, "io.popen unsupported at kernel level"
  end

  function io.tmpfile()
    return nil, "io.tmpfile unsupported at kernel level"
  end

  function io.read(...)
    return io.input():read(...)
  end

  function io.write(...)
    return io.output():write(...)
  end

  function io.lines(file, fmt)
    file = file or io.stdin

    if type(file) == "string" then
      file = assert(io.open(file, "r"))
    end
    
    checkArg(1, file, "FILE*")
    
    return file:lines(fmt)
  end

  local function stream(kk)
    return function(v)
      if v then checkArg(1, v, "FILE*") end

      if not k.scheduler.info() then
        return k.logio
      end
      local t = k.scheduler.info().data.io
    
      if v then
        t[kk] = v
      end
      
      return t[kk]
    end
  end

  io.input = stream("input")
  io.output = stream("output")

  function io.type(stream)
    assert(stream, "bad argument #1 (value expected)")
    
    if type(stream) == "FILE*" then
      if stream.closed then
        return "closed file"
      end
    
      return "file"
    end

    return nil
  end

  function io.flush(s)
    s = s or io.stdout
    checkArg(1, s, "FILE*")

    return s:flush()
  end

  function io.close(stream)
    checkArg(1, stream, "FILE*")

    if stream == io.stdin or stream == io.stdout or stream == io.stderr then
      return nil, "cannot close standard file"
    end
    
    return stream:close()
  end

  setmetatable(io, mt)
  k.hooks.add("sandbox", function()
    setmetatable(k.userspace.io, mt)
  end)

  function _G.print(...)
    local args = table.pack(...)
   
    for i=1, args.n, 1 do
      args[i] = tostring(args[i])
    end
    
    return (io.stdout or k.logio):write(
      table.concat(args, "  ", 1, args.n), "\n")
  end
end
--#include "base/stdlib/io.lua"
-- package API.  this is probably the lib i copy-paste the most. --

k.log(k.loglevels.info, "base/stdlib/package")

do
  _G.package = {}
 
  local loaded = {
    os = os,
    io = io,
    math = math,
    string = string,
    table = table,
    users = k.users,
    sha3 = k.sha3,
    unicode = unicode
  }
  
  package.loaded = loaded
  package.path = "/lib/?.lua;/lib/lib?.lua;/lib/?/init.lua"
  
  local fs = k.fs.api

  local function libError(name, searched)
    local err = "module '%s' not found:\n\tno field package.loaded['%s']"
    err = err .. ("\n\tno file '%s'"):rep(#searched)
  
    return string.format(err, name, name, table.unpack(searched))
  end

  function package.searchpath(name, path, sep, rep)
    checkArg(1, name, "string")
    checkArg(2, path, "string")
    checkArg(3, sep, "string", "nil")
    checkArg(4, rep, "string", "nil")
    
    sep = "%" .. (sep or ".")
    rep = rep or "/"
    
    local searched = {}
    
    name = name:gsub(sep, rep)
    
    for search in path:gmatch("[^;]+") do
      search = search:gsub("%?", name)
    
      if fs.stat(search) then
        return search
      end
      
      searched[#searched + 1] = search
    end

    return nil, libError(name, searched)
  end

  package.protect = k.util.protect

  function package.delay(lib, file)
    local mt = {
      __index = function(tbl, key)
        setmetatable(lib, nil)
        setmetatable(lib.internal or {}, nil)
        ; -- this is just in case, because Lua is weird
        (k.userspace.dofile or dofile)(file)
    
        return tbl[key]
      end
    }

    if lib.internal then
      setmetatable(lib.internal, mt)
    end
    
    setmetatable(lib, mt)
  end

  -- let's define this here because WHY NOT
  function _G.loadfile(file, mode, env)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    checkArg(3, env, "table", "nil")
    
    local handle, err = io.open(file, "r")
    if not handle then
      return nil, err
    end
    
    local data = handle:read("a")
    handle:close()

    return load(data, "="..file, "bt", k.userspace or _G)
  end

  function _G.dofile(file)
    checkArg(1, file, "string")
    
    local ok, err = loadfile(file)
    if not ok then
      error(err, 0)
    end
    
    local stat, ret = xpcall(ok, debug.traceback)
    if not stat and ret then
      error(ret, 0)
    end
    
    return ret
  end

  local k = k
  k.hooks.add("sandbox", function()
    k.userspace.k = nil
    
    local acl = k.security.acl
    local perms = acl.permissions
    
    local function wrap(f, p)
      return function(...)
        if not acl.user_has_permission(k.scheduler.info().owner,
            p) then
          error("permission denied")
        end
    
        return f(...)
      end
    end

    k.userspace.component = nil
    k.userspace.computer = nil
    k.userspace.unicode = nil

    k.userspace.package.loaded.component = {}
    
    for f,v in pairs(component) do
      k.userspace.package.loaded.component[f] = wrap(v,
        perms.user.COMPONENTS)
    end
    
    k.userspace.package.loaded.computer = {
      getDeviceInfo = wrap(computer.getDeviceInfo, perms.user.HWINFO),
      setArchitecture = wrap(computer.setArchitecture, perms.user.SETARCH),
      addUser = wrap(computer.addUser, perms.user.MANAGE_USERS),
      removeUser = wrap(computer.removeUser, perms.user.MANAGE_USERS),
      setBootAddress = wrap(computer.setBootAddress, perms.user.BOOTADDR),
      pullSignal = coroutine.yield,
      pushSignal = function(...)
        return k.scheduler.info().data.self:push_signal(...)
      end
    }
    
    for f, v in pairs(computer) do
      k.userspace.package.loaded.computer[f] =
        k.userspace.package.loaded.computer[f] or v
    end
    
    k.userspace.package.loaded.unicode = k.util.copy_table(unicode)
    k.userspace.package.loaded.filesystem = k.util.copy_table(k.fs.api)
    
    local ufs = k.userspace.package.loaded.filesystem
    ufs.mount = wrap(k.fs.api.mount, perms.user.MOUNT)
    ufs.umount = wrap(k.fs.api.umount, perms.user.MOUNT)
    
    k.userspace.package.loaded.filetypes = k.util.copy_table(k.fs.types)

    k.userspace.package.loaded.users = k.util.copy_table(k.security.users)

    k.userspace.package.loaded.acls = k.util.copy_table(k.security.acl.permissions)

    local blacklist = {}
    for k in pairs(k.userspace.package.loaded) do blacklist[k] = true end

    local shadow = k.userspace.package.loaded
    k.userspace.package.loaded = setmetatable({}, {
      __newindex = function(t, k, v)
        if shadow[k] and blacklist[k] then
          error("cannot override protected library " .. k, 0)
        else
          shadow[k] = v
        end
      end,
      __index = shadow,
      __pairs = shadow,
      __ipairs = shadow,
      __metatable = {}
    })
  end)
end
--#include "base/stdlib/package.lua"
--#include "base/stdlib.lua"
-- custom types

k.log(k.loglevels.info, "base/types")

do
  local old_type = type
  function _G.type(obj)
    if old_type(obj) == "table" then
      local s, mt = pcall(getmetatable, obj)
      
      if not s and mt then
        -- getting the metatable failed, so it's protected.
        -- instead, we should tostring() it - if the __name
        -- field is set, we can let the Lua VM get the
        -- """type""" for us.
        local t = tostring(obj):gsub(" [%x+]$", "")
        return t
      end
       
      -- either there is a metatable or ....not. If
      -- we have gotten this far, the metatable was
      -- at least not protected, so we can carry on
      -- as normal.  And yes, i have put waaaay too
      -- much effort into making this comment be
      -- almost a rectangular box :)
      mt = mt or {}
 
      return mt.__name or mt.__type or old_type(obj)
    else
      return old_type(obj)
    end
  end

  -- ok time for cursed shit: aliasing one type to another
  -- i will at least blacklist the default Lua types
  local cannot_alias = {
    string = true,
    number = true,
    boolean = true,
    ["nil"] = true,
    ["function"] = true,
    table = true,
    userdata = true
  }
  local defs = {}
  
  -- ex. typedef("number", "int")
  function _G.typedef(t1, t2)
    checkArg(1, t1, "string")
    checkArg(2, t2, "string")
  
    if cannot_alias[t2] then
      error("attempt to override default type")
    end

    if defs[t2] then
      error("cannot override existing typedef")
    end
    
    defs[t2] = t1
    
    return true
  end

  -- copied from machine.lua
  function _G.checkArg(n, have, ...)
    have = type(have)
    
    local function check(want, ...)
      if not want then
        return false
      else
        return have == want or defs[want] == have or check(...)
      end
    end
    
    if not check(...) then
      local msg = string.format("bad argument #%d (%s expected, got %s)",
                                n, table.concat(table.pack(...), " or "), have)
      error(msg, 3)
    end
  end
end
--#include "base/types.lua"
-- binary struct
-- note that to make something unsigned you ALWAYS prefix the type def with
-- 'u' rather than 'unsigned ' due to Lua syntax limitations.
-- ex:
-- local example = struct {
--   uint16("field_1"),
--   string[8]("field_2")
-- }
-- local copy = example "\0\14A string"
-- yes, there is lots of metatable hackery behind the scenes

k.log(k.loglevels.info, "ksrc/struct")

do
  -- step 1: change the metatable of _G so we can have convenient type notation
  -- without technically cluttering _G
  local gmt = {}
  
  local types = {
    int = "i",
    uint = "I",
    bool = "b", -- currently booleans are just signed 8-bit values because reasons
    short = "h",
    ushort = "H",
    long = "l",
    ulong = "L",
    size_t = "T",
    float = "f",
    double = "d",
    lpstr = "s",
  }

  -- char is a special case:
  --   - the user may want a single byte (char("field"))
  --   - the user may also want a fixed-length string (char[42]("field"))
  local char = {}
  setmetatable(char, {
    __call = function(field)
      return {fmtstr = "B", field = field}
    end,
    __index = function(t, k)
      if type(k) == "number" then
        return function(value)
          return {fmtstr = "c" .. k, field = value}
        end
      else
        error("invalid char length specifier")
      end
    end
  })

  function gmt.__index(t, k)
    if k == "char" then
      return char
    else
      local tp
  
      for t, v in pairs(types) do
        local match = k:match("^"..t)
        if match then tp = t break end
      end
      
      if not tp then return nil end
      
      return function(value)
        return {fmtstr = types[tp] .. tonumber(k:match("%d+$") or "0")//8,
          field = value}
      end
    end
  end

  -- step 2: change the metatable of string so we can have string length
  -- notation.  Note that this requires a null-terminated string.
  local smt = {}

  function smt.__index(t, k)
    if type(k) == "number" then
      return function(value)
        return {fmtstr = "z", field = value}
      end
    end
  end

  -- step 3: apply these metatable hacks
  setmetatable(_G, gmt)
  setmetatable(string, smt)

  -- step 4: ???

  -- step 5: profit

  function struct(fields, name)
    checkArg(1, fields, "table")
    checkArg(2, name, "string", "nil")
    
    local pat = "<"
    local args = {}
    
    for i=1, #fields, 1 do
      local v = fields[i]
      pat = pat .. v.fmtstr
      args[i] = v.field
    end
  
    return setmetatable({}, {
      __call = function(_, data)
        assert(type(data) == "string" or type(data) == "table",
          "bad argument #1 to struct constructor (string or table expected)")
    
        if type(data) == "string" then
          local set = table.pack(string.unpack(pat, data))
          local ret = {}
        
          for i=1, #args, 1 do
            ret[args[i]] = set[i]
          end
          
          return ret
        elseif type(data) == "table" then
          local set = {}
          
          for i=1, #args, 1 do
            set[i] = data[args[i]]
          end
          
          return string.pack(pat, table.unpack(set))
        end
      end,
      __len = function()
        return string.packsize(pat)
      end,
      __name = name or "struct"
    })
  end
end
--#include "base/struct.lua"
-- system log API hook for userspace

k.log(k.loglevels.info, "base/syslog")

do
  local mt = {
    __name = "syslog"
  }

  local syslog = {}
  local open = {}

  function syslog.open(pname)
    checkArg(1, pname, "string", "nil")

    pname = pname or k.scheduler.info().name

    local n = math.random(1, 999999999)
    open[n] = pname
    
    return n
  end

  function syslog.write(n, ...)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    k.log(k.loglevels.info, open[n] .. ":", ...)

    return true
  end

  function syslog.close(n)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    open[n] = nil

    return true
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.syslog = k.util.copy_table(syslog)
  end)
end
--#include "base/syslog.lua"
-- wrap load() to forcibly insert yields --

k.log(k.loglevels.info, "base/load")

if (not k.cmdline.no_force_yields) then
  local patterns = {
    { "if([ %(])(.-)([ %)])then([ \n])", "if%1%2%3then%4__internal_yield() " },
    { "elseif([ %(])(.-)([ %)])then([ \n])", "elseif%1%2%3then%4__internal_yield() " },
    { "([ \n])else([ \n])", "%1else%2__internal_yield() " },
    { "while([ %(])(.-)([ %)])do([ \n])", "while%1%2%3do%4__internal_yield() " },
    { "for([ %(])(.-)([ %)])do([ \n])", "for%1%2%3do%4__internal_yield() " },
    { "repeat([ \n])", "repeat%1__internal_yield() " },
  }

  local old_load = load

  local max_time = tonumber(k.cmdline.max_process_time) or 0.5

  local function process_section(s)
    for i=1, #patterns, 1 do
      s = s:gsub(patterns[i][1], patterns[i][2])
    end
    return s
  end

  local function process(chunk)
    local i = 1
    local ret = ""
    local nq = 0
    local in_blocks = {}
    while true do
      local nextquote = chunk:find("[^\\][\"']", i)
      if nextquote then
        local ch = chunk:sub(i, nextquote)
        i = nextquote + 1
        nq = nq + 1
        if nq % 2 == 1 then
          ch = process_section(ch)
        end
        ret = ret .. ch
      else
        local nbs, nbe = chunk:find("%[=*%[", i)
        if nbs and nbe then
          ret = ret .. process_section(chunk:sub(i, nbs - 1))
          local match = chunk:find("%]" .. ("="):rep((nbe - nbs) - 1) .. "%]")
          if not match then
            -- the Lua parser will error here, no point in processing further
            ret = ret .. chunk:sub(nbs)
            break
          end
          local ch = chunk:sub(nbs, match)
          ret = ret .. ch --:sub(1,-2)
          i = match + 1
        else
          ret = ret .. process_section(chunk:sub(i))
          i = #chunk
          break
        end
      end
    end

    if i < #chunk then ret = ret .. process_section(chunk:sub(i)) end

    return ret
  end

  function _G.load(chunk, name, mode, env)
    checkArg(1, chunk, "function", "string")
    checkArg(2, name, "string", "nil")
    checkArg(3, mode, "string", "nil")
    checkArg(4, env, "table", "nil")

    local data = ""
    if type(chunk) == "string" then
      data = chunk
    else
      repeat
        local ch = chunk()
        data = data .. (ch or "")
      until not ch
    end

    chunk = process(chunk)

    if k.cmdline.debug_load then
      local handle = io.open("/load.txt", "a")
      handle:write(" -- load: ", name or "(no name)", " --\n", chunk)
      handle:close()
    end

    env = env or k.userspace or _G

    local ok, err = old_load(chunk, name, mode, env)
    if not ok then
      return nil, err
    end
    return function(...)
      local last_yield = computer.uptime()
      local old_iyield = env.__internal_yield
      local old_cyield = env.coroutine.yield
      
      env.__internal_yield = function()
        if computer.uptime() - last_yield >= max_time then
          last_yield = computer.uptime()
          coroutine.yield(0.05)
        end
      end
      
      env.coroutine.yield = function(...)
        last_yield = computer.uptime()
        coroutine.yield(...)
      end
      
      local result = table.pack(ok(...))
      env.__internal_yield = old_iyield
      env.coroutine.yield = old_cyield

      return table.unpack(result)
    end
  end
end
--#include "base/load.lua"
-- thread: wrapper around coroutines

k.log(k.loglevels.info, "base/thread")

do
  local function handler(err)
    return debug.traceback(err, 3)
  end

  local old_coroutine = coroutine
  local _coroutine = {}
  _G.coroutine = _coroutine
  
  function _coroutine.create(func)
    checkArg(1, func, "function")
  
    return setmetatable({
      __thread = old_coroutine.create(function()
        return select(2, k.util.lassert(xpcall(func, handler)))
      end)
    }, {
      __index = _coroutine,
      __name = "thread"
    })
  end

  function _coroutine.wrap(fnth)
    checkArg(1, fnth, "function", "thread")
    
    if type(fnth) == "function" then fnth = _coroutine.create(fnth) end
    
    return function(...)
      return select(2, fnth:resume(...))
    end
  end

  function _coroutine:resume(...)
    return old_coroutine.resume(self.__thread, ...)
  end

  function _coroutine:status()
    return old_coroutine.status(self.__thread)
  end

  for k,v in pairs(old_coroutine) do
    _coroutine[k] = _coroutine[k] or v
  end
end
--#include "base/thread.lua"
-- processes
-- mostly glorified coroutine sets

k.log(k.loglevels.info, "base/process")

do
  local process = {}
  local proc_mt = {
    __index = process,
    __name = "process"
  }

  function process:resume(...)
    local result
    for k, v in ipairs(self.threads) do
      result = result or table.pack(v:resume(...))
  
      if v:status() == "dead" then
        table.remove(self.threads, k)
      
        if not result[1] then
          self:push_signal("thread_died", v.id)
        
          return nil, result[2]
        end
      end
    end

    if not next(self.threads) then
      self.dead = true
    end
    
    return table.unpack(result)
  end

  local id = 0
  function process:add_thread(func)
    checkArg(1, func, "function")
    
    local new = coroutine.create(func)
    
    id = id + 1
    new.id = id
    
    self.threads[#self.threads + 1] = new
    
    return id
  end

  function process:status()
    return self.coroutine:status()
  end

  local c_pushSignal = computer.pushSignal
  
  function process:push_signal(...)
    local signal = table.pack(...)
    table.insert(self.queue, signal)
    return true
  end

  -- there are no timeouts, the scheduler manages that
  function process:pull_signal()
    if #self.queue > 0 then
      return table.remove(self.queue, 1)
    end
  end

  local pid = 0

  -- default signal handlers
  local defaultHandlers = {
    [0] = function() end,
    [1] = function(self) self.status = "" self.dead = true end,
    [2] = function(self) self.status = "interrupted" self.dead = true end,
    [9] = function(self) self.dead = true end,
    [18] = function(self) self.stopped = true end,
  }
  
  function k.create_process(args)
    pid = pid + 1
  
    local new
    new = setmetatable({
      name = args.name,
      pid = pid,
      io = {
        stdin = args.stdin or {},
        input = args.input or args.stdin or {},
        stdout = args.stdout or {},
        output = args.output or args.stdout or {},
        stderr = args.stderr or args.stdout or {}
      },
      queue = {},
      threads = {},
      waiting = true,
      stopped = false,
      handles = {},
      coroutine = {},
      cputime = 0,
      deadline = 0,
      env = args.env and k.util.copy_table(args.env) or {},
      signal = setmetatable({}, {
        __call = function(_, self, s)
          -- don't block SIGSTOP or SIGCONT
          if s == 17 or s == 19 then
            self.stopped = s == 17
            return true
          end
          -- and don't block SIGKILL, unless we're init
          if self.pid ~= 1 and s == 9 then
            self.status = "killed" self.dead = true return true end
          if self.signal[s] then
            return self.signal[s](self)
          else
            return (defaultHandlers[s] or defaultHandlers[0])(self)
          end
        end,
        __index = defaultHandlers
      })
    }, proc_mt)
    
    args.stdin, args.stdout, args.stderr,
                  args.input, args.output = nil, nil, nil, nil, nil
    
    for k, v in pairs(args) do
      new[k] = v
    end

    new.handles[0] = new.stdin
    new.handles[1] = new.stdout
    new.handles[2] = new.stderr
    
    new.coroutine.status = function(self)
      if self.dead then
        return "dead"
      elseif self.stopped then
        return "stopped"
      elseif self.waiting then
        return "waiting"
      else
        return "running"
      end
    end
    
    return new
  end
end
--#include "base/process.lua"
-- scheduler

k.log(k.loglevels.info, "base/scheduler")

do
  local processes = {}
  local current

  local api = {}

  api.signals = {
    hangup = 1,
    interrupt = 2,
    kill = 9,
    stop = 17,
    kbdstop = 18,
    continue = 19
  }

  function api.spawn(args)
    checkArg(1, args.name, "string")
    checkArg(2, args.func, "function")
    
    local parent = processes[current or 0] or
      (api.info() and api.info().data.self) or {}
    
    local new = k.create_process {
      name = args.name,
      parent = parent.pid or 0,
      stdin = parent.stdin or (io and io.input()) or args.stdin,
      stdout = parent.stdout or (io and io.output()) or args.stdout,
      stderr = args.stderr or parent.stderr or (io and io.stderr),
      input = args.input or parent.stdin or (io and io.input()),
      output = args.output or parent.stdout or (io and io.output()),
      owner = args.owner or parent.owner or 0,
      env = setmetatable(args.env or {}, {__index = parent.env,
        __metatable = {}})
    }

    -- this is kind of ugly, but it works
    new.env.TERM = new.env.TERM or "cynosure"
    
    new:add_thread(args.func)
    processes[new.pid] = new
    
    if k.sysfs then
      assert(k.sysfs.register(k.sysfs.types.process, new, "/proc/"..math.floor(
        new.pid)))
    end
    
    return new
  end

  function api.info(pid)
    checkArg(1, pid, "number", "nil")
    
    pid = pid or current
    
    local proc = processes[pid]
    if not proc then
      return nil, "no such process"
    end

    local info = {
      pid = proc.pid,
      name = proc.name,
      waiting = proc.waiting,
      stopped = proc.stopped,
      deadline = proc.deadline,
      n_threads = #proc.threads,
      status = proc:status(),
      cputime = proc.cputime,
      owner = proc.owner
    }
    
    if proc.pid == current then
      info.data = {
        io = proc.io,
        self = proc,
        handles = proc.handles,
        coroutine = proc.coroutine,
        env = proc.env
      }
    end
    
    return info
  end

  function api.kill(proc, signal)
    checkArg(1, proc, "number", "nil")
    checkArg(2, signal, "number")
    
    proc = proc or current.pid
    
    if not processes[proc] then
      return nil, "no such process"
    end
    
    processes[proc]:signal(signal)
    
    return true
  end

  -- XXX: this is specifically for kernel use ***only*** - userspace does NOT
  -- XXX: get this function.  it is incredibly dangerous and should be used with
  -- XXX: the utmost caution.
  api.processes = processes
  function api.get(pid)
    checkArg(1, pid, "number", current and "nil")
    pid = pid or current
    if not processes[pid] then
      return nil, "no such process"
    end
    return processes[pid]
  end

  local function handleDeath(proc, exit, err, ok)
    local exit = err or 0
    err = err or ok

    if type(err) == "string" then
      exit = 127
    else
      exit = err or 0
      err = "exited"
    end

    err = err or "died"
    if (k.cmdline.log_process_death and
        k.cmdline.log_process_death ~= 0) then
      -- if we can, put the process death info on the same stderr stream
      -- belonging to the process that died
      if proc.io.stderr and proc.io.stderr.write then
        local old_logio = k.logio
        k.logio = proc.io.stderr
        k.log(k.loglevels.info, "process died:", proc.pid, exit, err)
        k.logio = old_logio
      else
        k.log(k.loglevels.warn, "process died:", proc.pid, exit, err)
      end
    end

    computer.pushSignal("process_died", proc.pid, exit, err)

    for k, v in pairs(proc.handles) do
      pcall(v.close, v)
    end

    local ppt = "/proc/" .. math.floor(proc.pid)
    if k.sysfs then
      k.sysfs.unregister(ppt)
    end
    processes[proc.pid] = nil
  end

  local pullSignal = computer.pullSignal
  function api.loop()
    while next(processes) do
      local to_run = {}
      local going_to_run = {}
      local min_timeout = math.huge
    
      for _, v in pairs(processes) do
        if not v.stopped then
          min_timeout = math.min(min_timeout, v.deadline - computer.uptime())
        end
      
        if min_timeout <= 0 then
          min_timeout = 0
          break
        end
      end
      
      --k.log(k.loglevels.info, min_timeout)
      
      local sig = table.pack(pullSignal(min_timeout))
      k.event.handle(sig)

      for _, v in pairs(processes) do
        if (v.deadline <= computer.uptime() or #v.queue > 0 or sig.n > 0) and
            not (v.stopped or going_to_run[v.pid] or v.dead) then
          to_run[#to_run + 1] = v
      
          if v.resume_next then
            to_run[#to_run + 1] = v.resume_next
            going_to_run[v.resume_next.pid] = true
          end
        elseif v.dead then
          handleDeath(v, v.exit_code or 1, v.status or "Killed")
        end
      end

      for i, proc in ipairs(to_run) do
        local psig = sig
        current = proc.pid
      
        if #proc.queue > 0 then
          -- the process has queued signals
          -- but we don't want to drop this signal
          proc:push_signal(table.unpack(sig))
          
          psig = proc:pull_signal() -- pop a signal
        end
        
        local start_time = computer.uptime()
        local aok, ok, err = proc:resume(table.unpack(psig))

        if proc.dead or ok == "__internal_process_exit" or not aok then
          handleDeath(proc, exit, err, ok)
        else
          proc.cputime = proc.cputime + computer.uptime() - start_time
          proc.deadline = computer.uptime() + (tonumber(ok) or tonumber(err)
            or math.huge)
        end
      end
    end

    if not k.is_shutting_down then
      -- !! PANIC !!
      k.panic("all user processes died")
    end
  end

  k.scheduler = api

  k.hooks.add("shutdown", function()
    if not k.is_shutting_down then
      return
    end

    k.log(k.loglevels.info, "shutdown: sending shutdown signal")

    for pid, proc in pairs(processes) do
      proc:resume("shutdown")
    end

    k.log(k.loglevels.info, "shutdown: waiting 1s for processes to exit")
    os.sleep(1)

    k.log(k.loglevels.info, "shutdown: killing all processes")

    for pid, proc in pairs(processes) do
      if pid ~= current then -- hack to make sure shutdown carries on
        proc.dead = true
      end
    end

    coroutine.yield(0) -- clean up
  end)
  
  -- sandbox hook for userspace 'process' api
  k.hooks.add("sandbox", function()
    local p = {}
    k.userspace.package.loaded.process = p
    
    function p.spawn(args)
      checkArg(1, args.name, "string")
      checkArg(2, args.func, "function")
    
      local sanitized = {
        func = args.func,
        name = args.name,
        stdin = args.stdin,
        stdout = args.stdout,
        input = args.input,
        output = args.output,
        stderr = args.stderr,
      }
      
      local new = api.spawn(sanitized)
      
      return new.pid
    end
    
    function p.kill(pid, signal)
      checkArg(1, pid, "number", "nil")
      checkArg(2, signal, "number")
      
      local cur = current
      local atmp = processes[pid]
      
      if not atmp then
        return true
      end
      
      if (atmp or {owner=current.owner}).owner ~= cur.owner and
         cur.owner ~= 0 then
        return nil, "permission denied"
      end
      
      return api.kill(pid, signal)
    end
    
    function p.list()
      local pr = {}
      
      for k, v in pairs(processes) do
        pr[#pr+1]=k
      end
      
      table.sort(pr)
      return pr
    end

    -- this is not provided at the kernel level
    -- largely because there is no real use for it
    -- returns: exit status, exit message
    function p.await(pid)
      checkArg(1, pid, "number")
      
      local signal = {}
      
      if not processes[pid] then
        return nil, "no such process"
      end
      
      repeat
        -- busywait until the process dies
        signal = table.pack(coroutine.yield())
      until signal[1] == "process_died" and signal[2] == pid
      
      return signal[3], signal[4]
    end
    
    p.info = api.info

    p.signals = k.util.copy_table(api.signals)
  end)
end
--#include "base/scheduler.lua"
-- sysfs API --

k.log(k.loglevels.info, "sysfs/sysfs")

do
  local tree = {
    dir = true,
    components = {
      dir = true,
      ["by-address"] = {dir = true},
      ["by-type"] = {dir = true}
    },
    proc = {dir = true},
    dev = {
      dir = true,
      stdin = {
        dir = false,
        open = function()
          return io.stdin
        end
      },
      stdout = {
        dir = false,
        open = function()
          return io.stdout
        end
      },
      stderr = {
        dir = false,
        open = function()
          return io.stderr
        end
      },
    },
    mounts = {
      dir = false,
      read = function(h)
        if h.__read then
          return nil
        end

        local mounts = k.fs.api.mounts()
        local ret = ""
        
        for k, v in pairs(mounts) do
          ret = string.format("%s%s\n", ret, k..": "..v)
        end
        
        h.__read = true
        
        return ret
      end,
      write = function()
        return nil, "bad file descriptor"
      end
    }
  }

  local function find(f)
    if f == "/" or f == "" then
      return tree
    end

    local s = k.fs.split(f)
    local c = tree
    
    for i=1, #s, 1 do
      if s[i] == "dir" then
        return nil, k.fs.errors.file_not_found
      end
    
      if not c[s[i]] then
        return nil, k.fs.errors.file_not_found
      end

      c = c[s[i]]
    end

    return c
  end

  local obj = {}

  function obj:stat(f)
    checkArg(1, f, "string")
    
    local n, e = find(f)
    
    if n then
      return {
        permissions = 365,
        owner = 0,
        group = 0,
        lastModified = 0,
        size = 0,
        isDirectory = not not n.dir,
        type = n.dir and k.fs.types.directory or k.fs.types.special
      }
    else
      return nil, e
    end
  end

  function obj:touch()
    return nil, k.fs.errors.read_only
  end

  function obj:remove()
    return nil, k.fs.errors.read_only
  end

  function obj:list(d)
    local n, e = find(d)
    
    if not n then return nil, e end
    if not n.dir then return nil, k.fs.errors.not_a_directory end
    
    local f = {}
    
    for k, v in pairs(n) do
      if k ~= "dir" then
        f[#f+1] = tostring(k)
      end
    end
    
    return f
  end

  local function ferr()
    return nil, "bad file descriptor"
  end

  local function fclose(self)
    if self.closed then
      return ferr()
    end
    
    self.closed = true
  end

  function obj:open(f, m)
    checkArg(1, f, "string")
    checkArg(2, m, "string")
    
    local n, e = find(f)
    
    if not n then return nil, e end
    if n.dir then return nil, k.fs.errors.is_a_directory end

    if n.open then return n.open(m) end
    
    return {
      read = n.read or ferr,
      write = n.write or ferr,
      seek = n.seek or ferr,
      close = n.close or fclose
    }
  end

  obj.node = {getLabel = function() return "sysfs" end}

  -- now here's the API
  local api = {}
  api.types = {
    generic = "generic",
    process = "process",
    directory = "directory"
  }
  typedef("string", "SYSFS_NODE")

  local handlers = {}

  function api.register(otype, node, path)
    checkArg(1, otype, "SYSFS_NODE")
    assert(type(node) ~= "nil", "bad argument #2 (value expected, got nil)")
    checkArg(3, path, "string")

    if not handlers[otype] then
      return nil, string.format("sysfs: node type '%s' not handled", otype)
    end

    local segments = k.fs.split(path)
    local nname = segments[#segments]
    local n, e = find(table.concat(segments, "/", 1, #segments - 1))

    if not n then
      return nil, e
    end

    local nn, ee = handlers[otype](node)
    if not nn then
      return nil, ee
    end

    n[nname] = nn

    return true
  end

  function api.retrieve(path)
    checkArg(1, path, "string")
    return find(path)
  end

  function api.unregister(path)
    checkArg(1, path, "string")
    
    local segments = k.fs.split(path)
    local ppath = table.concat(segments, "/", 1, #segments - 1)
    
    local node = segments[#segments]
    if node == "dir" then
      return nil, k.fs.errors.file_not_found
    end

    local n, e = find(ppath)
    if not n then
      return nil, e
    end

    if not n[node] then
      return nil, fs.errors.file_not_found
    end

    n[node] = nil

    return true
  end
  
  function api.handle(otype, mkobj)
    checkArg(1, otype, "SYSFS_NODE")
    checkArg(2, mkobj, "function")

    api.types[otype] = otype
    handlers[otype] = mkobj

    return true
  end
  
  k.sysfs = api

  -- we have to hook this here since the root filesystem isn't mounted yet
  -- when the kernel reaches this point.
  k.hooks.add("sandbox", function()
    assert(k.fs.api.mount(obj, k.fs.api.types.NODE, "sys"))
    -- Adding the sysfs API to userspace is probably not necessary for most
    -- things.  If it does end up being necessary I'll do it.
    --k.userspace.package.loaded.sysfs = k.util.copy_table(api)
  end)
end

-- sysfs handlers

k.log(k.loglevels.info, "sysfs/handlers")

do
  local util = {}
  function util.mkfile(data)
    local data = data
    return {
      dir = false,
      read = function(self, n)
        self.__ptr = self.__ptr or 0
        if self.__ptr >= #data then
          return nil
        else
          self.__ptr = self.__ptr + n
          return data:sub(self.__ptr - n, self.__ptr)
        end
      end
    }
  end

  function util.fmkfile(tab, k, w)
    return {
      dir = false,
      read = function(self)
        if self.__read then
          return nil
        end

        self.__read = true
        return tostring(tab[k])
      end,
      write = w and function(self, d)
        tab[k] = tonumber(d) or d
      end or nil
    }
  end

  function util.fnmkfile(r, w)
    return {
      dir = false,
      read = function(s)
        if s.__read then
          return nil
        end

        s.__read = true
        return r()
      end,
      write = w
    }
  end

-- sysfs: Generic component handler

k.log(k.loglevels.info, "sysfs/handlers/generic")

do
  local function mknew(addr)
    return {
      dir = true,
      address = util.mkfile(addr),
      type = util.mkfile(component.type(addr)),
      slot = util.mkfile(tostring(component.slot(addr)))
    }
  end

  k.sysfs.handle("generic", mknew)
end
--#include "sysfs/handlers/generic.lua"
-- sysfs: Directory generator

k.log(k.loglevels.info, "sysfs/handlers/directory")

do
  local function mknew()
    return { dir = true }
  end

  k.sysfs.handle("directory", mknew)
end
--#include "sysfs/handlers/directory.lua"
-- sysfs: Process handler

k.log(k.loglevels.info, "sysfs/handlers/process")

do
  local function mknew(proc)
    checkArg(1, proc, "process")
    
    local base = {
      dir = true,
      handles = {
        dir = true,
      },
      cputime = util.fmkfile(proc, "cputime"),
      name = util.mkfile(proc.name),
      threads = util.fmkfile(proc, "threads"),
      owner = util.mkfile(tostring(proc.owner)),
      deadline = util.fmkfile(proc, "deadline"),
      stopped = util.fmkfile(proc, "stopped"),
      waiting = util.fmkfile(proc, "waiting"),
      status = util.fnmkfile(function() return proc.coroutine.status(proc) end)
    }

    local mt = {
      __index = function(t, k)
        k = tonumber(k) or k
        if not proc.handles[k] then
          return nil, k.fs.errors.file_not_found
        else
          return {dir = false, open = function(m)
            -- you are not allowed to access other
            -- people's files!
            return nil, "permission denied"
          end}
        end
      end,
      __pairs = function()
        return pairs(proc.handles)
      end
    }
    mt.__ipairs = mt.__pairs

    setmetatable(base.handles, mt)

    return base
  end

  k.sysfs.handle("process", mknew)
end
--#include "sysfs/handlers/process.lua"
-- sysfs: TTY device handling

k.log(k.loglevels.info, "sysfs/handlers/tty")

do
  local function mknew(tty)
    return {
      dir = false,
      read = function(_, n)
        return tty:read(n)
      end,
      write = function(_, d)
        return tty:write(d)
      end
    }
  end

  k.sysfs.handle("tty", mknew)

  k.sysfs.register("tty", k.logio, "/dev/console")
  k.sysfs.register("tty", k.logio, "/dev/tty0")
end
--#include "sysfs/handlers/tty.lua"

-- component-specific handlers
-- sysfs: GPU hander

k.log(k.loglevels.info, "sysfs/handlers/gpu")

do
  local function mknew(addr)
    local proxy = component.proxy(addr)
    local new = {
      dir = true,
      address = util.mkfile(addr),
      slot = util.mkfile(proxy.slot),
      type = util.mkfile(proxy.type),
      resolution = util.fnmkfile(
        function()
          return string.format("%d %d", proxy.getResolution())
        end,
        function(_, s)
          local w, h = s:match("(%d+) (%d+)")
        
          w = tonumber(w)
          h = tonumber(h)
        
          if not (w and h) then
            return nil
          end

          proxy.setResolution(w, h)
        end
      ),
      foreground = util.fnmkfile(
        function()
          return tostring(proxy.getForeground())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setForeground(s)
        end
      ),
      background = util.fnmkfile(
        function()
          return tostring(proxy.getBackground())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setBackground(s)
        end
      ),
      maxResolution = util.fnmkfile(
        function()
          return string.format("%d %d", proxy.maxResolution())
        end
      ),
      maxDepth = util.fnmkfile(
        function()
          return tostring(proxy.maxDepth())
        end
      ),
      depth = util.fnmkfile(
        function()
          return tostring(proxy.getDepth())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setDepth(s)
        end
      ),
      screen = util.fnmkfile(
        function()
          return tostring(proxy.getScreen())
        end,
        function(_, s)
          if not component.type(s) == "screen" then
            return nil
          end

          proxy.bind(s)
        end
      )
    }

    return new
  end

  k.sysfs.handle("gpu", mknew)
end
--#include "sysfs/handlers/gpu.lua"
-- sysfs: filesystem handler

k.log(k.loglevels.info, "sysfs/handlers/filesystem")

do
  local function mknew(addr)
    local proxy = component.proxy(addr)
    
    local new = {
      dir = true,
      address = util.mkfile(addr),
      slot = util.mkfile(proxy.slot),
      type = util.mkfile(proxy.type),
      label = util.fnmkfile(
        function()
          return proxy.getLabel() or "unlabeled"
        end,
        function(_, s)
          proxy.setLabel(s)
        end
      ),
      spaceUsed = util.fnmkfile(
        function()
          return string.format("%d", proxy.spaceUsed())
        end
      ),
      spaceTotal = util.fnmkfile(
        function()
          return string.format("%d", proxy.spaceTotal())
        end
      ),
      isReadOnly = util.fnmkfile(
        function()
          return tostring(proxy.isReadOnly())
        end
      ),
      mounts = util.fnmkfile(
        function()
          local mounts = k.fs.api.mounts()
          local ret = ""
          for k,v in pairs(mounts) do
            if v == addr then
              ret = ret .. k .. "\n"
            end
          end
          return ret
        end
      )
    }

    return new
  end

  k.sysfs.handle("filesystem", mknew)
end
--#include "sysfs/handlers/filesystem.lua"

-- component event handler
-- sysfs: component event handlers

k.log(k.loglevels.info, "sysfs/handlers/component")

do
  local n = {}
  local gpus, screens = {}, {}
  gpus[k.logio.gpu.address] = true
  screens[k.logio.gpu.getScreen()] = true

  local function update_ttys(a, c)
    if c == "gpu" then
      gpus[a] = gpus[a] or false
    elseif c == "screen" then
      screens[a] = screens[a] or false
    else
      return
    end

    for gk, gv in pairs(gpus) do
      if not gpus[gk] then
        for sk, sv in pairs(screens) do
          if not screens[sk] then
            k.log(k.loglevels.info, string.format(
              "Creating TTY on [%s:%s]", gk:sub(1, 8), (sk:sub(1, 8))))
            k.create_tty(gk, sk)
            gpus[gk] = true
            screens[sk] = true
            gv, sv = true, true
          end
        end
      end
    end
  end

  local function added(_, addr, ctype)
    n[ctype] = n[ctype] or 0

    k.log(k.loglevels.info, "Detected component:", addr .. ", type", ctype)
    
    local path = "/components/by-address/" .. addr:sub(1, 6)
    local path_ = "/components/by-type/" .. ctype
    local path2 = "/components/by-type/" .. ctype .. "/" .. n[ctype]
    
    n[ctype] = n[ctype] + 1

    if not k.sysfs.retrieve(path_) then
      k.sysfs.register("directory", true, path_)
    end

    local s = k.sysfs.register(ctype, addr, path)
    if not s then
      s = k.sysfs.register("generic", addr, path)
      k.sysfs.register("generic", addr, path2)
    else
      k.sysfs.register(ctype, addr, path2)
    end

    if ctype == "gpu" or ctype == "screen" then
      update_ttys(addr, ctype)
    end
    
    return s
  end

  local function removed(_, addr, ctype)
    local path = "/sys/components/by-address/" .. addr
    local path2 = "/sys/components/by-type/" .. addr
    k.sysfs.unregister(path2)
    return k.sysfs.unregister(path)
  end

  k.event.register("component_added", added)
  k.event.register("component_removed", removed)
end
--#include "sysfs/handlers/component.lua"

end -- sysfs handlers: Done
--#include "sysfs/handlers.lua"
--#include "sysfs/sysfs.lua"
-- base networking --

k.log(k.loglevels.info, "extra/net/base")

do
  local protocols = {}
  k.net = {}

  local ppat = "^(.-)://(.+)"

  function k.net.socket(url, ...)
    checkArg(1, url, "string")
    local proto, rest = url:match(ppat)
    if not proto then
      return nil, "protocol unspecified"
    elseif not protocols[proto] then
      return nil, "bad protocol: " .. proto
    end

    return protocols[proto].socket(proto, rest, ...)
  end

  function k.net.request(url, ...)
    checkArg(1, url, "string")
    local proto, rest = url:match(ppat)
    if not proto then
      return nil, "protocol unspecified"
    elseif not protocols[proto] then
      return nil, "bad protocol: " .. proto
    end

    return protocols[proto].request(proto, rest, ...)
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.network = k.util.copy_table(k.net)
  end)

-- internet component for the 'net' api --

k.log(k.loglevels.info, "extra/net/internet")

do
  local proto = {}

  local iaddr, ipx
  local function get_internet()
    if not (iaddr and component.methods(iaddr)) then
      iaddr = component.list("internet")()
    end
    if iaddr and ((ipx and ipx.address ~= iaddr) or not ipx) then
      ipx = component.proxy(iaddr)
    end
    return ipx
  end

  local _base_stream = {}

  function _base_stream:read(n)
    checkArg(1, n, "number")
    if not self.base then
      return nil, "_base_stream is closed"
    end
    local data = ""
    repeat
      local chunk = self.base.read(n - #data)
      data = data .. (chunk or "")
    until (not chunk) or #data == n
    if #data == 0 then return nil end
    return data
  end

  function _base_stream:write(data)
    checkArg(1, data, "string")
    if not self.base then
      return nil, "_base_stream is closed"
    end
    while #data > 0 do
      local written, err = self.base.write(data)
      if not written then
        return nil, err
      end
      data = data:sub(written + 1)
    end
    return true
  end

  function _base_stream:close()
    if self._base_stream then
      self._base_stream.close()
      self._base_stream = nil
    end
    return true
  end

  function proto:socket(url, port)
    local inetcard = get_internet()
    if not inetcard then
      return nil, "no internet card installed"
    end
    local base, err = inetcard._base_stream(self .. "://" .. url, port)
    if not base then
      return nil, err
    end
    return setmetatable({base = base}, {__index = _base_stream})
  end

  function proto:request(url, data, headers, method)
    checkArg(1, url, "string")
    checkArg(2, data, "string", "table", "nil")
    checkArg(3, headers, "table", "nil")
    checkArg(4, method, "string", "nil")

    local inetcard = get_internet()
    if not inetcard then
      return nil, "no internet card installed"
    end

    local post
    if type(data) == "string" then
      post = data
    elseif type(data) == "table" then
      for k,v in pairs(data) do
        post = (post and (post .. "&") or "")
          .. tostring(k) .. "=" .. tostring(v)
      end
    end

    local base, err = inetcard.request(self .. "://" .. url, post, headers, method)
    if not base then
      return nil, err
    end

    local ok, err
    repeat
      ok, err = base.finishConnect()
    until ok or err
    if not ok then return nil, err end

    return setmetatable({base = base}, {__index = _base_stream})
  end

  protocols.https = proto
  protocols.http = proto
end
  --#include "extra/net/internet.lua"
end
--#include "extra/net/base.lua"
--#include "includes.lua"
-- load /etc/passwd, if it exists

k.log(k.loglevels.info, "base/passwd_init")

k.hooks.add("rootfs_mounted", function()
  local p1 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+):([^:]+):([^:]+)"
  local p2 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+):([^:]+)"
  local p3 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+)"

  k.log(k.loglevels.info, "Reading /etc/passwd")

  local handle, err = io.open("/etc/passwd", "r")
  if not handle then
    k.log(k.loglevels.info, "Failed opening /etc/passwd:", err)
  else
    local data = {}
    
    for line in handle:lines("l") do
      -- user ID, user name, password hash, ACLs, home directory,
      -- preferred shell
      local uid, uname, pass, acls, home, shell
      uid, uname, pass, acls, home, shell = line:match(p1)
      if not uid then
        uid, uname, pass, acls, home = line:match(p2)
      end
      if not uid then
        uid, uname, pass, acls = line:match(p3)
      end
      uid = tonumber(uid)
      if not uid then
        k.log(k.loglevels.info, "Invalid line:", line, "- skipping")
      else
        data[uid] = {
          name = uname,
          pass = pass,
          acls = tonumber(acls),
          home = home,
          shell = shell
        }
      end
    end
  
    handle:close()
  
    k.log(k.loglevels.info, "Registering user data")
  
    k.security.users.prime(data)

    k.log(k.loglevels.info,
      "Successfully registered user data from /etc/passwd")
  end

  k.hooks.add("shutdown", function()
    k.log(k.loglevels.info, "Saving user data to /etc/passwd")
    local handle, err = io.open("/etc/passwd", "w")
    if not handle then
      k.log(k.loglevels.warn, "failed saving /etc/passwd:", err)
      return
    end
    for k, v in pairs(k.passwd) do
      local data = string.format("%d:%s:%s:%d:%s:%s\n",
        k, v.name, v.pass, v.acls, v.home or ("/home/"..v.name),
        v.shell or "/bin/lsh")
      handle:write(data)
    end
    handle:close()
  end)
end)
--#include "base/passwd_init.lua"
-- load init, i guess

k.log(k.loglevels.info, "base/load_init")

-- we need to mount the root filesystem first
do
  if _G.__mtar_fs_tree then
    k.log(k.loglevels.info, "using MTAR filesystem tree as rootfs")
    k.fs.api.mount(__mtar_fs_tree, k.fs.api.types.NODE, "/")
  else
    local root, reftype = nil, "UUID"
    
    if k.cmdline.root then
      local rtype, ref = k.cmdline.root:match("^(.-)=(.+)$")
      reftype = rtype:upper() or "UUID"
      root = ref or k.cmdline.root
    elseif not computer.getBootAddress then
      -- still error, but slightly less hard
      k.panic("Cannot determine root filesystem!")
    else
      k.log(k.loglevels.warn,
        "\27[101;97mWARNING\27[39;49m use of computer.getBootAddress to detect the root filesystem is discouraged.")
      k.log(k.loglevels.warn,
        "\27[101;97mWARNING\27[39;49m specify root=UUID=<address> on the kernel command line to suppress this message.")
      root = computer.getBootAddress()
      reftype = "UUID"
    end
  
    local ok, err
    
    if reftype ~= "LABEL" then
      if reftype ~= "UUID" then
        k.log(k.loglevels.warn, "invalid rootspec type (expected LABEL or UUID, got ", reftype, ") - assuming UUID")
      end
    
      if not component.list("filesystem")[root] then
        for k, v in component.list("drive", true) do
          local ptable = k.fs.get_partition_table_driver(k)
      
          if ptable then
            for i=1, #ptable:list(), 1 do
              local part = ptable:partition(i)
          
              if part and (part.address == root) then
                root = part
                break
              end
            end
          end
        end
      end
  
      ok, err = k.fs.api.mount(root, k.fs.api.types.RAW, "/")
    elseif reftype == "LABEL" then
      local comp
      
      for k, v in component.list() do
        if v == "filesystem" then
          if component.invoke(k, "getLabel") == root then
            comp = root
            break
          end
        elseif v == "drive" then
          local ptable = k.fs.get_partition_table_driver(k)
      
          if ptable then
            for i=1, #ptable:list(), 1 do
              local part = ptable:partition(i)
          
              if part then
                if part.getLabel() == root then
                  comp = part
                  break
                end
              end
            end
          end
        end
      end
  
      if not comp then
        k.panic("Could not determine root filesystem from root=", k.cmdline.root)
      end
      
      ok, err = k.fs.api.mount(comp, k.fs.api.types.RAW, "/")
    end
  
    if not ok then
      k.panic(err)
    end
  end

  k.log(k.loglevels.info, "Mounted root filesystem")
  
  k.hooks.call("rootfs_mounted")

  -- mount the tmpfs
  k.fs.api.mount(component.proxy(computer.tmpAddress()), k.fs.api.types.RAW, "/tmp")
end

-- register components with the sysfs, if possible
do
  for k, v in component.list("carddock") do
    component.invoke(k, "bindComponent")
  end

  k.log(k.loglevels.info, "Registering components")
  for kk, v in component.list() do
    computer.pushSignal("component_added", kk, v)
   
    repeat
      local x = table.pack(computer.pullSignal())
      k.event.handle(x)
    until x[1] == "component_added"
  end
end

do
  k.log(k.loglevels.info, "Creating userspace sandbox")
  
  local sbox = k.util.copy_table(_G)
  
  k.userspace = sbox
  sbox._G = sbox
  
  k.hooks.call("sandbox", sbox)

  k.log(k.loglevels.info, "Loading init from",
                               k.cmdline.init or "/sbin/init.lua")
  
  local ok, err = loadfile(k.cmdline.init or "/sbin/init.lua")
  
  if not ok then
    k.panic(err)
  end
  
  local ios = k.create_fstream(k.logio, "rw")
  ios.buffer_mode = "none"
  
  k.scheduler.spawn {
    name = "init",
    func = ok,
    input = ios,
    output = ios,
    stderr = ios
  }

  k.log(k.loglevels.info, "Starting scheduler loop")
  k.scheduler.loop()
end
--#include "base/load_init.lua"
k.panic("Premature exit!")
]=======]

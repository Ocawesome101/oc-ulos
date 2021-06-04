-- buildfile

local OS = "ULOS"
local REL = os.date("%y.%m").."-pre4"

local seq = {
  {name = "cynosure", flags = ""},
  {name = "refinement", flags = ""}
}

local extern = {
  "coresvc",
  "corelibs",
  "coreutils",
}

local build = function(dir)
  log("err", "building sub-project ", dir.name)
  io.write(assert(ex("cd", dir.name, "; OS='"..OS.." "..REL.."'",
    dir.flags, "../build")))
end

_G.main = function(args)
  for k,v in pairs(args) do args[v] = true end
  if args.help or args["--help"] then
    io.stderr:write("\
usage: \27[96mbuild \27[93mOPTIONS\27[39m\
Assembles ULOS.  \27[93mOPTIONS\27[39m should not be prefixed with a \27[91m--\27[39m.\
\
Available \27[93mOPTIONS\27[39m:\
  \27[33mnomanual\27[39m:   do not include manual pages in the build.  reduces output size by about 100KB.\
  \27[33mrelease\27[39m:    create a bootable MTAR archive (release image)\
  \27[33mhelp\27[39m:       display this help.\
  \27[33mocvm\27[39m:       automatically execute 'ocvm ..' when the build is complete.  used for my personal development setup.\
")
    os.exit(1)
  end
  log("err", "Assembling ULOS")
  for _, dir in ipairs(seq) do
    build(dir)
  end
  ex("rm -rv out")
  ex("mkdir -p out/sbin")
  ex("cp cynosure/kernel.lua out/init.lua")
  ex("cp refinement/refinement.lua out/sbin/init.lua")
  if not args.nomanual then
    extern[#extern+1] = "manpages"
  end

  for _, file in ipairs(extern) do
    ex("cp -rv", "external/"..file.."/*", "out/")
  end
  ex("cd tle; ./standalone.sh; cp tle ../out/bin/tle.lua")
  ex("mkdir out/usr/share -p; cp -r tle/syntax out/usr/share/VLE")
  log("err", "ULOS assembled")
  if args.release then
    log("err, Creating MTAR archive")
    if os.getenv("TERM") == "cynosure" then
      ex("mtar --output=release.mtar (find out/)")
      ex("into release.lua (cat cynosure/mtarldr.lua cynosure/mtarldr_2.lua release.mtar)")
    else
      ex("find out -type f | utils/mtar.lua > release.mtar")
      ex("cat cynosure/mtarldr.lua release.mtar cynosure/mtarldr_2.lua > release.lua")
    end
  end
  if args.ocvm then
    os.execute("ocvm ..")
  end
end

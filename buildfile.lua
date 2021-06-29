-- buildfile

local OS = "ULOS"
local REL = os.date("%y.%m").."-1.1"

local seq = {
  {name = "cynosure", flags = "KMODS=extra/net/base"},
  {name = "refinement", flags = ""}
}

local extern = {
  "cldr",
  "coresvc",
  "corelibs",
  "coreutils",
}

local build = function(dir)
  log("err", "building sub-project ", dir.name)
  ex("cd", dir.name, "; OS='"..OS.." "..REL.."'",
    dir.flags, "../build; cd ..")
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
  \27[33mnoupm\27[39m:      do not include UPM in the build.\
  \27[33mnorebuild\27[39m:  do not rebuild the system before performing further actions.\
  \27[33mrelease\27[39m:    create a bootable MTAR archive (release image)\
  \27[33mpkg\27[39m:        create the various MTAR packages used for installation with UPM\
  \27[33mhelp\27[39m:       display this help.\
  \27[33mocvm\27[39m:       automatically execute 'ocvm ..' when the build is complete.  used for my personal development setup.\
")
    os.exit(1)
  end
  if not args.norebuild then
    log("err", "Assembling ULOS")
    for _, dir in ipairs(seq) do
      build(dir)
    end
    ex("rm -rv out")
    ex("mkdir -p out out/sbin out/boot")
    ex("cp cynosure/kernel.lua out/boot/cynosure.lua")
    ex("cp refinement/refinement.lua out/sbin/init.lua")
    if not args.nomanual then
      extern[#extern+1] = "manpages"
    end
    if not args.noupm then
      extern[#extern+1] = "upm"
    end
  
    for _, file in ipairs(extern) do
      if os.getenv("TERM") == "cynosure" then
        local p = "external/" .. file .. "/"
        for f in require("lfs").dir(p) do
          ex("cp -rv", p .. f, "out/" .. f)
        end
      else
        ex("cp -rv", "external/"..file.."/*", "out/")
      end
    end
    ex("cd tle; ./standalone.lua; cp tle ../out/bin/tle.lua; cd ..")
    ex("mkdir out/usr/share -p; cp -r tle/syntax out/usr/share/VLE")
    ex("mkdir out/root")
    ex("cp external/motd.txt out/etc/")
    log("err", "ULOS assembled")
  end
  if args.release then
    log("err", "Creating MTAR archive")
    if os.getenv("TERM") == "cynosure" then
      ex("mtar --output=release.mtar (find out/)")
      ex("into -p release.lua cat cynosure/mtarldr.lua cynosure/mtarldr_2.lua release.mtar")
    else
      ex("find out -type f | utils/mtar.lua > release.mtar")
      ex("cat cynosure/mtarldr.lua release.mtar cynosure/mtarldr_2.lua > release.lua")
    end
    os.remove("release.mtar")
  end
  if args.pkg then
    log("err", "Creating MTAR packages")
    ex("mkdir pkg")
    -- loader
    log("ok", "package: cldr")
    ex("find external/cldr -type f | sed 's/external\\/cldr/out/g' | utils/mtar.lua > pkg/cldr.mtar")
    -- kernel
    log("ok", "package: cynosure")
    ex("echo out/boot/cynosure.lua | utils/mtar.lua > pkg/cynosure.mtar")
    -- init + services
    log("ok", "package: refinement")
    ex("find external/coresvc out/sbin/init.lua -type f | sed 's/external\\/coresvc/out/g' | utils/mtar.lua > pkg/refinement.mtar")
    -- coreutils
    log("ok", "package: coreutils")
    ex("find external/coreutils out/etc/motd.txt -type f | grep -v install | sed 's/external\\/coreutils/out/g' | utils/mtar.lua > pkg/coreutils.mtar")
    -- corelibs
    log("ok", "package: corelibs")
    ex("find external/corelibs -type f | sed 's/external\\/corelibs/out/g' | utils/mtar.lua > pkg/corelibs.mtar")
    -- tle
    log("ok", "package: tle")
    ex("find out/usr/share out/bin/tle.lua -type f | utils/mtar.lua > pkg/tle.mtar")
    -- man pages
    log("ok", "package: manpages")
    ex("find external/manpages -type f | sed 's/external\\/manpages/out/g' | utils/mtar.lua > pkg/manpages.mtar")
    -- upm
    log("ok", "package: upm")
    ex("find external/upm -type f | sed 's/external\\/upm/out/g' | utils/mtar.lua > pkg/upm.mtar")
  end
  if args.ocvm then
    os.execute("ocvm ..")
  end
end

-- buildfile

local OS = "ULOS"
local REL = os.date("%y.%m").."-" .. (os.getenv("ULOSREL") or "1.5")

local seq = {
  {name = "cynosure", flags = ""},
  {name = "refinement", flags = ""}
}

if os.getenv("KMODS") then
  seq[1].flags = (os.getenv("KMOV") and "KMODS=" or (seq[1].flags .. ",")) .. os.getenv("KMODS")
end

local extern = {
  "cldr",
  "coresvc",
  "corelibs",
  "coreutils",
  "installer"
}

_G.env = {}

local build = function(dir)
  log("err", "building sub-project ", dir.name)
  ex("cd", dir.name, "; OS='"..OS.." "..REL.."' ULOSREL="..REL,
    dir.flags, table.concat(env, " "), "../build", dir.args or "", "; cd ..")
end

_G.main = function(args)
  for k,v in pairs(args) do
    v = tostring(v)
    if v:find("=") then
      env[#env+1] = v
    else
      args[v] = true
    end
  end

  if args.help or args["--help"] then
    io.stderr:write("\
usage: \27[96mbuild \27[93mOPTIONS\27[39m\
Assembles ULOS.  \27[93mOPTIONS\27[39m should not be prefixed with a \27[91m--\27[39m.\
Specify extra kernel modules with \27[97mKMODS\27[39m=\27[93mmod1,mod2,...\27[39m\
\
Available \27[93mOPTIONS\27[39m:\
  \27[33mnomanual\27[39m:   do not include manual pages in the build.  reduces output size by about 100KB.\
  \27[33mnoupm\27[39m:      do not include UPM in the build.\
  \27[33mnorebuild\27[39m:  do not rebuild the system before performing further actions.\
  \27[33mrelease\27[39m:    create a bootable MTAR archive (release image)\
  \27[33mhelp\27[39m:       display this help.\
  \27[33mwebman\27[39m:     generate manual pages in web format.\
  \27[33mocvm\27[39m:       automatically execute 'ocvm ..' when the build is complete.  used for my personal development setup.\
")
    os.exit(1)
  end

  if not args.norebuild then
    log("err", "Assembling ULOS")
    for _, dir in ipairs(seq) do
      build(dir)
    end
    ex("rm -r out")
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
          ex("cp -r", p .. f, "out/" .. f)
        end
      else
        ex("cp -r", "external/"..file.."/*", "out/")
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
  if args.webman then
    ex("utils/mkman.sh ", args.noupload and "" or "upload")
  end
  if args.ocvm then
    os.execute("ocvm ..")
  end
end

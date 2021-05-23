-- buildfile

local OS = "ULOS"
local REL = os.date("%y.%m").."-r0"

local seq = {
  {name = "cynosure", flags = ""},
  {name = "refinement", flags = ""}
}

local extern = {
  "coresvc",
  "corelibs",
  "coreutils"
}

local build = function(dir)
  log("err", "building sub-project ", dir.name)
  io.write(assert(ex("cd", dir.name, "; OS='"..OS.." "..REL.."'",
    dir.flags, "../build")))
end

_G.main = function(args)
  log("err", "Assembling ULOS")
  for _, dir in ipairs(seq) do
    build(dir)
  end
  ex("rm -rv out")
  ex("mkdir -p out/sbin")
  ex("cp cynosure/kernel.lua out/init.lua")
  ex("cp refinement/refinement.lua out/sbin/init.lua")
  for _, file in ipairs(extern) do
    ex("cp -rv", "external/"..file.."/*", "out/")
  end
  -- yep, this is cursed
  ex("cd tle; ./standalone.sh; cat tle | tail -n $(echo \"`wc -l tle | cut -d ' ' -f1` - 1\" | bc) > ../out/bin/tle.lua")
  log("err", "ULOS assembled")
  if args[1] == "ocvm" then
    os.execute( "ocvm ..")
  end
end

-- buildfile

local OS = "ULOS"
local REL = os.date("%y.%m").."-r0"

local seq = {
  "cynosure",
  "refinement"
}

local extern = {
  "coresvc",
  "corelibs",
  "coreutils"
}

local build = function(dir)
  log("err", "building sub-project ", dir)
  io.write(assert(ex("cd", dir, "; OS='"..OS.." "..REL.."' ../build")))
end

_G.main = function(args)
  log("err", "Assembling ULOS")
  for _, dir in ipairs(seq) do
    build(dir)
  end
  ex("rm -r out")
  ex("mkdir -p out/sbin")
  ex("cp cynosure/kernel.lua out/init.lua")
  ex("cp refinement/refinement.lua out/sbin/init.lua")
  for _, file in ipairs(extern) do
    ex("cp -rv", "external/"..file.."/*", "out/")
  end
  log("err", "ULOS assembled")
  if args[1] == "ocvm" then
    os.execute( "ocvm ..")
  end
end

-- buildfile

local seq = {
  "cynosure",
  "refinement"
}

local build = function(dir)
  log("err", "building sub-project ", dir)
  io.write(assert(ex("cd", dir, "; ../build")))
end

_G.main = function(...)
  log("err", "Assembling ULOS")
  for _, dir in ipairs(seq) do
    build(dir)
  end
  os.remove("out")
  ex("mkdir -p out/sbin")
  ex("cp cynosure/kernel.lua out/init.lua")
  ex("cp refinement/refinement.lua out/sbin/init.lua")
  log("err", "ULOS assembled")
  if (...) == "ocvm" then
    os.execute( "ocvm ..")
  end
end

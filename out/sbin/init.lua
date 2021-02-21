-- Refinement init system --

local rf = {}

-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "0"
  local version = "2021.02.21"
  rf._VERSION = string.format("%s r%s-%s", rf._NAME, rf._RELEASE, version)
end


-- logger --

do
  rf.prefix = {
    busy = "\27[97m[\27[94mbusy\27[97m] ",
    info = "\27[97m[\27[94minfo\27[97m] ",
    done = "\27[97m[\27[92mdone\27[97m] ",
    fail = "\27[97m[\27[91mfail\27[97m] ",
    warn = "\27[97m[\27[93mwarn\27[97m] "
  }
  function rf.log(...)
    io.write(...)
    io.write("\n")
  end

  rf.log(rf.prefix.info, "Starting \27[94m", rf._VERSION, "\27[97m")
end


-- service management --

rf.log(rf.prefix.info, "src/services")

do
  local running = {}
end


while true do coroutine.yield() end

-- Refinement init system --

local rf = {}

-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "0"
  local version = "2021.02.15"
  rf._VERSION = string.format("%s r%s-%s", rf._NAME, rf._RELEASE, version)
end


-- logger --

do
  rf.prefix = {
    busy = "\27[34mbusy\27[39m ",
    info = "\27[34minfo\27[39m ",
    done = "\27[32mdone\27[39m ",
    fail = "\27[31mfail\27[39m ",
    warn = "\27[33mwarn\27[39m"
  }
  function rf.log(...)
    io.write(...)
    io.write("\n")
  end

  k.log(k.loglevels.info, "REFINEMENT HAS STARTED")
  rf.log(rf.prefix.info, "Starting ", rf._VERSION)
end


-- service management --

do
end


while true do io.write("RF> ") io.read() end

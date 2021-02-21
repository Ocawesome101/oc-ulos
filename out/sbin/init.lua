-- Refinement init system --

local rf = {}

-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "0"
  rf._RUNNING_ON = "ULOS 21.02-r0"
  
  io.write("\n  \27[97mWelcome to \27[93m", rf._RUNNING_ON, "\27[97m!\n\n")
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


-- require function

rf.log(rf.prefix.busy, "src/require")

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

rf.log(rf.prefix.done, "src/require")


-- service management --

rf.log(rf.prefix.busy, "src/services")

do
  local process = require("process")
  local running = {}
end

rf.log(rf.prefix.done, "src/services")


while true do coroutine.yield() end

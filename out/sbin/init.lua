-- Refinement init system --

local rf = {}

-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "0"
  rf._RUNNING_ON = "ULOS 21.03-r0"
  
  io.write("\n  \27[97mWelcome to \27[93m", rf._RUNNING_ON, "\27[97m!\n\n")
  local version = "2021.03.23"
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
  local svdir = "/etc/rf/"

  local running = {}
  local sv = {up=true}
  
  local starting = {}
  sv.up = function(srv)
    checkArg(1, srv, "string")
    if starting[srv] then
      error("circular dependency detected")
    end
    local senv = setmetatable({needs=sv.up}, {__index=_G, __pairs=_G})
    local spath = string.format("%s/%s", svdir, srv)
    local ok, err = loadfile(svpath, nil, senv)
    if not ok then
      return nil, err
    end
    starting[srv] = true
    local st, rt = pcall(ok)
    if not st and rt then return nil, rt end
    if senv.start then pcall(senv.start) end
    running[srv] = senv
    return true
  end
  
  function sv.down(srv)
    checkArg(1, srv, "string")
    if not running[srv] then
      return true, "no such service"
    end
    if running[srv].stop then
      pcall(running[srv].stop)
    end
    running[srv] = nil
  end
  
  function sv.msg(srv, ...)
    checkArg(1, srv, "string")
    if running[srv] and running[srv].msg then
      return pcall(running[srv].msg, ...)
    end
    return true
  end
end

rf.log(rf.prefix.done, "src/services")


while true do coroutine.yield() end

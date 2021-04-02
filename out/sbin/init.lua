-- Refinement init system --

local rf = {}

-- versioning --

do
  rf._NAME = "Refinement"
  rf._RELEASE = "0"
  rf._RUNNING_ON = "ULOS 21.04-r0"
  
  io.write("\n  \27[97mWelcome to \27[93m", rf._RUNNING_ON, "\27[97m!\n\n")
  local version = "2021.04.02"
  rf._VERSION = string.format("%s r%s-%s", rf._NAME, rf._RELEASE, version)
end


-- logger --

do
  rf.prefix = {
    red = "\27[91m*\27[97m ",
    blue = "\27[94m*\27[97m ",
    green = "\27[92m*\27[97m ",
    yellow = "\27[93m*\27[97m "
  }
  function rf.log(...)
    io.write(...)
    io.write("\n")
  end

  rf.log(rf.prefix.blue, "Starting \27[94m", rf._VERSION, "\27[97m")
end


-- require function

rf.log(rf.prefix.green, "src/require")

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


local config = {}
do
  rf.log(rf.prefix.blue, "Loading service configuration")

  -- string -> boolean, number, or string
  local function coerce(val)
    if val == "true" then
      return true
    elseif val == "false" then
      return false
    elseif val == "nil" then
      return nil
    else
      return tonumber(val) or val
    end
  end

  local fs = require("filesystem")
  if fs.stat("/etc/rf.cfg") then
    local section
    for line in io.lines("/etc/rf.cfg") do
      if line:match("%[.+%]") then
        section = line:sub(2, -2)
        config[section] = config[section] or {}
      else
        local k, v = line:match("^(.-) = (.+)$")
        if k and v then
          if v:match("^%[.+%]$") then
            config[section][k] = {}
            for item in v:gmatch("[^%[%]%s,]+") do
              table.insert(config[section][k], coerce(item))
           end
          else
            config[section][k] = coerce(v)
          end
        end
      end
    end
  end
end


-- service management, again

rf.log(rf.prefix.green, "src/services")

do
  local svdir = "nil"
  local sv = {up = nil}
  local running = {}
  local process = require("process")
  
  function sv.up(svc)
  end
  
  function sv.down(svc)
  end
  
  function sv.list()
  end
  
  function sv.msg()
  end
  
  rf.log(rf.prefix.blue, "Starting services")
  for k, v in pairs(config) do
    if v.autostart then
      rf.log(rf.prefix.yellow, "service START: ", k)
      sv.up(k)
      rf.log(rf.prefix.yellow, "service UP: ", k)
    end
  end
end


while true do coroutine.yield() end

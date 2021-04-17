-- getty implementation --

local function try(...)
  local result = table.pack(pcall(...))
  if not result[1] and result[2] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end

local sysfs = try(require, "sysfs")
local component = require("component")

local ttys = {}

-- TTY close handler
-- if there are no more references to a TTY, then actually close it
-- otherwise leave it open
local function ttyclose(self)
end

-- set up TTY1 first, with the boot-time console



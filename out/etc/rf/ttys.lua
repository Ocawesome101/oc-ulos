-- getty implementation --

local log = require("syslog")
local ld = log.open("start-ttys")

local function try(...)
  local result = table.pack(pcall(...))
  if not result[1] and result[2] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end

local fs = require("filesystem")
local process = require("process")

local d = "/sys/dev"
local files, err = fs.list(d)
if not files then
  log.write(ld, d .. ": " .. err)
  return
end

table.sort(files)

local login, err = loadfile("/bin/login.lua")
if not login then
  log.write(ld, "Failed loading login:", err)
  return nil, "failed loading login"
else
  for _, f in ipairs(files) do
    if f:match("tty") then
      log.write(ld, "Starting login on " .. f)
      local n = tonumber(f:match("tty(%d+)"))
      if not n then
        log.write(ld, "Bad TTY ID, for", f, "not starting login")
      else
        local handle, err = io.open("/sys/dev/" .. f, "rw")
        handle.buffer_mode = "none"
        if not handle then
          log.write(ld, "Failed opening TTY /sys/dev/" .. f .. ":", err)
        else
          process.spawn {
            name = "login[tty" .. n .. "]",
            func = login,
            stdin = handle,
            stdout = handle,
            input = handle,
            output = handle
          }
        end
      end
    end
  end
end

log.close(ld)

-- getty implementation --

local function try(...)
  local result = table.pack(pcall(...))
  if not result[1] and result[2] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end

local fs = require("filesystem")

local d = "/sys/dev"
local files, err = fs.list(d)
if not files then
  error(d .. ": " .. err)
  return
end

table.sort(files)

for _, f in ipairs(files) do
  if f:match("tty") then
    print("Starting login on " .. f)
    local n = f:match("tty(%d+)")
  end
end


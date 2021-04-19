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

local function pf(d)
  local files, err = fs.list(d)
  if not files then
    print(d .. ": " .. err)
    return
  end
  print(d)
  for i=1, #files, 1 do
    print(files[i])
  end
end

pf("/")
pf("/sys")
pf("/sys/dev")
pf("/sys/proc")

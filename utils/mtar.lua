-- create an mtar file --

local function genHeader(name, len)
  -- if len is <=65534, return an mtar v0 header (smaller)
  if len <= 65534 then
    return string.pack(">I2", #name) .. name .. string.pack(">I2", len)
  else
    -- else, return a v1 header (larger, much larger filesize)
    return string.pack(">I2I1I2", 0xFFFF, 1, #name) .. name
      .. string.pack(">I8", len)
  end
end

local function packFile(path)
  local handle = assert(io.open(path, "r"))
  local data = handle:read("a")
  handle:close()
  return genHeader(path:gsub("^out/", ""), #data) .. data
end

for file in io.lines() do
  print(packFile(path))
end

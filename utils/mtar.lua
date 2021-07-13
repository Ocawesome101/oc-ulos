#!/usr/bin/env lua
-- create an mtar v1 file --

local function genHeader(name, len)
  --io.stderr:write(name, "\n")
  return string.pack(">I2I1I2", 0xFFFF, 1, #name) .. name
    .. string.pack(">I8", len)
end

local function packFile(path)
  local handle = assert(io.open(path, "r"))
  local data = handle:read("a")
  handle:close()
  return genHeader(path:gsub("^out/", ""), #data) .. data
end

for file in io.lines() do
  io.write(packFile(file))
end

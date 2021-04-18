-- getty implementation --

local function try(...)
  local result = table.pack(pcall(...))
  if not result[1] and result[2] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end




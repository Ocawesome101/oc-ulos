-- size calculations

local lib = {}

-- if you need more sizes than this, @ me
local sizes = {"K", "M", "G", "T", "P", "E"}
setmetatable(sizes, {
  __index = function(_, k)
    if k > 0 then return "?" end
  end
})

-- override this if you must, but 2^10 is precious.
local UNIT = 1024

function lib.format(n, _)
  if not _ then return end
  local i = 0
  while n >= UNIT do
    n = n / UNIT
    i = i + 1
  end
  return string.format("%.2f%s", n, sizes[i] or "")
end

return lib

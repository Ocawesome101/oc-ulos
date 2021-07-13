-- wrap a gpu proxy so that all functions called on the wrapper are redirected to a buffer --

local blacklist = {
  setActiveBuffer = true,
  getActiveBuffer = true,
  setForeground = true,
  getForeground = true,
  setBackground = true,
  getBackground = true,
  allocateBuffer = true,
  setDepth = true,
  getDepth = true,
  maxDepth = true,
  setResolution = true,
  getResolution = true,
  maxResolution = true,
  totalMemory = true,
  buffers = true,
  getBufferSize = true,
  freeAllBuffers = true,
  freeMemory = true
}

return function(px, bufi)
  local new = {}

  for k, v in pairs(px) do
    if not blacklist[v] then
      new[k] = function(...)
        gpu.setActiveBuffer(bufi)
        return v(...)
      end
    else
      new[k] = v
    end
  end

  return new
end

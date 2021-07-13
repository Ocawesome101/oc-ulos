-- somewhat system-agnostic getgpu --

return function()
  return require("getgpu")(io.stderr.tty)
end

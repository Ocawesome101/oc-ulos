-- OCUI --

local args, opts = require("argutil").parse(...)

if #args == 0 then
  io.stderr:write([[
usage: ocui UIFILE ...
Launch UIFILE with a new OCUI instance in the
environment as 'ocui'.  Passes all remaining
arguments to the program.

OCUI (c) 2021 Ocawesome101 under the DSLv2.
]])
  os.exit(1)
end

local instance = require("ocui.base")()

local env = setmetatable({
  ocui = instance
}, {__index = _G})

assert(loadfile(args[1], nil, env))(...)

-- OCUI base --

local nci = require("ocui.object")
local getgpu = require("ocui.getgpu")
local gpuproxy = require("ocui.gpuproxy")
local class, inherit, new = nci()

_ENV.class = class
_ENV.inherit = inherit
_ENV.new = new

local base = class "base" {
  init = function(args)
    self.gpu = args.gpu
    self.x = args.x or 1
    self.y = args.y or 1
    self.w = args.w or 1
    self.h = args.h or 1
    self.children = {}
  end,
  addChild = function(ch)
    checkArg(1, ch, "table")
    local n = #self.children + 1
    self.children[n + 1] = ch
  end,
  click = function(x, y)
    for k, v in pairs(self.children) do
      if x >= v.x and x <= v.x + v.w and y >= v.y and y <= v.y + v.h then
        v:click(x - self.x + 1, y - self.y + 1)
      end
    end
  end,
  redraw = function(x, y)
    if self.visible then
      for k, v in pairs(self.children) do
        v:redraw(self.x + (x or 1) - 1, self.y + (y or 1) - 1)
      end
    end
  end,
  key = function(char, code)
    for k, v in pairs(self.children) do
      v:key(char, code)
    end
  end,
  visible = function(s)
    self.shown = not not s
  end
}

local winobj = require("ocui.window")

return function()
  if ocui then
    error("an ocui instance is already running")
  end

  local gpu = getgpu()
  return new("base", gpu)
end

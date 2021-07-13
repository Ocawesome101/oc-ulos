-- window object --

local gpuproxy = require("ocui.gpuproxy")
require("ocui.button")
require("ocui.label")
local colors = require("ocui.colors")

inherits "base" "buffer" {
  init = function(args)
    if args.bordered then
      args.h = args.h + 1
      self.bordered = true
    end
    self.x = args.x
    self.y = args.y
    self.w = args.w
    self.h = args.h
    local new = args.gpu.allocateBuffer(args.w, args.h)
    self.gpu = gpuproxy(gpu, new)
    self.children = {}
    if args.bordered then
      self.gpu.setBackground(colors.titlebar)
      self.gpu.fill(1, 1, self.w, 1, " ")
      self.gpu.setForeground(colors.buttons)
      self.gpu.set(1, 1, "X _")
      
      local click = self.click
      self.click = function(self, x, y)
        if x == 1 and y == 1 then
          if self.close then self:close() end
        elseif x == 3 and y == 3 then
          self.shown = false
          self.ox, self.oy = self.x, self.y
          self.x = 1000
          self.y = 1000
        end
      end
    end
  end,
}

package.path = package.path .. ";external/corelibs/lib/?.lua"

local termio = require("termio")

local mstr = (...)
-- example menu:
-- {
--   __ordering = {"main", "extra"}
--   main = {
--     __title = "Main Configuration",
--     __ordering = {"foo", "bar", "baz"},
--     foo = 14,
--     bar = "",
--     baz = 0,
--   },
--   extra = {
--     __title = "Extra Configuration",
--     __ordering = {"a", "b", "c"},
--     a = "",
--     b = "",
--     c = 0
--   }
-- }


mstr = mstr or {}

local colors = {
  BASE_BG = "104",
  BASE_FG = "97",
  MENU_BG = "100",
  MENU_FG = "30",
  MENU_SEL = "104",
}

local USAGE = "up/down/left/right: go up/go down/descend/ascend; return: modify"

local function setcolor(...)
  io.write("\27[", table.concat(table.pack(...), ";"), "m")
end

local function fill(x, y, w, h)
  local fst = (" "):rep(w)
  for i=1, h, 1 do
    termio.setCursor(x, y + i - 1)
    io.write(fst)
  end
end

local curmenu = {__ordering={"main"}, main = {}}

local function drawmenu()
  local w, h = termio.getTermSize()
  termio.setCursor(1, 1)
  setcolor(colors.BASE_BG, colors.BASE_FG)
  io.write("\27[2J")
  if curmenu.__title then
    termio.setCursor(1, 1)
    io.write(curmenu.__title)
  end
  termio.setCursor(1, h)
  io.write(USAGE)
  setcolor("40")
  fill(5, 3, w - 8, h - 4)
  setcolor(colors.MENU_BG, colors.MENU_FG)
  fill(4, 2, w - 8, h - 4)
  for i, item in ipairs(curmenu.__ordering) do
    termio.setCursor(6, 3 + i)
    if curmenu.__selected == i then
      setcolor(colors.MENU_SEL, colors.MENU_FG)
    else
      setcolor(colors.MENU_BG, colors.MENU_FG)
    end
    local val = curmenu[item]
    io.write(item, " ")
    if type(val) == "table" then
    else
      io.write("(", val, ")")
    end
  end
end

drawmenu()

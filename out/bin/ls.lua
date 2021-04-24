-- coreutils: ls --

local time = require("time")
local text = require("text")
local size = require("size")
local path = require("path")
local filetypes = require("filetypes")
local fs = require("filesystem")

local args, opts = require("argutil").parse(...)

local colors = {
  default = "39;49",
  dir = "49;94",
  link = "49;96",
  special = "49;93"
}

local function infoify(base, files, hook)
  for i=1, #files, 1 do
    local fpath = path.canonical(path.concat(base, files[i]))
    local info, err = fs.stat(fpath)
  end
end

local function list(dir)
  dir = path.canonical(dir)
  local files, err
  if opts.d then
    files = {dir}
  else
    local info, serr = fs.stat(dir)
    if not info then
      err = serr
    elseif not info.dir then
      files = {dir}
    else
      files, err = fs.list(dir)
    end
  end
  if not files then
    return nil, string.format("%s: %s", dir, err)
  end
  if opts.l then
    infoify(dir, files, colorize)
    for i=1, #files, 1 do
      print(files[i])
    end
  elseif opts["1"] then
    for i=1, #files, 1 do
      print(colorize(files[i]))
    end
  else
    print(text.mkcolumns(files, colorize))
  end
end

if #args == 0 then
  args[1] = os.getenv("PWD")
end

for i=1, #args, 1 do
  list(args[i])
end

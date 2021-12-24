#!/usr/bin/env lua
--[[
    Barebones Lua preprocessor.
    Copyright (C) 2021 Ocawesome101

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
  ]]--

_G.env = setmetatable({}, {__index = function(t, k) return os.getenv(k) end})

local handle

local included = {}
local dirs
dirs = {
  {"%-%-#define ([^ ]+).-([^ ]+)", function(a, b)
    dirs[#dirs + 1] = {"[^a-zA-Z0-9_]"..a.."[^a-zA-Z0-9_]", b}
  end},
  {"%-%-#undef ([^ }+)", function(a)
    local done = false
    for i=1, #dirs, 1 do
      if dirs[i][1]:sub(13, -13) == a then
        table.remove(dirs, i)
        done = true
        break
      end
    end
    if not done then
      error(a .. ": not defined")
    end
  end},
  {"$%[%{(.+)%}%]", function(ex)
    return assert(io.popen(ex, "r"):read("a")):gsub("\n$","")
  end},
  {"@%[%{(.+)%}%]", function(ex)
    return assert(load("return " .. ex, "=eval", "t", _G))()
  end},
  {"(%-%-#include \")(.+)(\" ?)(.-)", function(_, f, _, e)
    if (e == "force") or not included[f] then
      included[f] = true
      return proc(f)
    end
  end},
}

_G.proc = function(f)
  io.write("\27[36m *\27[39m processing " .. f .. "\n")
  for line in io.lines(f) do
    for k, v in ipairs(dirs) do
      line = line:gsub(v[1], v[2])
    end
    if not line:match("#include") then
      handle:write(line .. "\n")
    end
  end
end

local args = {...}

if #args < 2 then
  io.stderr:write([[
usage: proc IN OUT
Preprocesses files in a manner similar to LuaComp.

Much more primitive than LuaComp.

Copyright (C) 2021 Ocawesome101 under the GPLv3.
]])
  os.exit(1)
end

handle = assert(io.open(args[2], "w"))

proc(args[1])

handle:close()

if args[3] == "-strip-comments" then
  io.write("\27[93m * \27[39mStripping comments\n")
  local rhand = assert(io.open(args[2], "r"))
  local data = rhand:read("a")
    :gsub(" *%-%-%[(=*)%[.-%]%1%]", "")
    :gsub(" *%-%-[^\n]*\n", "")
    :gsub("\n+", "\n")
    :gsub("\n( +)([^/\\_ ])", "\n%2")
  rhand:close()
  local whand = assert(io.open(args[2], "w"))
  whand:write(data)
  whand:close()
end

io.write("\27[95m * \27[39mSuccess!\n")

_G.env = nil
_G.proc = nil

os.exit(0)

#!/usr/bin/env lua
-- coreutils: text formatter --

local args = {...}

local patterns = {
  {"  ", "&nbsp&nbsp"},
  {"<", "<"},
  {">", ">"},
  {"\n", "<br>"},
  {"%*{(..-)}", "<span style='color:#FFF;font-weight:bold;'>%1</span>"},
  {"%${(..-)}", "<span style='color:#0AA;font-weight:bold;font-style:italic;'>%1</span>"},
  {"@{(..-)}",  "<span style='color:#55F;font-weight:bold;'><a href='%1'>%1</a></span>"},
  {"#{(..-)}",  "<span style='color:#FF0;font-weight:bold;'>%1</span>"},
  {"red{(..-)}", "<span style='color:#F00;font-weight:bold;'>%1</span>"},
  {"green{(..-)}", "<span style='color:#0F0;font-weight:bold;'>%1</span>"},
  {"yellow{(..-)}", "<span style='color:#FF0;font-weight:bold;'>%1</span>"},
  {"blue{(..-)}", "<span style='color:#55F;font-weight:bold;'>%1</span>"},
  {"magenta{(..-)}", "<span style='color:#F5F;font-weight:bold;'>%1</span>"},
  {"cyan{(..-)}", "<span style='color:#0AA;font-weight:bold;'>%1</span>"},
  {"white{(..-)}", "<span style='color:#FFF;font-weight:bold;'>%1</span>"},
}

local base = [[
<!DOCTYPE html>

<link rel="stylesheet" href="https://oz-craft.pickardayune.com/man/ulos/style.css">

<html>
  <title>%s</title>
  ULOS Manual Pages - %s | <a href="../%s">Back</a><br><br>
  <body>
    %s
  </body>
</html>
]]

for i=1, #args, 1 do
  local handle, err = io.open(args[i], "r")
  if not handle then
    io.stderr:write("tfmt: ", args[i], ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()

  for i=1, #patterns, 1 do
    data = data:gsub(patterns[i][1], patterns[i][2])
  end

  local name = args[i]:match("[^/]+/[^/]+$")
  name = name:sub(3) .. "(" .. name:sub(1,1) .. ")"

  print(base:format(name, name, name:sub(-2,-2), data))
end

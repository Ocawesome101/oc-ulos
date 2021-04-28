-- argutil: common argument parsing library

local lib = {}

function lib.parse(...)
  local top = table.pack(...)
  local do_done = true
  
  if type(top[1]) == "boolean" then
    do_done = top[1]
    table.remove(top, 1)
  end

  local args, opts = {}, {}
  local done = false
  
  for i=1, #top, 1 do
    local arg = top[i]
    
    if done or arg:sub(1,1) ~= "-" then
      args[#args+1] = arg
    else
      if arg == "--" and do_done then
        done = true
      elseif arg:sub(1,2) == "--" and #arg > 2 then
        local opt, oarg = arg:match("^%-%-(.-)=(.+)")
  
        opt, oarg = opt or arg:sub(3), oarg or true
        opts[opt] = oarg
      elseif arg:sub(1,2) ~= "--" then
        opts[arg:sub(2)] = true
      end
    end
  end

  return args, opts
end

return lib

-- a shell.

local fs = require("filesystem")
local pipe = require("pipe")
local process = require("process")
local tokenizer = require("tokenizer")
local w_iter = tokenizer.new()

local def_path = "/bin:/sbin:/usr/bin"

w_iter.discard_whitespace = false
w_iter:addToken("bracket", "()[]{}")
w_iter:addToken("splitter", "$|&\"'; ")

local function tkiter()
  return w_iter:matchToken()
end

local function split(text)
  w_iter.text = text
  w_iter.i = 0
  local words = {}
  for word, ttype in tkiter do
    words[#words + 1] = word
  end
  return words
end

local token_st = {}

local function push(t)
  token_st[#token_st+1] = t
end

local function pop(t)
  return table.remove(token_st, #token_st)
end

local state = {
  backticked = false,
  quoted = false,
}

local alt = {
  ["("] = ")",
  ["{"] = "}",
  ["["] = "]"
}

local splitc = {
  ["|"] = true,
  [";"] = true,
  ["&"] = true
}

local var_decl = "([^ ]+)=(.-)"

local function resolve_program(program)
  if not program then
    return
  end
  local pwd = os.getenv("PWD")
  local path = os.getenv("PATH") or def_path
  if program:match("/") then
    local relative
    if program:sub(1,1) == "/" then
      relative = program
    else
      relative = string.format("%s/%s", pwd, program)
    end
    if fs.stat(relative) then
      return relative
    elseif fs.stat(relative .. ".lua") then
      return relative .. ".lua"
    end
  end
  for entry in path:gmatch("[^:]+") do
    local try = string.format("%s/%s", entry, program)
    if fs.stat(try) then
      return try
    elseif fs.stat(try .. ".lua") then
      return try .. ".lua"
    end
  end
  return nil, "sh: " .. program .. ": command not found"
end

local function run_programs(programs, getout)
  local sequence = {{}}
  local execs = {}
  for i, token in ipairs(programs) do
    if splitc[token] then
      if #sequence[#sequence] > 0 then
        sequence[#sequence + 1] = {}
      else
        return nil, "sh: syntax error near unexpected token '"..token.."'"
      end
    else
      table.insert(sequence[#sequence], token)
    end
  end

  if #sequence[1] == 0 then
    return true
  end

  for i, program in ipairs(sequence) do
    if type(program) ~= "string" then
      local prg_env = {}
      program.env = prg_env
      while #program > 0 and program[1]:match(var_decl) do
        local k, v = table.remove(program, 1):match(var_decl)
        prg_env[k] = v
      end

      if #program == 0 then
        for k, v in pairs(prg_env) do
          os.setenv(k, v)
        end
        return
      end

      for i, token in ipairs(program) do
        if token:match("%$([^ ]+)") then
          program[i] = os.getenv(token:sub(2))
        end
      end
      program[0] = program[1]
      local pre
      program[1], pre = resolve_program(program[1])
      if not program[1] and pre then
        return nil, pre
      end
      execs[#execs + 1] = program
    elseif program == "|" then
      if type(sequence[i - 1]) == "string" or
          type(sequence[i + 1]) == "string" then
        return nil, "sh: syntax error near unexpected token '|'"
      end
      local pipe = pipe.create()
      sequence[i - 1].output = pipe
      sequence[i + 1].input = pipe
    end
  end

  for i, program in ipairs(execs) do
    if not program[1] then
      return
    end
    local exec, err = loadfile(program[1])
    if not exec then
      return nil, "sh: " .. program[0] .. ": " ..
        (err or "command not found")
    end
    local pid = process.spawn {
      func = function()
        for k, v in pairs(program.env) do
          os.setenv(k, v)
        end
        if program.input then
          io.input(program.input)
        end
        if program.output then
          io.output(program.output)
        end
        local ok, err, ret1 = pcall(exec, table.unpack(program, 2))
        if not ok and err then
          io.stderr:write(program[0], ": ", err, "\n")
          os.exit(127)
        elseif not err and ret1 then
          io.stderr:write(program[0], ": ", err, "\n")
          os.exit(127)
        end
        os.exit(0)
      end,
      name = table.concat(program) or program[1],
      stdin = program.input,
      input = program.input,
      stdout = program.output,
      output = program.output,
      stderr = program.stderr
                or io.stderr
    }

    print(process.await(pid))
  end
  return true
end

local function parse(cmd)
  local ret = {}
  local words = split(cmd)
  for i=1, #words, 1 do
    local token = words[i]
    token = token:gsub("\n", "")
    local opening = token_st[#token_st]
    local preceding = words[i - 1]
    if token:match("[%(%{%[]") then -- opening bracket
      if preceding == "$" then
        push(token)
        ret[#ret + 1] = ""
      else
        -- TODO: handle this
        return nil, "sh: syntax error near unexpected token '" .. token .. "'"
      end
    elseif token:match("[%)%]%}]") then -- closing bracket
      local ttok = pop()
      if token ~= alt[ttok] then
        return nil, "sh: syntax error near unexpected token '" .. token .. "'"
      end
      local pok, perr = parse(ret[#ret])
      if not pok then
        return nil, perr
      end
      local rok, rerr = run_programs(pok, true)
      if not rok then
        return nil, rerr
      end
      ret[#ret] = rok
    elseif token:match([["']]) then
      if state.quoted and token == state.quoted then
        state.quoted = false
      else
        state.quoted = token
        ret[#ret + 1] = ""
      end
    elseif opening and opening:match("[%(%[{]") then
      table.insert(ret[#ret], token)
    elseif state.quoted then
      ret[#ret] = ret[#ret] .. token
    elseif token:match(" ") then
      if #ret[#ret] > 0 then ret[#ret + 1] = "" end
    elseif token then
      if #ret == 0 then ret[1] = "" end
      ret[#ret] = ret[#ret] .. token
    end
  end
  return ret
end

local function execute(cmd)
  local data, err = parse(cmd)
  if not data then
    return nil, err
  end
  return run_programs(data)
end

while true do
  io.write("dummy-shell:$ ")
  local inp = io.read("L")
  if inp then
    local ok, err = execute(inp)
    if not ok and err then
      io.stderr:write(err, "\n")
    end
  end
end

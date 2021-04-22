-- a shell.

local tokenizer = require("tokenizer")
local w_iter = tokenizer.new()

w_iter.discard_whitespace = false
w_iter:addToken("bracket", "()[]{}")
w_iter:addToken("splitter", "$|&\"' ")

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

local function run_programs(programs)
end

local function parse(cmd)
  local ret = {}
  local words = split(cmd)
  for i=1, #words, 1 do
    print(words[i])
    local token = words[i]
    local preceding = token_st[#token_st]
    if token:match("[%(%{%[]") then -- opening bracket
      push(token)
      ret[#ret + 1] = ""
    elseif token:match("[%)%]%}]") then -- closing bracket
      local ttok = pop()
      if token ~= alt[ttok] then
        return nil, "sh: unexpected token near '" .. token .. "'"
      end
      ret[#ret] = parse(ret[#ret])
      ret[#ret] = run_programs(ret[#ret])
    elseif token:match([["']]) then
      if state.quoted and token == state.quoted then
        state.quoted = false
      else
        state.quoted = token
        ret[#ret + 1] = ""
      end
    elseif preceding:match("[%(%[{]") then
      table.insert(ret[#ret], token)
    elseif state.quoted then
      ret[#ret] = ret[#ret] .. token
    else
      ret[#ret + 1] = token
    end
  end
  return ret
end

while true do
  io.write("dummy-shell:$ ")
  local inp = io.read("L")
  if inp then
    local ok, err = execute(inp)
    if not ok and err then
      print(err)
    end
  end
end

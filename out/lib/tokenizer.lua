-- some sort of parser library

local lib = {}

local function esc(c)
  return c:gsub("[%[%]%(%)%.%+%-%*%%%^%$%?]", "%%%1")
end

function lib:matchToken()
  local tok = ""
  local splitter = "[" .. self.brackets .. self.splitters .. "]"
  if self.i >= #self.text then return nil end
  for i=self.i, #self.text, 1 do
    self.i = i + 1
    local c = self.text:sub(i,i)
    if #self.splitters > 0 and c:match(splitter) and #tok == 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if #self.brackets > 0 and c:match("["..self.brackets.."]") then
          return c, "bracket"
        elseif self.text:sub(i+1,i+1):match(splitter) then
          tok = c
        else
          return c, "splitter"
        end
      end
    elseif #self.splitters > 0 and c:match(splitter) and #tok > 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if tok:match("%"..c) then
          tok = tok .. c
        else
          self.i = self.i - 1
          return tok, (tok:match(splitter) and "splitter") or "word"
        end
      elseif #tok > 0 then
        return tok, (tok:match(splitter) and "splitter") or "word"
      end
    elseif #self.splitters > 0 and tok:match(splitter) and #tok > 0 then
      self.i = self.i - 1
      return tok, "splitter"
    else
      tok = tok .. c
      if self.text:sub(i+1,i+1):match(splitter) then
        for n, v in ipairs(self.words) do
          if tok == v.word then
            return tok, v.type
          end
        end
        for n, v in ipairs(self.matches) do
          if tok:match(v.pattern) then
            return tok, v.type
          end
        end
      end
    end
  end
  return ((#tok > 0 and tok) or nil), #tok > 0 and "word" or nil
end

function lib:addToken(ttype, pow, ptype)
  if ttype == "match" then
    self.matches[#self.matches + 1] = {
      pattern = pow,
      type = ptype or ttype
    }
  elseif ttype == "bracket" then
    self.brackets = self.brackets .. esc(pow)
    self.splitters = self.splitters .. esc(pow)
  elseif ttype == "splitter" then
    self.splitters = self.splitters .. esc(pow)
  else
    self.words[#self.words + 1] = {
      word = pow,
      type = ptype or ttype
    }
  end
end

function lib.new(text)
  return setmetatable({
    words={},
    matches={},
    i=0,
    text=text or"",
    splitters="",
    brackets=""},{__index=lib})
end

return lib

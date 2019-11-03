-- MIT License
-- 
-- Copyright (c) 2019 babulous
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local O = { }

local metamethods = {
  "__add", "__sub", "__mul", "__div", "__unm", "__pow", "__mod",
  "__tostring", "__lt", "__le", "__eq", "__mode", "__metatable", 
  "__concat", "__newindex"
}
local function extend_metatable(base, super)
  for i = 1, #metamethods do
    base[metamethods[i]] = super[metamethods[i]]
  end

  if type(super.__index) == "function" then
    base.__index = super.__index
  end

  return base
end

function O.Class(name, Super, loader)
  if     type(name)  == "function" then name, Super, loader = nil,  nil,  name
  elseif type(name)  == "table"    then name, Super, loader = nil,  name, Super
  elseif type(Super) == "function" then name, Super, loader = name, nil,  Super end

  local C 
  local MT
  if Super then
    C  = Super.New()
    MT = extend_metatable({ __index = C }, Super)
  else
    C  = { }
    MT = { __index = C }
  end

  C .Class     = MT
  C .Prototype = C
  MT.Prototype = C
  C .ClassName = name
  function MT:__tostring()
    local mt = getmetatable(self)
    
    local mt_tostring = mt.__tostring
    mt.__tostring = nil
    local result = tostring(self):gsub("table", mt.Prototype.ClassName or "Object")
    mt.__tostring = mt_tostring

    return result
  end

  function MT:New()
    return setmetatable({ }, MT)
  end

  MT.Construct = loader(C, MT)

  return setmetatable(MT, {
    __call = function(_, ...)
      local instance = MT:New()
      if MT.Construct then
        MT.Construct(instance, ...)
      end
      return instance
    end
  })
end

function O.Singleton(name, Super, loader)
  return O.Class(name, Super, loader)()
end

function O.Super(object)
  return getmetatable(object.Prototype).__index
end

function O.IsInstance(object, Class)
  local MT = getmetatable(object)
  if MT == Class then return true
  else                return IsInstance(MT.__index, Class) end
end

return O
-- MIT License
-- 
-- Copyright (c) 2020 babulous
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

local O = require 'timeline.oop'

local timeline_stack = { }

-- ugly hack to avoid multiple stack traces in error messages
local debug_traceback = debug.traceback
local ignore_traceback = 0
function debug.traceback(...)
  if ignore_traceback > 0 then ignore_traceback = ignore_traceback - 1; return ""
  else                         return debug_traceback(...) end
end

local tl_err
local function safety_error(msg)
  ignore_traceback = 2
  error("Timeline Error: \n\n" .. msg, -1)
end
local function safety_coalesce(success, ...)
  if not success then
    safety_error(..., -1)
  end
  return ...
end
-- this class will wrap timeline run functions in order to
-- provide better error messages
local function safety_wrapper(f)
  return function(...)
    return safety_coalesce(xpcall(f, debug.traceback, ...))
  end
end


local function timeline_error(msg)
  print(msg)
  error(msg, -1)
end
local function timeline_coalesce(tl, success, ...)
  if not success then
    timeline_error(...)
  end
  if coroutine.status(tl._coroutine) == "dead" and select("#", ...) > 0 then
    tl._results = { ... }
  end
end
local function timeline_resume(tl)
  if coroutine.status(tl._coroutine) ~= "dead" then
    timeline_coalesce(tl, coroutine.resume(tl._coroutine, unpack(tl._args)))
  end
end


-- timelines!! the heart of tle
TL = O.Class("Timeline", function(C, MT)
  C._status      = "Suspended"
  C._is_paused   = false
  C._type        = "TLE"

  MT.Event   = { }
  MT.Trigger = { }

  function C:type   () return self._type end
  function C:_yield () coroutine.yield() end
  function C:_resume() timeline_resume(self) end

  function C:Step()
    if self._status ~= "Dead" and not self._is_paused then
      timeline_stack[#timeline_stack + 1] = self
      local branch_count = #self._branches
      self._status = "Running"
      self:_resume()

      self._status = "Delegating"
      for i = 1, branch_count do
        self._branches[i]:Step()
      end
      for i = #self._branches, 1, -1 do
        if self._branches[i]:GetStatus() == "Dead" then
          table.remove(self._branches, i)
        end
      end

      if #self._branches == 0 and coroutine.status(self._coroutine) == "dead" then
        self._status = "Dead"
      else
        self._status = "Suspended"
      end
      timeline_stack[#timeline_stack] = nil
    end
    return self:IsDone()
  end

  function C:IsRunning () return self._status == "Running" or self._status == "Delegating" end
  function C:IsDone    () return self._status == "Dead" end
  function C:GetStatus () return self._status end
  function C:HasResults() return #self._results > 0 end
  function C:GetResults() return unpack(self._results) end

  function C:Branches() return ipairs(self._branches) end

  function C:Pause() 
    self._is_paused = true
    if self:IsRunning() then
      TL.Step()
    end
  end
  function C:Unpause()
    self._is_paused = false 
  end
  function C:IsPaused() return self._is_paused end

  function C:Branch(run, ...)
    local b  = TL(run, ...)
    self._branches[#self._branches + 1] = b
    return b
  end

  function C:KillBranches()
    for i = 1, #self._branches do
      self._branches[i]:Die()
      self._branches[i] = nil
    end
  end
  function C:Die()
    self:KillBranches()
    if self:IsRunning() then
      self._status = "Dead"
      TL.Step()
    else
      self._status = "Dead"
    end
  end

  return function(self, run, ...)
    if type(run) ~= "function" then
      local success = false
      if type(run) == "table" then
        success = getmetatable(run).__call
      end
      assert(success, "attempt to pass uncallable value to timeline constructor")
    end

    self._coroutine = coroutine.create(safety_wrapper(run))
    self._args      = { ... }
    self._results   = { }
    self._branches  = { }
  end
end)

package.loaded['timeline'] = TL

-- Utility --

local delta_time = 0
local frame      = 0
function TL.GetDT   () return delta_time end
function TL.GetFrame() return frame end

local loop_count = 0
function TL.CheckInfiniteLoop(...)
  loop_count = loop_count + 1
  if loop_count > 100000 then 
   error("infinite loop detected, try calling TL.Step()")
  end
  if select("#", ...) == 0 then return true
  else                          return ... end
end

local background_timelines = { }
function TL.Do(run)
  local tl = TL(run)
  background_timelines[#background_timelines + 1] = tl
  return tl
end

local TimelinePeeper = O.Class("TimelinePeeper", TL, function(C)
  local _PEEK_FINISHED = { }
  function C:_yield()
    error(_PEEK_FINISHED)
  end

  local function peep_coalesce(tl, success, ...)
    tl:KillBranches()
    if not success then
      if ... == _PEEK_FINISHED then 
        tl._did_pass = false
        return
      else
        timeline_error(...)
      end
    end
    tl._did_pass = true
    for i = 1, select("#", ...) do tl._results[i] = select(i, ...) end
  end

  function C:_set(run, ...)
    for i = 1, #self._results   do self._results[i] = nil end
    for i = 1, #self._args      do self._args   [i] = nil end
    for i = 1, select("#", ...) do self._args   [i] = select(i, ...) end
    self._run         = run
    self._status      = "Suspended"
    self._is_finished = false
  end

  return function(self)
    self._coroutine = coroutine.create(function()
      while true do
        coroutine.yield()
        peep_coalesce(self, xpcall(self._run, debug.traceback, unpack(self._args)))
      end
    end)
    self._args      = { }
    self._results   = { }
    self._branches  = { }
  end
end)

local peeper_stack = { TimelinePeeper(), _index = 0 }
local function get_peeper()
  return peeper_stack[peeper_stack._index + 1]
end

function TL.DidPeekTrigger() return get_peeper()._did_pass end
function TL.GetPeekResults() return get_peeper():GetResults() end
function TL.Peek(run, ...)
  peeper_stack._index = peeper_stack._index + 1
  if not peeper_stack[peeper_stack._index] then
    peeper_stack[peeper_stack._index] = TimelinePeeper()
  end

  local peeper = peeper_stack[peeper_stack._index]
  peeper:_set(run, ...)
  peeper:Step()
  peeper_stack._index = peeper_stack._index - 1
  return TL.DidPeekTrigger(), TL.GetPeekResults()
end

function TL.Assert(msg)
  assert(timeline_stack[#timeline_stack], msg or "cannot call this function outside of a Timeline")
end

function TL.Step()
  TL.Assert()
  TL.Current():_yield()
end

function TL.Current()
  return timeline_stack[#timeline_stack]
end

-- Events --

function TL.Event.Kill(n)
  n = n or 0
  TL.Assert()
  assert(n <= 0, "TL.Event.Kill only accepts negative numbers or 0")
  assert(#timeline_stack >= -n, "attempt to kill a timeline outside of the stack")
  timeline_stack[#timeline_stack + n]:Die()
end

function TL.Event.Die()
  TL.Assert()
  TL.Current():Die()
end

function TL.Event.Branch(run, ...)
  TL.Assert()
  local b = TL.Current():Branch(run, ...)
  local success, err = pcall(TL.Step, b)
  if not success then error(err) end
  return b
end

function TL.Event.Wait(t)
  while t > 0 do
    TL.Step()
    t = t - TL.GetDT()
  end
  return t
end

function TL.Trigger.OnTimelineDone(t)
  assert(t ~= TL.Current(), "attempt to wait for the currently running timeline")
  while not t:IsDone() do TL.Step() end
  return t:GetResults()
end

function TL.Trigger.OnBranchesDone(t)
  t = t or TL.Current()
  while next(t._branches) do TL.Step() end
end

-- Input Events --

local function new_on_trigger(name, narg)
  return function(...)
    while true do
      for a, b, c, d in TL.Trigger[name]("All") do
        local arg = select(narg, a, b, c, d)
        for i = 1, select("#", ...) do
          if arg == select(i, ...) then
            return arg
          end
        end
      end
      TL.Step()
    end
  end
end
TL.Trigger.OnKeyPress     = new_on_trigger("KeyPressed",      2)
TL.Trigger.OnMousePress   = new_on_trigger("MousePressed",    3)
TL.Trigger.OnKeyRelease   = new_on_trigger("KeyReleased",      2)
TL.Trigger.OnMouseRelease = new_on_trigger("MouseReleased",    3)

local function new_on_trigger_joystick(name, narg)
  return function(joystick, ...)
    while true do
      for jstick, b, c, d in TL.Trigger[name]("All") do
        local arg = select(narg, jstick, b, c, d)
        for i = 1, select("#", ...) do
          if arg == select(i, ...) then
            return arg
          end
        end
      end
    end
  end
end
TL.Trigger.OnGamepadPress    = new_on_trigger_joystick("GamepadPressed",  2)
TL.Trigger.OnJoystickPress   = new_on_trigger_joystick("JoystickPressed", 2)
TL.Trigger.OnGamepadRelease  = new_on_trigger_joystick("GamepadReleased",  2)
TL.Trigger.OnJoystickRelease = new_on_trigger_joystick("JoystickReleased", 2)

-- LOVE Events --

local inputs = { Size = 0 }
local function get_next_input(list)
  list.Size = list.Size + 1
  if not list[list.Size] then
    list[list.Size] = { Type = nil, nil, nil, nil }
  end
  return list[list.Size]
end
local function push_input_trigger(typ, ...)
  local input = get_next_input(inputs)
  input.Type = typ
  for i = #input, 1,                -1 do input[i] = nil end
  for i = 1,      select("#", ...)     do input[i] = select(i, ...) end
end
local triggers = { "KeyPressed", "KeyReleased", "MousePressed", "MouseReleased", "MouseMoved", 
  "WheelMoved", "TouchPressed", "TouchReleased", "TouchMoved", "GamepadPressed", 
  "GamepadReleased", "GamepadAxis", "JoystickPressed", "JoystickReleased", "JoystickAxis", 
  "JoystickHat", "JoystickAdded", "JoystickRemoved", "TextInput", "Visible", "Resize", 
  "MouseFocus", "Focus" }

local function new_input_trigger(names)
  if type(names) == "string" then names = { names } end

  local function iterate()
    for j = 1, #names do
      for i = 1, inputs.Size do
        local input = inputs[i]
        if input.Type == names[j] then
          if #names > 1 then coroutine.yield(names[j], unpack(input))
          else               coroutine.yield(unpack(input)) end
        end
      end
    end
  end
  local function trigger(all)
    while TL.CheckInfiniteLoop() do
      for j = 1, #names do
        for i = inputs.Size, 1, -1 do
          local input = inputs[i]
          if input.Type == names[j] then
            if all == "All" then return coroutine.wrap(iterate)
            else
              if #names > 1 then return names[j], unpack(input)
              else               return unpack(input) end 
            end
          end
        end
      end
      TL.Step()
    end
  end
  return trigger
end

do
  for i = 1, #triggers do
    TL[triggers[i]:lower()] = function(...)
      push_input_trigger(triggers[i], ...)
    end
    TL.Trigger[triggers[i]] = new_input_trigger(triggers[i])
  end

  TL.Trigger.   MouseActivity = new_input_trigger({ "MousePressed", "MouseReleased", "MouseMoved", 
                                                    "WheelMoved" })
  TL.Trigger.  WindowActivity = new_input_trigger({ "MouseFocus", "Focus", "Resize", "Visible" })
  TL.Trigger.JoystickActivity = new_input_trigger({ "JoystickPressed", "JoystickReleased", 
                                                    "JoystickAdded", "JoystickRemoved", 
                                                    "JoystickAxis", "JoystickHat" })
  TL.Trigger. GamepadActivity = new_input_trigger({ "GamepadPressed", "GamepadReleased", 
                                                    "GamepadAxis" })
  TL.Trigger.     KeyActivity = new_input_trigger({ "KeyPressed", "KeyReleased", "TextInput" })
end

function TL.update(dt)
  for i = 1, #background_timelines do
    background_timelines[i]:Step()
  end
  for i = #background_timelines, 1, -1 do
    if background_timelines[i]:GetStatus() == "Dead" then
      table.remove(background_timelines, i)
    end
  end

  delta_time  = dt
  frame       = frame + 1
  inputs.Size = 0
  loop_count  = 0
end

function TL.Attach()
  for i = 1, #triggers do
    local lname = triggers[i]:lower()
    local old = love[lname]
    if old then
      love[lname] = function(...)
        TL[lname](...)
        old(...)
      end
    else
      love[lname] = TL[lname]
    end
  end

  local old_update = love.update or function()end
  function love.update(...)
    old_update(...)
    TL.update(...)
  end
end


return TL
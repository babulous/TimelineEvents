local O = require "tlevent.oop"

local E = { G = { }, O = { } }

local _itdbg

-- error handling

local lua_pcall  = pcall
local lua_xpcall = xpcall

local _TLE_TIMELINE_DIE = { }

local traceback = { }

local error_mt = {
  __tostring = function(self)
    return self.TracebackString
  end
}
local function timeline_error(err, level)
  if is_graphics_pushed then
    pop_graphics()
  end

  local db_traceback = debug.traceback(err)
  local db_string    = tostring(db_traceback)
  local tl_traceback = { }
  for i = 1, #traceback do
    tl_traceback[i] = traceback[i]
  end

  error(setmetatable({
    Traceback         = db_traceback,
    TracebackString   = db_string,
    TimelineTraceback = tl_traceback,
  }, error_mt), -2 + (level or 0))
end
local function timeline_assert(case, err)
  if not case then
    timeline_error(err, -1)
  end
  return case
end

local function push_timeline(self)
  timeline_assert(#traceback < 100000, "timeline overflow")
  table.insert(traceback, self)
  local parent = self.Parent
  while parent do
    parent = parent.Parent
  end
end
local function pop_timeline(self)
  timeline_assert(#traceback > 0, "reached end of timeline stack")
  timeline_assert(traceback[#traceback] == self, "uh oh")
  table.remove(traceback)
end

local function get_current_timeline()
  return traceback[#traceback]
end

local function is_functionable(v)
  if type(v) ~= "function" then
    if type(v) == "table" then
      local mt = getmetatable(v)
      return not not mt.__call
    else return false end
  end
  return true
end
setmetatable(E, {
  __newindex = function(self, k, v)
    if not is_functionable(v) then rawset(self, k, v)
    else
      rawset(self, k, function(...)
        timeline_assert(#traceback > 0, "events must be called inside of a timeline")
        return v(...)
      end)
    end
  end
})
setmetatable(E.O, {
  __newindex = function(self, k, v)
    if not is_functionable(v) then rawset(self, k, v)
    else
      rawset(self, k, function(...)
        timeline_assert(#traceback == 0, "outer events must be called outside of timelines")
        return v(...)
      end)
    end
  end
})

-- maximums

_TLE_MAX_BRANCH_RULES    = 25000
_TLE_MAX_ITERATIONS      = 10000
_TLE_MAX_BRANCHES        = 10000
_TLE_MAX_SINGLE_BRANCHES = 500

-- utility

local Cache = O.Class("Cache", function(C)
  function C:Pop()
    if #self.Data > 0 then 
      return table.remove(self.Data)
    end
  end
  function C:Push(dat)
    self:Reset(dat)
    if #self.Data < self.Max then
      table.insert(self.Data, dat)
    end
  end
  function C:Has()
    return #self.Data > 0
  end

  return function(self, max, reset)
    self.Reset = reset or function()end
    self.Max   = max or math.huge
    self.Data  = { }
  end
end)

-- the meat
  
local function coalesce(success, ...)
  if not success then
    timeline_error(..., -1)
  end
  return ...
end
function SafetyWrapper(f)
  return function(...)
    return coalesce(lua_xpcall(f, debug.traceback, ...))
  end
end

local Timeline = O.Class("Timeline", function(C, Timeline)
  Timeline.ActiveTimelines = { }
  Timeline.InstantaneousBranchCount = 0
  Timeline.TCache = Cache(_TLE_MAX_BRANCHES, function(self, data)
    Timeline.ActiveTimelines[data.ID] = nil
    data.ID        = nil
    data.Run       = nil
    data.Status    = "Dead"
    data.IsAuto    = false
    data.IsPassive = false
    for passive in pairs(data.Passives) do passive:Release(); data.Passives[passive] = nil end
    for i = 1, #data.Args    do data.Args   [i] = nil end
    for i = 1, #data.Results do data.Results[i] = nil end
  end)

  local default_tostring = Timeline.__tostring
  function Timeline:__tostring()
    local str = default_tostring(self)
    return str:gsub("Timeline", "Timeline[" .. tostring(self.ID) .. "]")
  end

  function Timeline.Get(id)
    return Timeline.ActiveTimelines[id]
  end

  local function safe_resume(cr, ...)
    local success, err = coroutine.resume(cr, ...)
    if not success then
      timeline_error(err, -2)
    end
  end

  local function pcall_coalesce(success, ...)
    if not success then
      if ... == _TLE_TIMELINE_DIE then
        timeline_error(_TLE_TIMELINE_DIE)
      end
    end
    return success, ...
  end
  local function running_pcall(...)
    return pcall_coalesce(lua_pcall(...))
  end
  local xpcall_user_errhand
  local function xpcall_errhand(...)
    if ... == _TLE_TIMELINE_DIE then
      return _TLE_TIMELINE_DIE
    end
    return xpcall_user_errhand(...)
  end
  local function running_xpcall(f, errhand, ...)
    xpcall_user_errhand = errhand
    return pcall_coalesce(lua_xpcall(f, xpcall_errhand, ...))
  end

  local function set_status(self, status)
    if self.Status ~= status then
      if self.Status == "Running" then
         pcall = lua_pcall
        xpcall = lua_xpcall
      elseif status == "Running" then
         pcall = running_pcall
        xpcall = running_xpcall
      end
      self.Status = status
    end
  end

  local function remove_branch(self, i)
    local tl = table.remove(self.Branches, i)
    if tl.Status ~= "Dead" then
      tl:Release()
    end
  end
  function C:Branch(tl)
    timeline_assert(self.Status == "Running", "attempt to branch a timeline that isn't running")

    table.insert(self.Branches, tl)
    set_status(self, "Normal")
    tl:Update()
    set_status(self, "Running")
  end

  function C:AddPassive(passive)
    self.Passives[passive] = true
    passive:Update()
  end
  function C:GetResults()
    return unpack(self.Results)
  end

  function C:IsDone()
    return self.Status                      == "Dead" or 
           self.Status                      == "Finished" or 
           coroutine.status(self.Coroutine) == "dead"
  end
  function C:IsRunning()
    return self.Status == "Running" or
           self.Status == "Normal"
  end

  local function check_completion(self)
    if self.Status == "Finished" then
      pop_timeline(self)
      self:Kill()
      return true
    elseif self:IsDone() then
      pop_timeline(self)
      set_status(self, "Dead")
      return true
    elseif self.Status == "Paused" then
      pop_timeline(self)
      return true
    end
    return false
  end
  function C:Update()
    if     self.Status == "Paused" then return
    elseif self:IsDone()           then timeline_error("attempt to resume a dead timeline", -1)
    elseif self:IsRunning()        then timeline_error("attempt to resume a running timeline", -1)
    else
      self.Wait = 0
      push_timeline(self)

      for passive in pairs(self.Passives) do
        passive.Wait = passive.Wait + 1
        if passive.Wait > 1 then passive:Kill() end
        if passive:IsDone() then
          self.Passives[passive] = nil
          passive:Release()
        elseif passive.IsAuto then
          passive:Update()
        end
      end

      set_status(self, "Running")
      local success, err = coroutine.resume(self.Coroutine)
      if not success then 
        timeline_error(err)
      end

      if check_completion(self) then return end
      set_status(self, "Normal")

      for i, tl in ipairs(self.Branches) do
        if not tl:IsDone() then tl:Update() end
      end
      for i = #self.Branches, 1, -1 do
        local tl = self.Branches[i]
        if tl:IsDone() then
          remove_branch(self, i)
        end
      end

      pop_timeline(self)
      set_status(self, "Suspended")
    end
  end

  function C:Release()
    timeline_assert(self:IsDone(), "attempt to release a running timeline")
    for _, tl in ipairs(self.Branches) do
      tl:Release()
    end
    Timeline.TCache:Push(self)
  end
  function C:KillBranches()
    for _, branch in pairs(self.Branches) do
      if not branch:IsDone() then
        branch:Kill()
      end
    end
    for passive in pairs(self.Passives) do
      if not passive:IsDone() then
        passive:Kill()
      end
    end
  end
  function C:Kill()
    timeline_assert(self.Status ~= "Dead", "attempt to kill a timeline that's already dead")
    local status = self.Status
    set_status(self, "Dead")
    self:KillBranches()
    if status == "Running" then
      self:Step()
    end
  end

  function C:Step()
    coroutine.yield()
    if self:IsDone() then
      error(_TLE_TIMELINE_DIE)
    end
  end
  function C:Pause()
    local status = self.Status
    set_status(self, "Paused")
    if status == "Running" then
      self:Step()
    end
  end
  function C:Resume()
    if self.Status == "Paused" then
      set_status(self, "Suspended")
      self:Update()
    end
  end

  local function pcall_run(err)
    if err == _TLE_TIMELINE_DIE then return err
    else                                  return debug.traceback(err) end
  end
  local function coalesce(self, success, ...)
    if success then
      self.Status = "Finished"
      for i = 1, select("#", ...) do
        self.Results[i] = select(i, ...)
      end
      coroutine.yield()
    else
      if ... ~= _TLE_TIMELINE_DIE then
        timeline_error(..., -1)
      end
    end
  end
  local coroutine_run = SafetyWrapper(function(self)
    while true do
      coroutine.yield()
      coalesce(self, lua_xpcall(self.Run, pcall_run, unpack(self.Args)))
    end
  end)
  function Timeline:New()
    if Timeline.TCache:Has() then
      local tl = Timeline.TCache:Pop()
      if coroutine.status(tl.Coroutine) == "dead" then
        tl.Coroutine = coroutine.create(coroutine_run)
      end
      safe_resume(tl.Coroutine, tl)
      return tl
    else
      Timeline.InstantaneousBranchCount = Timeline.InstantaneousBranchCount + 1
      if Timeline.InstantaneousBranchCount > _TLE_MAX_SINGLE_BRANCHES then
        timeline_error("branch overflow")
      end

      local instance = setmetatable({
        Branches  = { },
        Passives  = { },
        Args      = { },
        Results   = { },
        Coroutine = coroutine.create(coroutine_run),
      }, self)
      safe_resume(instance.Coroutine, instance)
      return instance
    end
  end
  local id = 0
  return function(self, run, ...)
    timeline_assert(type(run) == "table" or type(run) == "function", "bad branch function")

    id = (id + 1) % 1e300
    Timeline.ActiveTimelines[id] = self

    for i = 1, select("#", ...) do
      self.Args[i] = select(i, ...)
    end
    self.Wait   = 0
    self.Run    = run
    self.ID     = id
    set_status(self, "Suspended")
  end
end)

local function get_timeline(id)
  if id then 
    if id < 0 then
      return timeline_assert(traceback[#traceback + id], "attempt to get nonexistent relative timeline")
    else
      return timeline_assert(Timeline.Get(id), "attempt to perform operation on dead timeline") 
    end
  end
  return get_current_timeline()
end

-- some globals

local delta_time = 0
local frame = 0
function E.G.GetDeltaTime() return delta_time end
function E.G.GetFrame    () return frame end

function E.G.KillBranches(id) get_timeline(id):KillBranches() end
function E.G.Kill(id) 
  assert(id, "Kill requires an id")
  get_timeline(id):Kill() 
end

function E.G.IsDone(id)
  local tl = Timeline.Get(id)
  if tl then return tl:IsDone() 
  else       return true end
end
function E.G.IsRunning(id)
  local tl = Timeline.Get(id)
  if tl then return tl:IsRunning() 
  else       return false end
end

function E.G.Status(id)
  local tl = Timeline.Get(id) or get_current_timeline()
  if tl then return tl.Status
  else       return "Dead" end
end


function E.GetID() return get_timeline().ID end

-- built-in events

--function E.Resume(id) get_timeline(id):Resume() end
--function E.Pause (id) get_timeline(id):Pause() end

function E.Die() E.Kill(get_current_timeline().ID) end

function E.Step()
  return get_current_timeline():Step()
end
function E.When(f)
  repeat E.Step() until f()
end
function E.Wait(t)
  while t > 0 do
    E.Step()
    t = t - E.G.GetDeltaTime()
  end
end

function E.WaitForTimeline(id)
  local tl = get_timeline(id)
  repeat E.Step() until tl:IsDone() or tl.ID ~= id
end
function E.PollBranchStatus(id, status)
  if status == "Dead" then
    return E.WaitForBranches(id)
  end
  local tl = get_timeline(id)
  repeat E.Step() until tl.Status == status
end
function E.WaitForBranches(id)
  local tl = get_timeline(id)
  while #tl.Branches > 0 do E.Step() end
end


function E.IsPassiveDone(id) 
  local passive = Timeline.Get(id)
  if passive then return passive:IsDone()
  else            return true end
end
function E.GetPassiveResults(id)
  local passive = Timeline.Get(id)
  if passive then
    timeline_assert(passive:IsDone(), "attempt to get results from a running passive event")
    return passive:GetResults()
  end
  return nil
end
function E.PassiveStep(...)
  for i = 1, select("#", ...) do
    local passive = Timeline.Get(select(i, ...))
    if passive then 
      passive:Update() 
    end
  end
end

local BranchRule = O.Class("BranchRule", function(C, BranchRule)
  BranchRule.BRCache = Cache(_TLE_MAX_BRANCH_RULES)

  function C:Make(run, ...)
    timeline_assert(type(run) == "table" or type(run) == "function", "bad branch function")
    local br = BranchRule(self.Rule, run)
    local tl = Timeline(br, ...)
    return tl
  end
  function C:Branch(run, ...)
    local tl = self:Make(run, ...)
    get_current_timeline():Branch(tl)
    BranchRule.BRCache:Push(br)
    return tl
  end
  function C:Create(run, ...)
    local tl = self:Make(run, ...)
    tl:Update()
    BranchRule.BRCache:Push(br)
    return tl
  end

  function BranchRule:__call(...)
    E.Step()
    return self.Rule(self.Run, ...)
  end

  local function coalesce_results(self, ...)
    for i = 1, select("#", ...) do
      self.Results[i] = select(i, ...)
    end
  end
  function BranchRule:New()
    if BranchRule.BRCache:Has() then
      local instance = BranchRule.BRCache:Pop()
      return instance
    else
      local instance = setmetatable({ }, self)
      return instance
    end
  end
  return function(self, rule, run)
    self.Run  = run
    self.Rule = rule
  end
end)

local function rule_coalesce(f, ...) f(); return ... end
local rules = {
  ["patient"] = BranchRule(function(run, ...)
    return rule_coalesce(E.WaitForBranches, run(...))
  end),
  ["immediate"] = BranchRule(function(run, ...)
    return run(...)
  end),
  ["loop"] = BranchRule(function(run, ...)
    local iteration = 0
    while iteration < _TLE_MAX_ITERATIONS do
      local frame = E.G.GetFrame()
      run(...)
      if frame ~= E.G.GetFrame() then iteration = 0
      else                        iteration = iteration + 1 end
    end
    timeline_error("iteration overflow", -1)
  end)
}

local function parse_branch_args(...)
  local args_i = 3
  local rule, f = ...
  if type(rule) ~= "string" then
    args_i = 2
    rule   = "patient"
    f      = ...
  end
  return f, rule, args_i
end
getmetatable(E).__call = function(_, ...)
  local f, rule, args_i = parse_branch_args(...)
  local tl = rules[rule]:Create(f, select(args_i, ...))
  return tl.ID
end
function E.Branch(...)
  local f, rule, args_i = parse_branch_args(...)
  local tl = rules[rule]:Branch(f, select(args_i, ...))
  return tl.ID
end
function E.Passive(...)
  local f, rule, args_i = parse_branch_args(...)
  local passive = rules[rule]:Make(f, select(args_i, ...))
  get_current_timeline():AddPassive(passive)
  return passive.ID
end
function E.AutoPassive(...)
  local id = E.Passive(...)
  get_timeline(id).IsAuto = true
  return id
end

local text_input = ""
local text_input_frame = 0
function E.PollTextInput()
  local frame = E.G.GetFrame()
  repeat E.Step() until text_input_frame > frame
  return text_input
end

local button_pressed
local button_pressed_frame = 0
local function poll_mouse_press_any()
  local frame = E.G.GetFrame()
  repeat E.Step() until button_pressed_frame > frame
  return button_pressed
end
local button_released
local button_released_frame = 0
local function poll_mouse_release_any()
  local frame = E.G.GetFrame()
  repeat E.Step() until button_released_frame > frame
  return button_released
end

local key_pressed
local key_pressed_frame = 0
local function poll_key_press_any()
  local frame = E.G.GetFrame()
  repeat E.Step() until key_pressed_frame > frame
  return key_pressed
end
local key_released
local key_released_frame = 0
local function poll_key_release_any()
  local frame = E.G.GetFrame()
  repeat E.Step() until key_released_frame > frame
  return key_released
end

local function input_event(test, default, state, ...)
  if not ... then return default() end
  local was_equal
  repeat 
    was_equal = test(...) == state 
    E.Step()
  until test(...) == state and not was_equal
  return ...
end
function E.PollKeyPress    (k) return input_event(love.keyboard.isDown, poll_key_press_any,     true,  k) end
function E.PollKeyRelease  (k) return input_event(love.keyboard.isDown, poll_key_release_any,   false, k) end
function E.PollMousePress  (b) return input_event(love.mouse   .isDown, poll_mouse_press_any,   true,  b) end
function E.PollMouseRelease(b) return input_event(love.mouse   .isDown, poll_mouse_release_any, false, b) end

local wheel_position = 0
function E.PollMouseWheel()
  local pos = wheel_position
  repeat E.Step() until pos ~= wheel_position
  return wheel_position - pos
end

local dx, dy = 0, 0
function E.PollMouseMove()
  local x1, y1 = love.mouse.getPosition()
  local x2, y2 = x1, y1
  while x1 == x2 and y1 == y2 do 
    E.Step()
    x2, y2 = love.mouse.getPosition()
  end
  return x2 - x1, y2 - y1
end

local function is_mod_down(mod)
  if     mod == "ctrl"  then return love.keyboard.isDown("lctrl")  or love.keyboard.isDown("rctrl")
  elseif mod == "alt"   then return love.keyboard.isDown("lalt")   or love.keyboard.isDown("ralt")
  elseif mod == "shift" then return love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift") end
end
function E.PollHotkey(hotkey)
  local hk = { nil, nil, nil }
  local key
  local i = 1 
  while i < #hotkey do
    local s = hotkey:match("[^%+]+%+", i)
    hk[#hk + 1] = s:sub(1, #s - 1)
    i = i + #s
  end
  key = hotkey:sub(i, i)

  repeat
    local k = E.PollKeyPress()
    local is_good = true
    for i = 1, #hk do
      if not is_mod_down(hk[i]) then
        is_good = false
        break
      end
    end
  until is_good and k == key 
end

function E.PollMouseActivity()
  local pmm = E.Passive(E.PollMouseMove)
  local pmp = E.Passive(E.PollMousePress)
  local pmr = E.Passive(E.PollMouseRelease)
  local pmw = E.Passive(E.PollMouseWheel)
  while true do
    E.Step()
    E.PassiveStep(pmm, pmp, pmr, pmw)
    if E.IsPassiveDone(pmm) then return "MouseMoved",    E.GetPassiveResults(pmm) end
    if E.IsPassiveDone(pmp) then return "MousePressed",  E.GetPassiveResults(pmp) end
    if E.IsPassiveDone(pmr) then return "MouseReleased", E.GetPassiveResults(pmr) end
    if E.IsPassiveDone(pmw) then return "MouseWheel",    E.GetPassiveResults(pmw) end
  end
end

function E.  Assert()end
function E.O.Assert()end

-- outer events

function E.O.Step(id)
  Timeline.Get(id):Update()
end

local auto_timelines = { }
function E.O.Do(...)
  local id = E(...)
  auto_timelines[id] = true
  E.O.Step(id)
end

function E.O.update(dt)
  delta_time = dt
  frame      = frame + 1
  for id in pairs(auto_timelines) do
    if E.G.IsDone(id) then auto_timelines[id] = nil
    else                   E.O.Step(id) end
  end
end
function E.O.keypressed(k)
  key_pressed       = k
  key_pressed_frame = E.G.GetFrame()
end
function E.O.keyreleased(k)
  key_released       = k
  key_released_frame = E.G.GetFrame()
end
function E.O.mousemoved(_, _, ddx, ddy)
  dx, dy = ddx, ddy
end
function E.O.wheelmoved(dx, dy)
  wheel_position = wheel_position + dy
end
function E.O.mousepressed(_, _, button)
  button_pressed       = button
  button_pressed_frame = E.G.GetFrame()
end
function E.O.mousereleased(_, _, button)
  button_released       = button
  button_released_frame = E.G.GetFrame()
end
function E.O.textinput(text, ...)
  if E.G.GetFrame() ~= text_input_frame then
    text_input       = text
    text_input_frame = E.G.GetFrame()
  else
    text_input = text_input .. text
  end
end
function E.O.Attach()
  local function replace(name)
    if love[name] then
      local old = love[name]
      love[name] = function(...)
        E.O[name](...)
        old(...)
      end
    else
      love[name] = E.O[name]
    end
  end

  replace("keypressed")
  replace("keyreleased")
  replace("mousemoved")
  replace("mousereleased")
  replace("mousepressed")
  replace("wheelmoved")
  replace("textinput")

  if love.update then
    local old = love.update
    function love.update(...)
      old(...)
      E.O.update(...)
    end
  else
    love.update = E.O.update
  end
end

-- debug

if _TLE_DEBUG then
  _itdbg = {
    Timelines = {
      Rules = {
        Active = nil,
        Stored = nil,
        Total  = nil,
      },

      Active = nil,
      Stored = nil,
      Total  = nil
    }
  }

  function _itdbg.Timelines.Stored()
    return #Timeline.TCache.Data
  end
  function _itdbg.Timelines.Active()
    local count = 0
    for _ in pairs(Timeline.ActiveTimelines) do
      count = count + 1
    end
    return count
  end
  function _itdbg.Timelines.Total()
    return _tdbg.Get("Timelines.Stored") + _tdbg.Get("Timelines.Active")
  end

  function _itdbg.Timelines.Rules.Stored() return #BranchRule.BRCache.Data end
  function _itdbg.Timelines.Rules.Active() return _tdbg.Get("Timelines.Rules.Stored") end
  function _itdbg.Timelines.Rules.Total () return _tdbg.Get("Timelines.Rules.Stored") end

  local function split(path)
    local result = { }
    for str in string.gmatch(path, "[^%.]+") do
      result[#result + 1] = str
    end
    return result
  end
  local function get_path(path)
    local strpath = path
    path = split(path)
    local v = _itdbg
    for i = 1, #path do
      timeline_assert(type(v) == "table", "no debug variable at '" .. strpath .. "'")
      v = v[path[i]]
    end

    if type(v) == "function" then return v()
    else                          return v end
  end
  local function set_path(path, v)
    local strpath = path
    path = split(path)
    local t = _itdbg
    for i = 1, #path - 1 do
      t = t[path[i]]
      timeline_assert(type(t) == "table", "no debug table at '" .. strpath .. "'")
    end
    t[path[#path]] = v
  end

  _tdbg = { }

  function _tdbg.Get(path) return get_path(path) end
end

return E
# TimelineEvents
A coroutine based event system for Lua/LÖVE

FYI, this whole thing is being reworked at the moment and the API will change (for the better). Only use this if you want to experiment with it at the moment.

## How to Use Timeline Events

Timeline Events is an event system allows the programmer to write code in the order that events happen rather than catching all separate events with observers.

Simple example, this will print a few messages before closing:

```lua
-- main.lua
local E = require "tlevent"

E.O.Attach() -- all examples must include this line to function
E.O.Do(function()
  print("Hello!")
  E.Wait(1)
  print("Thanks for checking out my library~")
  E.Wait(3)
  print("[Press any key to exit]")
  E.PollKeyPress()
  love.event.push("quit")
end)
```

Because of the way TLE works, it demands that certain functions be called in certain locations of your code.

Timeline events is separated into 3 namespaces:
- ```E``` represents all functions that must be called inside of a timeline (i.e. inside the ```run``` function), with the exception of calling ```E``` directly, which must be done outside.
- ```E.O``` represents all functions that must be called outside of a timeline.
- ```E.G``` represents all functions that can be called anywhere.

There are built in functions to assert these conditions if you'd like to use them for yourself.

```lua
E.O.Assert()
```
```lua
E.Assert()
```

The core of TLE is it's "Events" which will halt code execution until a particular event happens. There's a number of built in events, but you can also make your own. There's no trick or system or catch or anything to making your own events, as long as you make a call to either another event or ```E.Step()```

Event example, will wait for the user to type the konami code:

```lua
-- main.lua
local E = require "tlevent"

local code = { "up", "up", "down", "down", "left", "right", "left", "right", "a", "b", "return" }
function PollKonamiCode()
  local i = 0
  while i < #code do
    local k = E.PollKeyPress()
    if code[i + 1] == k then
      i = i + 1
    else
      i = 0
    end
  end
end

E.O.Attach()
E.O.Do(function()
  print("Enter code")
  PollKonamiCode()
  print("God mode activated.")
  E.Wait(3)
  print("[Press any key to exit]")
end)
```

Complex example, this will have a dialog with the user before closing:

```lua
-- main.lua
local E = require "tlevent"

E.O.Attach()
E.O.Do(function()
  print("Hello!")
  E.Wait(1)
  print("What's your name?")
  E.Wait(1)
  local name = ""
  local enter_name = E.Branch("loop", function()
    print("Enter your name: " .. name)
    name = name .. E.PollTextInput()
  end)
  E.PollKeyPress("return")
  E.G.Kill(enter_name)
  print("")
  E.Wait(1)
  print("Hello " .. name .. ", nice to meet you!")
  E.Wait(3)
  print("[Press any key to exit]")
  E.PollKeyPress()
  love.event.push("quit")
end)
```

All of the above examples have been using ```E.O.Do([type,] run)```, I should mention this isn't typical. Normally you will create events using the similar ```E([type,] run)```. The difference is that ```E.O.Do(...)``` will update automatically where ```E(...)``` will need to be manually updated with ```E.O.Step(id)```.

Example of manual usage:

```lua
--- main.lua
local E = require "tlevent"

local quit_timeline = E(function()
  E.PollKeyPress("escape")
  love.event.quit()
end

function love.load()
  E.O.Attach()
end

function love.update(dt)
  E.O.Step(quit_timeline)
end
```

## Installation

Just drop the tlevent folder into your code and type:

```lua
local E = require "tlevent"
```

## Documentation

### The Basics

```lua
id = E([type,] run, ...)
```

Create a new timeline based on 3 different ```type``` values and a ```run``` function. The ```run``` function can also be a table that overrides the ```__call``` metamethod. The remaining arguments will be used as input into ```run```

The timeline types are given as one of the following string values.
- ```"patient"``` default, will wait for all branches before dying
- ```"immediate"``` will kill all branches as soon as ```run``` finishes
- ```"loop"``` will loop infinitely until killed manually

This returns an ```id``` number, this id points to the timeline object internally. In order to update timelines created in this way, you must call ```E.O.Step(id)``` somewhere when updating your program.
   <br/>
   
```lua
E.O.Step(id)
```

Update a Timeline from it's ```id``` value.   
   <br/>
   
```lua
E.O.Attach()
```

Attach Timeline Events to LÖVE's events (```keypressed```, ```update```, etc.), this will preserve the programmer's events, so call inside ```love.load()``` to avoid overriding TLEvent.  
   <br/>
   
```lua
id = E.Branch([type,] run, ...)
```

Create a timeline within another timeline. Branches are associated with their parent timeline and will update with it. Returns the ```id``` of this branch. Branches are initialized immediately and update in the order that they are created.   
<br/>

```lua
E.Step()
```

Step one iteration in the main loop. All Events will either directly, or indirectly make a call to this function. If this function isn't called somewhere then it's not an Event. Must be called inside of a Timeline, otherwise will return an error.

### Timeline Events

The heart of TLE, these functions will yield execution until the expected event occurs.

```lua
pressed = E.PollKeyPress([k])
```

Wait for the user to press the given key (in LÖVE's format), entering nothing will poll for any key. Returns the key that was pressed.   
   <br/>

```lua
released = E.PollKeyRelease([k])
```

Wait for the user to release the given key, entering nothing will poll for any key, Returns the key that was released.   
   <br/>

```lua
text = E.PollTextInput()
```

Wait for the user to type some text, returns the text typed.   
<br/>

```lua
E.PollHotkey(hotkey)
```

Wait until the user presses a hotkey, given in the following format ```"ctrl+shift+z"```.   
<br/>

```lua
pressed = E.PollMousePress([b])
```

Wait for the user to press the given mouse button (in LÖVE's format), entering nothing will poll for any button. Returns the button that was pressed.   
   <br/>

```lua
released = E.PollMouseRelease([b])
```

Wait for the user to release the given mouse button (in LÖVE's format), entering nothing will poll for any button. Returns the button that was released.   
   <br/>
   
```lua
dw = E.PollMouseWheel()
```

Wait for mouse wheel activity, returns the direction and value of movement.   
   <br/>

```lua
dx, dy = E.PollMouseMove()
```

Wait for the user to move the mouse, returns the change in the mouse's position.   
   <br/>

```lua
activity, ... = E.PollMouseActivity()
```

Wait for the user to do anything with the mouse. The first result is always the name of the activity, the subsequent results depend on what activity was detected.

- ```"MouseMoved"``` returns ```dx, dy```
- ```"MousePressed"``` returns ```button```
- ```"MouseReleased"``` returns ```button```
- ```"MouseWheel"``` returns ```dw```   
   <br/>
   
```lua
E.Wait(t)
```

Wait for the given amount of time in seconds.   
<br/>

```lua
E.PollBranchStatus(id, status)
```

Wait until the given branch reaches a particular status. see ```E.G.GetStatus()``` for more information.   
<br/>

```lua
E.Die()
```

Kill the currently running branch.   
<br/>

```lua
id = E.GetID()
```

Get the ID of the currently running timeline.   
<br/>

```lua
E.WaitForTimeline(id)
```

Wait until the given timeline finishes.   
<br/>

```lua
E.WaitForBranches([id])
```

Wait until the given timeline's branches finish, ```id``` defaults to the currently running timeline.   
<br/>

```lua
E.When(f)
```

Wait until the given function ```f``` returns ```true```.

### Universal Functions

```lua
dt = E.G.GetDeltaTime()
```

Simply returns the ```dt``` value given for this current ```love.update``` frame.   
<br/>

```lua
frame = E.G.GetFrame()
```

Returns the number of frames that have elapsed up to this point.   
<br/>

```lua
E.G.KillBranches([id])
```

Kill all the branches of a given timeline, if no ```id``` is given, it will default to the currently running timeline or give an error if outside.   
<br/>

```lua
E.G.Kill(id)
```

Kill the timeline given by ```id```, if no ```id``` is given then it has the same functionality as ```E.Die()```.   
<br/>

```lua
is_done = E.G.IsDone(id)
```

Returns whether or not a timeline has finished.   
<br/>

```lua
is_running = E.G.IsRunning(id)
```

Returns whether or not a timeline is actively running right now.
<br/>

```lua
status = E.G.Status(id)
```

Returns the ```status``` of a timeline, the statuses are the following:

- ```"Dead"``` means this timeline has finished
- ```"Running"``` means this timeline is currently running
- ```"Normal"``` means one of this timeline's branches are running
- ```"Suspended"``` means this timeline is alive but not currently active

### Outside Functions

```lua
id = E.O.Do([type,] run, ...)
```

Will create and update a new timeline internally without needing to call ```E.O.Step(id)```. Returns the ```id``` of the created timeline.

### Input Events

Only call these if you don't want to use ```E.O.Attach()```.

```lua 
E.O.update(dt)
```
```lua
E.O.keypressed(k)
```
```lua 
E.O.keyreleased(k)
```
```lua 
E.O.mousemoved(x, y, dx, dy)
```
```lua 
E.O.wheelmoved(dx, dy)
```
```lua 
E.O.mousepressed(x, y, button)
```
```lua 
E.O.mousereleased(x, y, button)
```
```lua 
E.O.textinput(text, ...)
```

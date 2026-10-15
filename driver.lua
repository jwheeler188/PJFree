--[[
  PJFree - PJLink Projector (Class 1) - Control4 DriverWorks driver - v5
  https://github.com/jwheeler188/PJFree

  AI code generation was used in the production and testing of this driver.
  No warranty is provided. Please report bugs so the driver can be improved.
  Released into the public domain under The Unlicense (https://unlicense.org).

  Supports: power on/off, discrete input select, AV mute, status polling
  (power, input, lamp hours, error status, name), PJLink password auth (MD5).
  Port 4352 TCP. Projector closes idle sockets after ~30s, so the driver
  connects on demand, drains its command queue, then disconnects.
]]

local NET_BINDING   = 6001
local PROXY_BINDING = 5001
local PJ_PORT       = 4352

local RESPONSE_TIMEOUT_MS = 5000
local CONNECT_TIMEOUT_MS  = 6000
local IDLE_DISCONNECT_MS  = 3000
local BUSY_RETRY_MS       = 5000   -- retry interval when projector answers ERR3 (warming up)
local BUSY_MAX_TRIES      = 24     -- ~2 minutes of retries

-- Control4 video input binding -> property holding its PJLink INPT code
local INPUTS = {
  [2000] = "HDMI 1 PJLink Code",
  [2001] = "HDMI 2 PJLink Code",
  [2002] = "Computer 1 PJLink Code",
  [2003] = "Computer 2 PJLink Code",
  [2004] = "Memory Viewer PJLink Code",
  [2005] = "Network / USB PJLink Code",
}

local POWER_NAMES = { ["0"] = "Off", ["1"] = "On", ["2"] = "Cooling", ["3"] = "Warming Up" }
local ERR_NAMES = {
  ERR1 = "Undefined command",
  ERR2 = "Out of parameter",
  ERR3 = "Unavailable time (busy/warming/off)",
  ERR4 = "Projector failure",
  ERRA = "Authentication error (check password)",
}

-- State
gQueue        = {}
gBuf          = ""
gConnected    = false
gConnecting   = false
gReady        = false     -- greeting received
gAuthPrefix   = ""
gAuthUsed     = false
gAwaiting     = nil       -- queue item waiting for a response
gFails        = 0
gPowerVal     = nil       -- "0".."3"
gIsOn         = nil
gInputCode    = nil
gPollCount    = 0

gTimers = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function dbg(s)
  if Properties["Debug Mode"] == "On" then
    print("PJLink: " .. tostring(s))
  end
end

local function setProp(name, value)
  value = tostring(value or "")
  if Properties[name] ~= value then
    C4:UpdateProperty(name, value)
  end
end

local function killTimer(key)
  if gTimers[key] then
    gTimers[key]:Cancel()
    gTimers[key] = nil
  end
end

local function startTimer(key, ms, fn, rep)
  killTimer(key)
  gTimers[key] = C4:SetTimer(ms, function(timer)
    if not rep then gTimers[key] = nil end
    fn(timer)
  end, rep or false)
end

local function md5hex(s)
  local h = C4:Hash("MD5", s, { return_encoding = "HEX" })
  return string.lower(h or "")
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function inputCodeFor(binding)
  local prop = INPUTS[tonumber(binding)]
  if not prop then return nil end
  local code = trim(Properties[prop])
  if code == "" then return nil end
  return code
end

local function bindingForCode(code)
  for binding, prop in pairs(INPUTS) do
    if trim(Properties[prop]) == code then return binding, prop end
  end
  return nil
end

------------------------------------------------------------------------
-- Connection / queue
------------------------------------------------------------------------
local Pump -- forward declaration

local function Disconnect()
  killTimer("idle")
  killTimer("connect")
  if gConnected or gConnecting then
    C4:NetDisconnect(NET_BINDING, PJ_PORT)
  end
end

local function Connect()
  if gConnected or gConnecting then return end
  gConnecting = true
  gReady = false
  gBuf = ""
  dbg("Connecting...")
  C4:NetConnect(NET_BINDING, PJ_PORT)
  startTimer("connect", CONNECT_TIMEOUT_MS, function()
    if not gReady then
      dbg("Connect/greeting timeout")
      setProp("Connection Status", "No response from projector")
      gConnecting = false
      C4:NetDisconnect(NET_BINDING, PJ_PORT)
      gQueue = {}
    end
  end)
end

function Send(cmd, tries)
  cmd = trim(cmd)
  if cmd == "" then return end
  -- de-dupe queries already waiting in the queue
  if cmd:sub(-1) == "?" then
    for _, item in ipairs(gQueue) do
      if item.cmd == cmd then return end
    end
  end
  table.insert(gQueue, { cmd = cmd, tries = tries or 0 })
  Pump()
end

Pump = function()
  if #gQueue == 0 then
    if gConnected and not gAwaiting then
      startTimer("idle", IDLE_DISCONNECT_MS, function()
        if #gQueue == 0 and not gAwaiting then Disconnect() end
      end)
    end
    return
  end
  killTimer("idle")

  if not gConnected then Connect() return end
  if not gReady or gAwaiting then return end

  local item = table.remove(gQueue, 1)
  gAwaiting = item

  local out = "%1" .. item.cmd .. "\r"
  if gAuthPrefix ~= "" and (not gAuthUsed or Properties["Send Auth With Every Command"] == "Yes") then
    out = gAuthPrefix .. out
    gAuthUsed = true
  end

  dbg("TX: " .. out:gsub("\r", "\\r"))
  C4:SendToNetwork(NET_BINDING, PJ_PORT, out)

  startTimer("response", RESPONSE_TIMEOUT_MS, function()
    dbg("No response to " .. (gAwaiting and gAwaiting.cmd or "?"))
    gAwaiting = nil
    gFails = gFails + 1
    if gFails >= 3 then
      gFails = 0
      gQueue = {}
      setProp("Connection Status", "Not responding")
      Disconnect()
    else
      Pump()
    end
  end)
end

------------------------------------------------------------------------
-- State updates
------------------------------------------------------------------------
local function UpdatePower(val)
  local name = POWER_NAMES[val]
  if not name then return end
  gPowerVal = val
  setProp("Power State", name)
  C4:SetVariable("POWER_STATE", name)

  local on = (val == "1" or val == "3")
  if on ~= gIsOn then
    gIsOn = on
    C4:SetVariable("POWER_ON", on and "1" or "0")
    C4:SendToProxy(PROXY_BINDING, on and "ON" or "OFF", {})
  end

  -- poll faster through warm-up / cool-down
  if val == "2" or val == "3" then
    startTimer("transition", 5000, function() Send("POWR ?") end)
  elseif val == "1" then
    Send("INPT ?")
  end
end

local function UpdateInput(code)
  gInputCode = code
  local binding, prop = bindingForCode(code)
  local label = binding and prop:gsub(" PJLink Code$", "") or ("Code " .. code)
  setProp("Current Input", label .. " (" .. code .. ")")
  C4:SetVariable("INPUT", label)
  if binding then
    C4:SendToProxy(PROXY_BINDING, "INPUT_CHANGED", { INPUT = binding })
  end
end

local function UpdateErrors(val)
  -- 6 digits: fan, lamp, temp, cover, filter, other. 0=ok 1=warning 2=error
  local names = { "Fan", "Lamp", "Temp", "Cover", "Filter", "Other" }
  local levels = { ["1"] = "Warning", ["2"] = "Error" }
  local out = {}
  for i = 1, 6 do
    local lvl = levels[val:sub(i, i)]
    if lvl then table.insert(out, names[i] .. " " .. lvl) end
  end
  local s = (#out == 0) and "OK" or table.concat(out, ", ")
  setProp("Error Status", s)
  C4:SetVariable("ERROR_STATUS", s)
end

local function HandleResponse(cmd, val)
  killTimer("response")
  local item = gAwaiting
  gAwaiting = nil
  gFails = 0
  val = trim(val)
  dbg("RX: " .. cmd .. "=" .. val)

  if val:match("^ERR") then
    if val == "ERR3" and item and (cmd == "INPT" or cmd == "AVMT") and item.tries < BUSY_MAX_TRIES then
      dbg("Projector busy, retrying " .. item.cmd)
      local c, t = item.cmd, item.tries + 1
      C4:SetTimer(BUSY_RETRY_MS, function() Send(c, t) end)
    elseif val == "ERRA" then
      setProp("Connection Status", ERR_NAMES.ERRA)
    else
      dbg(cmd .. " -> " .. (ERR_NAMES[val] or val))
    end
    Pump()
    return
  end

  if cmd == "POWR" then
    if val == "OK" then
      Send("POWR ?")
    else
      UpdatePower(val)
    end
  elseif cmd == "INPT" then
    if val == "OK" then
      Send("INPT ?")
    else
      UpdateInput(val)
    end
  elseif cmd == "LAMP" then
    -- "hours on/off [hours on/off ...]" - report every lamp's hours
    local hrs = {}
    local i = 0
    for tok in val:gmatch("%S+") do
      i = i + 1
      if i % 2 == 1 then table.insert(hrs, tok) end
    end
    local s = table.concat(hrs, " / ")
    setProp("Lamp Hours", s)
    C4:SetVariable("LAMP_HOURS", s)
  elseif cmd == "ERST" then
    UpdateErrors(val)
  elseif cmd == "NAME" then
    setProp("Projector Name", val)
  elseif cmd == "INST" then
    print("PJLink projector inputs available: " .. val)
  elseif cmd == "AVMT" then
    if val == "OK" then
      Send("AVMT ?")
    else
      local muted = (val == "31" or val == "11" or val == "21")
      C4:SetVariable("AV_MUTE", muted and "1" or "0")
    end
  end

  Pump()
end

local function HandleLine(line)
  line = line:gsub("\n", "")
  if line == "" then return end

  if line:match("^PJLINK 0") then
    killTimer("connect")
    gAuthPrefix, gAuthUsed, gReady = "", false, true
    setProp("Connection Status", "Connected (no auth)")
    Pump()
  elseif line:match("^PJLINK 1") then
    killTimer("connect")
    local rand = line:match("^PJLINK 1 (%S+)") or ""
    local pw = Properties["Password"] or ""
    gAuthPrefix = md5hex(rand .. pw)
    gAuthUsed, gReady = false, true
    setProp("Connection Status", pw == "" and "Projector requires a password - set Password" or "Connected (auth)")
    Pump()
  elseif line:match("^PJLINK ERRA") then
    killTimer("response")
    gAwaiting = nil
    gQueue = {}
    setProp("Connection Status", ERR_NAMES.ERRA)
    Disconnect()
  else
    local cmd, val = line:match("^%%1(%u%u%u%u)=(.*)$")
    if cmd then
      HandleResponse(cmd, val)
    else
      dbg("Unparsed: " .. line)
    end
  end
end

------------------------------------------------------------------------
-- Polling
------------------------------------------------------------------------
function Poll()
  gPollCount = gPollCount + 1
  Send("POWR ?")
  if gIsOn then Send("INPT ?") end
  if gPollCount % 10 == 1 then
    Send("ERST ?")
    Send("LAMP ?")
  end
end

local function StartPolling()
  killTimer("poll")
  local secs = tonumber(Properties["Poll Interval (seconds)"]) or 30
  if secs > 0 and trim(Properties["IP Address"]) ~= "" then
    startTimer("poll", secs * 1000, Poll, true)
  end
end

function QueryAll()
  Send("NAME ?")
  Send("POWR ?")
  Send("INPT ?")
  Send("AVMT ?")
  Send("ERST ?")
  Send("LAMP ?")
end

------------------------------------------------------------------------
-- Control4 entry points
------------------------------------------------------------------------
function OnDriverInit()
  C4:AddVariable("POWER_STATE", "Unknown", "STRING")
  C4:AddVariable("POWER_ON", "0", "BOOL")
  C4:AddVariable("INPUT", "", "STRING")
  C4:AddVariable("AV_MUTE", "0", "BOOL")
  C4:AddVariable("LAMP_HOURS", "", "STRING")
  C4:AddVariable("ERROR_STATUS", "", "STRING")
end

function OnDriverLateInit()
  for k, _ in pairs(Properties) do
    OnPropertyChanged(k)
  end
  StartPolling()
  C4:SetTimer(3000, function() QueryAll() end)
end

function OnDriverDestroyed()
  for k, _ in pairs(gTimers) do killTimer(k) end
  Disconnect()
end

function OnPropertyChanged(strProperty)
  local val = Properties[strProperty]
  if strProperty == "IP Address" then
    local ip = trim(val)
    if ip ~= "" then
      C4:CreateNetworkConnection(NET_BINDING, ip)
      StartPolling()
      C4:SetTimer(1000, function() QueryAll() end)
    end
  elseif strProperty == "Poll Interval (seconds)" then
    StartPolling()
  elseif strProperty == "Password" then
    Disconnect() -- next command reconnects and re-hashes
  elseif INPUTS and strProperty:match("PJLink Code$") and gInputCode then
    UpdateInput(gInputCode)
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  if idBinding ~= NET_BINDING then return end
  dbg("Connection " .. tostring(strStatus))
  if strStatus == "ONLINE" then
    gConnected, gConnecting = true, false
    -- wait for the PJLINK greeting before sending anything
  else
    gConnected, gConnecting, gReady = false, false, false
    killTimer("response")
    if gAwaiting then
      -- projector dropped mid-command: put it back once
      if gAwaiting.tries < 1 then
        gAwaiting.tries = gAwaiting.tries + 1
        table.insert(gQueue, 1, gAwaiting)
      end
      gAwaiting = nil
    end
    if #gQueue > 0 then
      C4:SetTimer(1000, function() Pump() end)
    end
  end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  if idBinding ~= NET_BINDING then return end
  gBuf = gBuf .. strData
  while true do
    local s, e = gBuf:find("\r", 1, true)
    if not s then break end
    local line = gBuf:sub(1, s - 1)
    gBuf = gBuf:sub(e + 1)
    HandleLine(line)
  end
  if #gBuf > 1024 then gBuf = "" end
end

local function PowerOn()  Send("POWR 1") end
local function PowerOff() Send("POWR 0") end

local function SelectInput(binding)
  local code = inputCodeFor(binding)
  if not code then
    dbg("No PJLink code for input binding " .. tostring(binding))
    return
  end
  if gPowerVal ~= "1" and gPowerVal ~= "3" then
    PowerOn()
  end
  -- ERR3 (still warming) is retried automatically
  Send("INPT " .. code)
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  dbg("Proxy: " .. tostring(strCommand))
  if strCommand == "ON" then
    PowerOn()
  elseif strCommand == "OFF" then
    PowerOff()
  elseif strCommand == "SET_INPUT" then
    SelectInput(tParams.INPUT)
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" then
    local a = tParams.ACTION
    if a == "QueryStatus" then QueryAll()
    elseif a == "PowerOn" then PowerOn()
    elseif a == "PowerOff" then PowerOff()
    elseif a == "ListInputs" then Send("INST ?")
    end
  elseif strCommand == "Power On" then
    PowerOn()
  elseif strCommand == "Power Off" then
    PowerOff()
  elseif strCommand == "AV Mute On" then
    Send("AVMT 31")
  elseif strCommand == "AV Mute Off" then
    Send("AVMT 30")
  elseif strCommand == "Send PJLink Command" then
    local c = trim(tParams["Command"]):gsub("^%%1", "")
    Send(c)
  end
end

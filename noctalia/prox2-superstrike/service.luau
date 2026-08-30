--!nonstrict
-- The service is the only entry allowed to invoke px2. Widget and panel entries
-- exchange plain command/status tables with it through noctalia.state.

local SCHEMA_VERSION = 1
local MIN_REFRESH_SECONDS = 5
local MAX_REFRESH_SECONDS = 300

local busy = false
local lastCommandId = nil
local lastPollMs = 0
local snapshot = nil
local lastAction = nil
local lastError = nil
local connection = "auto"

local function configuredConnection()
  local value = noctalia.getConfig("connection")
  if value == "direct" or value == "receiver" then return value end
  return "auto"
end

local function refreshSeconds()
  local value = math.floor(tonumber(noctalia.getConfig("refresh_interval")) or 15)
  return math.max(MIN_REFRESH_SECONDS, math.min(MAX_REFRESH_SECONDS, value))
end

local function publish()
  noctalia.state.set("device_status", {
    available = noctalia.commandExists("px2"),
    busy = busy,
    connection = connection,
    snapshot = snapshot,
    action = lastAction,
    error = lastError,
    updated_at_ms = lastPollMs,
  })
end

local function errorText(result, fallback)
  local text = noctalia.string.trim(result.stderr or "")
  if text == "" then text = fallback end
  return text
end

local function validInteger(value, minimum, maximum)
  local number = tonumber(value)
  if number == nil or number ~= math.floor(number) then return nil end
  if number < minimum or number > maximum then return nil end
  return number
end

local function validConnection(value)
  return value == "auto" or value == "direct" or value == "receiver"
end

local function refresh()
  if busy then return end
  if not noctalia.commandExists("px2") then
    lastError = "px2 is not installed or is not available on PATH."
    publish()
    return
  end

  busy = true
  publish()
  local accepted = noctalia.runAsync({ "px2", "snapshot", "--json", "--connection", connection }, function(result)
    busy = false
    lastPollMs = noctalia.nowMs()
    if result.exitCode ~= 0 then
      snapshot = nil
      lastError = errorText(result, "Unable to read the mouse.")
      publish()
      return
    end

    local decoded, decodeError = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" or decoded.schema_version ~= SCHEMA_VERSION then
      snapshot = nil
      lastError = decodeError or "px2 returned an unsupported snapshot schema."
      publish()
      return
    end

    snapshot = decoded
    lastError = nil
    publish()
  end)

  if not accepted then
    busy = false
    lastError = "Noctalia could not start px2."
    publish()
  end
end

local function actionArgs(command)
  local action = command.action
  if action == "set-dpi" then
    local value = validInteger(command.value, 100, 44000)
    local profile = validInteger(command.profile, 1, 5)
    if value == nil or profile == nil then return nil, "Invalid DPI or profile." end
    return { "px2", "set", "dpi", tostring(value), "--profile", tostring(profile), "--json", "--connection", connection }
  elseif action == "set-rate" then
    local value = validInteger(command.value, 125, 8000)
    local profile = validInteger(command.profile, 1, 5)
    local allowed = { [125] = true, [250] = true, [500] = true, [1000] = true, [2000] = true, [4000] = true, [8000] = true }
    if not allowed[value] or profile == nil then return nil, "Invalid polling rate or profile." end
    return { "px2", "set", "rate", tostring(value), "--profile", tostring(profile), "--json", "--connection", connection }
  elseif action == "activate-profile" then
    local profile = validInteger(command.profile, 1, 5)
    if profile == nil then return nil, "Invalid profile." end
    return { "px2", "profile", "activate", tostring(profile), "--json", "--connection", connection }
  elseif action == "initialize-profile" then
    local profile = validInteger(command.profile, 1, 5)
    if profile == nil then return nil, "Invalid profile." end
    return { "px2", "profile", "initialize", tostring(profile), "--from-factory", "--json", "--connection", connection }
  elseif action == "set-hits" then
    local target = command.target
    if target ~= "left" and target ~= "right" and target ~= "both" then return nil, "Invalid HITS target." end
    local actuation = validInteger(command.actuation, 1, 255)
    local rapid = validInteger(command.rapid, 1, 255)
    local haptics = validInteger(command.haptics, 0, 255)
    if actuation == nil or rapid == nil or haptics == nil then return nil, "Invalid HITS values." end
    return {
      "px2", "set", "hits", target,
      "--actuation", tostring(actuation), "--rapid", tostring(rapid), "--haptics", tostring(haptics),
      "--json", "--connection", connection,
    }
  end
  return nil, "Unknown action."
end

local function runAction(command)
  if busy then
    lastAction = { id = command.id, ok = false, error = "Another mouse operation is already running." }
    publish()
    return
  end

  local argv, validationError = actionArgs(command)
  if argv == nil then
    lastAction = { id = command.id, ok = false, error = validationError }
    publish()
    return
  end

  busy = true
  lastError = nil
  lastAction = { id = command.id, action = command.action, pending = true }
  publish()
  local accepted = noctalia.runAsync(argv, function(result)
    busy = false
    if result.exitCode ~= 0 then
      local message = errorText(result, "px2 rejected the operation.")
      lastAction = { id = command.id, action = command.action, ok = false, error = message }
      lastError = message
      publish()
      return
    end

    local response = noctalia.json.decode(result.stdout or "")
    lastAction = { id = command.id, action = command.action, ok = true, response = response }
    lastError = nil
    publish()
    refresh()
  end)

  if not accepted then
    busy = false
    lastAction = { id = command.id, action = command.action, ok = false, error = "Noctalia could not start px2." }
    publish()
  end
end

local function handleCommand(command)
  if type(command) ~= "table" or command.id == nil or command.id == lastCommandId then return end
  lastCommandId = command.id

  if command.action == "refresh" then
    refresh()
  elseif command.action == "set-connection" then
    if validConnection(command.connection) then
      connection = command.connection
      snapshot = nil
      lastError = nil
      publish()
      refresh()
    end
  else
    runAction(command)
  end
end

function update()
  local now = noctalia.nowMs()
  if lastPollMs == 0 or now - lastPollMs >= refreshSeconds() * 1000 then refresh() end
end

function onConfigChanged()
  connection = configuredConnection()
  lastPollMs = 0
  refresh()
end

function onIpc(event, payload)
  if event == "refresh" then
    handleCommand({ id = noctalia.nowMs(), action = "refresh" })
  elseif event == "connection" and validConnection(payload) then
    handleCommand({ id = noctalia.nowMs(), action = "set-connection", connection = payload })
  end
end

connection = configuredConnection()
noctalia.setUpdateInterval(1000)
noctalia.state.watch("device_command", handleCommand)
publish()
refresh()

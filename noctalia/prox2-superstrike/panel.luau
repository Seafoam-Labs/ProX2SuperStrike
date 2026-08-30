--!nonstrict

local status = noctalia.state.get("device_status")
local selectedProfile = 1
local leftHits = { actuation = 1, rapid = 1, haptics = 0 }
local rightHits = { actuation = 1, rapid = 1, haptics = 0 }
local connectionOptions = { "Automatic", "Direct USB", "LIGHTSPEED receiver" }
local connectionValues = { "auto", "direct", "receiver" }
local render

local function send(action)
  action.id = noctalia.nowMs()
  noctalia.state.set("device_command", action)
end

local function section(title, children)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    ui.column({ gap = 8 }, children),
  })
end

local function activeProfile(data)
  local profiles = data.profiles or {}
  for _, profile in ipairs(profiles) do
    if profile.sector == selectedProfile then return profile end
  end
  return nil
end

local function connectionIndex(value)
  for index, item in ipairs(connectionValues) do
    if item == value then return index - 1 end
  end
  return 0
end

local function rateIndex(rates, value)
  for index, rate in ipairs(rates) do
    if rate == value then return index - 1 end
  end
  return 0
end

local function statusBody()
  if type(status) ~= "table" or not status.available then
    return { ui.label({ text = "px2 is not installed or not available on PATH.", color = "error", wrap = true }) }
  end
  if type(status.snapshot) ~= "table" then
    return {
      ui.label({ text = status.busy and "Reading the mouse…" or "Mouse unavailable", fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = status.error or "Connect the cable or LIGHTSPEED receiver and check hidraw permissions.", color = "error", wrap = true }),
      ui.button({ text = "Retry", glyph = "refresh", onClick = "onRefresh", enabled = not status.busy }),
    }
  end

  local data = status.snapshot
  local battery = data.battery or {}
  local device = data.device or {}
  local reported = data.reported or {}
  local supported = data.supported or {}
  local rates = supported.rates_hz or { 125, 250, 500, 1000 }
  local rateLabels = {}
  for _, rate in ipairs(rates) do table.insert(rateLabels, `{rate} Hz`) end
  local profile = activeProfile(data)
  local dpi = if profile ~= nil and profile.crc_valid then profile.dpi_x else reported.dpi_x or 800
  local savedRate = if profile ~= nil and profile.crc_valid then profile.rate_hz else reported.rate_hz or rates[1]
  local hits = data.hits or {}
  local caps = hits.capabilities or { max_actuation = 10, max_rapid_trigger = 5, max_haptics = 5 }
  local busy = status.busy == true

  local profileButtons = {}
  for _, item in ipairs(data.profiles or {}) do
    local number = item.sector
    local label = if item.active then `Profile {number} · active` else `Profile {number}`
    table.insert(profileButtons, ui.button({
      text = label,
      variant = number == selectedProfile and "primary" or "outline",
      enabled = not busy,
      onClick = function()
        selectedProfile = number
        render()
      end,
    }))
  end

  local actionMessage = ""
  local actionColor = "on_surface_variant"
  if type(status.action) == "table" then
    if status.action.pending then
      actionMessage = "Applying change…"
      actionColor = "primary"
    elseif status.action.ok then
      actionMessage = "Change applied and verified."
      actionColor = "primary"
    elseif status.action.error then
      actionMessage = status.action.error
      actionColor = "error"
    end
  end

  return {
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = "mouse", size = 28, color = battery.percent <= 15 and "error" or "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = device.name or "PRO X2 SUPERSTRIKE", fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = `{battery.percent or "?"}%{battery.charging and " · charging" or ""} · {device.connection or status.connection}`, color = "on_surface_variant" }),
      }),
      ui.button({ glyph = "refresh", onClick = "onRefresh", enabled = not busy }),
    }),

    section("Connection", {
      ui.select({ options = connectionOptions, selectedIndex = connectionIndex(status.connection), onChange = "onConnection", enabled = not busy }),
    }),

    section("Profiles", {
      ui.row({ gap = 6, wrap = true }, profileButtons),
      ui.button({ text = `Activate profile {selectedProfile}`, onClick = "onActivateProfile", enabled = not busy, variant = "outline" }),
      if profile ~= nil and not profile.crc_valid
        then ui.label({ text = "This writable profile does not contain a valid px2 profile image; persistent DPI/rate writes are disabled.", color = "error", wrap = true })
        else ui.label({ text = `Profile {selectedProfile} · {dpi} DPI · {savedRate} Hz`, color = "on_surface_variant" }),
    }),

    section("DPI", {
      ui.input({ key = `dpi-{selectedProfile}`, value = tostring(dpi), placeholder = "100–44000", onSubmit = "onDpiSubmit", enabled = not busy and profile ~= nil and profile.crc_valid }),
      ui.label({ text = "Enter a DPI value and press Enter. Persistent writes create and verify a backup.", color = "on_surface_variant", wrap = true }),
    }),

    section("Polling rate", {
      ui.select({ options = rateLabels, selectedIndex = rateIndex(rates, savedRate), onChange = "onRate", enabled = not busy and profile ~= nil and profile.crc_valid }),
    }),

    section("Left HITS", {
      ui.label({ text = `Actuation · {leftHits.actuation}` }),
      ui.slider({ min = 1, max = caps.max_actuation, step = 1, value = leftHits.actuation, onChange = "onLeftActuation", enabled = not busy }),
      ui.label({ text = `Rapid trigger · {leftHits.rapid}` }),
      ui.slider({ min = 1, max = caps.max_rapid_trigger, step = 1, value = leftHits.rapid, onChange = "onLeftRapid", enabled = not busy }),
      ui.label({ text = `Haptics · {leftHits.haptics}` }),
      ui.slider({ min = 0, max = caps.max_haptics, step = 1, value = leftHits.haptics, onChange = "onLeftHaptics", enabled = not busy }),
      ui.button({ text = "Apply left HITS", onClick = "onApplyLeft", enabled = not busy, variant = "primary" }),
    }),

    section("Right HITS", {
      ui.label({ text = `Actuation · {rightHits.actuation}` }),
      ui.slider({ min = 1, max = caps.max_actuation, step = 1, value = rightHits.actuation, onChange = "onRightActuation", enabled = not busy }),
      ui.label({ text = `Rapid trigger · {rightHits.rapid}` }),
      ui.slider({ min = 1, max = caps.max_rapid_trigger, step = 1, value = rightHits.rapid, onChange = "onRightRapid", enabled = not busy }),
      ui.label({ text = `Haptics · {rightHits.haptics}` }),
      ui.slider({ min = 0, max = caps.max_haptics, step = 1, value = rightHits.haptics, onChange = "onRightHaptics", enabled = not busy }),
      ui.button({ text = "Apply right HITS", onClick = "onApplyRight", enabled = not busy, variant = "primary" }),
    }),

    if actionMessage ~= "" then ui.label({ text = actionMessage, color = actionColor, wrap = true }) else ui.spacer({ height = 1 }),
  }
end

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = "PRO X2 SUPERSTRIKE", fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 16 }, statusBody()),
  }))
end

local function syncStatus(value)
  if type(value) == "table" then status = value end
  local data = if type(status) == "table" then status.snapshot else nil
  if type(data) == "table" then
    selectedProfile = data.active_profile or selectedProfile
    local hits = data.hits or {}
    if type(hits.left) == "table" then
      leftHits = { actuation = hits.left.actuation, rapid = hits.left.rapid_trigger, haptics = hits.left.haptics }
    end
    if type(hits.right) == "table" then
      rightHits = { actuation = hits.right.actuation, rapid = hits.right.rapid_trigger, haptics = hits.right.haptics }
    end
  end
  render()
end

function onOpen(_context)
  syncStatus(noctalia.state.get("device_status"))
  send({ action = "refresh" })
end

function onRefresh() send({ action = "refresh" }) end
function onCloseClicked() panel.close() end

function onConnection(index, _text)
  local value = connectionValues[(tonumber(index) or 0) + 1]
  if value ~= nil then send({ action = "set-connection", connection = value }) end
end

function onActivateProfile() send({ action = "activate-profile", profile = selectedProfile }) end

function onDpiSubmit(value)
  local dpi = tonumber(value)
  if dpi == nil then return end
  send({ action = "set-dpi", profile = selectedProfile, value = dpi })
end

function onRate(index, _text)
  local data = status and status.snapshot
  local rates = data and data.supported and data.supported.rates_hz or {}
  local rate = rates[(tonumber(index) or 0) + 1]
  if rate ~= nil then send({ action = "set-rate", profile = selectedProfile, value = rate }) end
end

function onLeftActuation(value) leftHits.actuation = math.floor(tonumber(value) or leftHits.actuation); render() end
function onLeftRapid(value) leftHits.rapid = math.floor(tonumber(value) or leftHits.rapid); render() end
function onLeftHaptics(value) leftHits.haptics = math.floor(tonumber(value) or leftHits.haptics); render() end
function onRightActuation(value) rightHits.actuation = math.floor(tonumber(value) or rightHits.actuation); render() end
function onRightRapid(value) rightHits.rapid = math.floor(tonumber(value) or rightHits.rapid); render() end
function onRightHaptics(value) rightHits.haptics = math.floor(tonumber(value) or rightHits.haptics); render() end

function onApplyLeft()
  send({ action = "set-hits", target = "left", actuation = leftHits.actuation, rapid = leftHits.rapid, haptics = leftHits.haptics })
end

function onApplyRight()
  send({ action = "set-hits", target = "right", actuation = rightHits.actuation, rapid = rightHits.rapid, haptics = rightHits.haptics })
end

noctalia.state.watch("device_status", syncStatus)

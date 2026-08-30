--!nonstrict

local status = noctalia.state.get("device_status")

local function applyStatus(value)
  if type(value) == "table" then status = value end
  local showBattery = noctalia.getConfig("show_battery") ~= false

  if type(status) ~= "table" or not status.available then
    barWidget.setGlyph("mouse-off")
    barWidget.setGlyphColor("error")
    barWidget.setText(showBattery and "px2?" or "")
    barWidget.setTooltip("px2 is not available")
    return
  end

  local data = status.snapshot
  if type(data) ~= "table" then
    barWidget.setGlyph("mouse-off")
    barWidget.setGlyphColor(status.busy and "primary" or "error")
    barWidget.setText(showBattery and "--" or "")
    barWidget.setTooltip(status.error or (status.busy and "Reading mouse…" or "Mouse disconnected"))
    return
  end

  local battery = data.battery or {}
  local percent = tonumber(battery.percent) or 0
  barWidget.setGlyph("mouse")
  barWidget.setText(showBattery and `{percent}%` or "")
  if percent <= 15 then
    barWidget.setGlyphColor("error")
  elseif battery.charging then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("on_surface")
  end

  local device = data.device or {}
  local reported = data.reported or {}
  local charging = battery.charging and " · charging" or ""
  barWidget.setTooltip(
    `{device.name or "PRO X2 SUPERSTRIKE"}\n{percent}%{charging}\n{device.connection or status.connection} · {reported.dpi_x or "?"} DPI · {reported.rate_hz or "?"} Hz · profile {data.active_profile or "?"}`
  )
end

function onClick()
  noctalia.togglePanel("prox2-superstrike/prox2-superstrike:control")
end

function onRightClick()
  noctalia.state.set("device_command", { id = noctalia.nowMs(), action = "refresh" })
end

function update()
  noctalia.setUpdateInterval(30000)
  applyStatus(status)
end

noctalia.state.watch("device_status", applyStatus)
applyStatus(status)

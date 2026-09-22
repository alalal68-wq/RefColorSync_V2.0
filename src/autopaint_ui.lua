-- autopaint_ui.lua: non-modal controls and progress display for Auto-Paint.

local autopaintUi = { dialog = nil }

local CONFIRM_REMAINING_PIXELS = 5000
local BAR_WIDTH = 280
local BAR_HEIGHT = 14

local function formatInteger(value)
  local text = tostring(math.floor(tonumber(value) or 0))
  while true do
    local replaced, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    text = replaced
    if count == 0 then return text end
  end
end

local function orderLabel(order)
  return order == "random" and "Random" or "Raster"
end

local function orderValue(label)
  return label == "Random" and "random" or "raster"
end

function autopaintUi.show(config, watcher, autopaint)
  if autopaintUi.dialog then
    app.alert("The Auto-Paint dialog is already open")
    return
  end

  local cfg = config.getAll()
  local progressValue = 0
  local dlg

  local function isOpen()
    return autopaintUi.dialog == dlg
  end

  local function setProgress(value)
    progressValue = math.max(0, math.min(100, tonumber(value) or 0))
    if isOpen() then pcall(function() dlg:repaint() end) end
  end

  local function setStatus(text)
    if isOpen() then dlg:modify{ id = "progressText", text = text } end
  end

  local settingIds = {
    "referenceLayerName",
    "sampleFromComposite",
    "autopaintOrder",
    "autopaintTicksPerSecond",
    "autopaintPixelsPerTick"
  }

  local function setRunning(running)
    if not isOpen() then return end
    for _, id in ipairs(settingIds) do
      dlg:modify{ id = id, enabled = not running }
    end
    dlg:modify{ id = "start", enabled = not running }
    dlg:modify{ id = "stop", enabled = running }
    dlg:modify{ id = "close", enabled = not running }
  end

  local function callbacks()
    return {
      onProgress = function(info)
        if not isOpen() then return end
        setProgress(info.progress)

        if info.phase == "scanning" then
          setStatus(string.format(
            "Preparing: %d%% (%s pixels queued)",
            info.progress,
            formatInteger(info.queued)))
        elseif info.phase == "shuffling" then
          setStatus(string.format("Preparing random order: %d%%", info.progress))
        else
          setStatus(string.format(
            "Painted %s | Processed %s / %s",
            formatInteger(info.painted),
            formatInteger(info.processed),
            formatInteger(info.total)))
        end
      end,

      onComplete = function(info)
        if not isOpen() then return end
        setProgress(100)
        setRunning(false)
        setStatus(string.format(
          "Done: painted %s pixels in %s queue steps",
          formatInteger(info.painted),
          formatInteger(info.total)))
        app.alert(string.format("Done! Painted %s pixels.", formatInteger(info.painted)))
      end,

      onEmpty = function()
        if not isOpen() then return end
        setProgress(0)
        setRunning(false)
        setStatus("Nothing to paint")
        app.alert("Nothing to paint: all source pixels are transparent or the target is already filled.")
      end,

      onStopped = function(info)
        if not isOpen() then return end
        setRunning(false)
        setStatus(string.format("Stopped. Painted %s pixels.", formatInteger(info.painted)))
      end,

      onError = function(info)
        if not isOpen() then return end
        setRunning(false)
        setStatus("Stopped because of an error")
        app.alert{
          title = "Auto-Paint Error",
          text = {
            tostring(info.error),
            "The error was also written to the Aseprite console."
          }
        }
      end
    }
  end

  dlg = Dialog{
    title = "RefColorSync: Auto-Paint from Reference",
    onclose = function()
      if autopaintUi.dialog == dlg then autopaintUi.dialog = nil end
      if autopaint.isRunning() then autopaint.stop("dialog_closed", false) end
    end
  }
  autopaintUi.dialog = dlg

  dlg:entry{
    id = "referenceLayerName",
    label = "Reference Layer:",
    text = cfg.referenceLayerName
  }

  dlg:check{
    id = "sampleFromComposite",
    label = "Sample from Composite",
    selected = cfg.sampleFromComposite
  }

  dlg:combobox{
    id = "autopaintOrder",
    label = "Paint Order:",
    option = orderLabel(cfg.autopaintOrder),
    options = { "Raster", "Random" }
  }

  dlg:slider{
    id = "autopaintTicksPerSecond",
    label = "Ticks per Second:",
    min = 1,
    max = 60,
    value = cfg.autopaintTicksPerSecond
  }

  dlg:slider{
    id = "autopaintPixelsPerTick",
    label = "Pixels per Tick:",
    min = 1,
    max = 500,
    value = cfg.autopaintPixelsPerTick
  }

  dlg:separator{ text = "Progress" }

  dlg:label{
    id = "progressText",
    text = "Ready"
  }

  dlg:canvas{
    id = "progressBar",
    width = BAR_WIDTH,
    height = BAR_HEIGHT,
    autoscaling = true,
    onpaint = function(event)
      local context = event.context
      context.color = Color{ r = 55, g = 58, b = 66, a = 255 }
      context:fillRect(Rectangle(0, 0, BAR_WIDTH, BAR_HEIGHT))

      local filled = math.floor((BAR_WIDTH - 2) * progressValue / 100)
      if filled > 0 then
        context.color = Color{ r = 67, g = 156, b = 255, a = 255 }
        context:fillRect(Rectangle(1, 1, filled, BAR_HEIGHT - 2))
      end
    end
  }

  dlg:button{
    id = "start",
    text = "Start",
    focus = true,
    onclick = function()
      if autopaint.isRunning() then return end

      local data = dlg.data
      if not data.referenceLayerName or data.referenceLayerName:match("^%s*$") then
        app.alert("Reference layer name cannot be empty")
        return
      end

      config.update({
        referenceLayerName = data.referenceLayerName,
        sampleFromComposite = data.sampleFromComposite,
        autopaintOrder = orderValue(data.autopaintOrder),
        autopaintTicksPerSecond = data.autopaintTicksPerSecond,
        autopaintPixelsPerTick = data.autopaintPixelsPerTick
      })

      -- The watcher and Auto-Paint intentionally share their source settings.
      if watcher.isRunning() then
        local watcherOk = watcher.updateConfig(config.getAll())
        config.set("enabled", watcherOk)
      end

      setProgress(0)
      setStatus("Preparing source and queue...")
      setRunning(true)

      local ok, err = autopaint.start(config.getAll(), callbacks())
      if not ok then
        setRunning(false)
        setStatus("Ready")
        app.alert(err)
      end
    end
  }

  dlg:button{
    id = "stop",
    text = "Stop",
    enabled = false,
    onclick = function()
      local status = autopaint.getStatus()
      if not status then return end

      if status.remaining > CONFIRM_REMAINING_PIXELS then
        local result = app.alert{
          title = "Stop Auto-Paint?",
          text = string.format(
            "%s pixels are still pending. Already painted pixels will remain.",
            formatInteger(status.remaining)),
          buttons = { "Stop", "Continue" }
        }
        if result ~= 1 then return end
      end

      autopaint.stop("user", true)
    end
  }

  dlg:button{ id = "close", text = "Close" }
  dlg:show{ wait = false }
end

function autopaintUi.shutdown(autopaint)
  if autopaint.isRunning() then autopaint.stop("extension_exit", false) end
  if autopaintUi.dialog then
    local dlg = autopaintUi.dialog
    autopaintUi.dialog = nil
    pcall(function() dlg:close() end)
  end
end

return autopaintUi

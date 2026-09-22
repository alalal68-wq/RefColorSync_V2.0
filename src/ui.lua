-- ui.lua: settings dialog for cursor-based RefColorSync sampling.

local ui = {}

local function valuesFromDialog(dlg)
  local data = dlg.data
  if not data.referenceLayerName or data.referenceLayerName:match("^%s*$") then
    return nil, "Reference layer name cannot be empty"
  end

  return {
    referenceLayerName = data.referenceLayerName,
    ticksPerSecond = data.ticksPerSecond,
    ignoreTransparent = data.ignoreTransparent,
    sampleFromComposite = data.sampleFromComposite
  }
end

function ui.showSettings(config, watcher)
  local cfg = config.getAll()
  local dlg = Dialog("RefColorSync Settings")

  dlg:entry{
    id = "referenceLayerName",
    label = "Reference Layer Name:",
    text = cfg.referenceLayerName
  }

  dlg:slider{
    id = "ticksPerSecond",
    label = "Update Frequency (Hz):",
    min = 15,
    max = 40,
    value = cfg.ticksPerSecond
  }

  dlg:check{
    id = "ignoreTransparent",
    label = "Ignore Transparent Pixels",
    selected = cfg.ignoreTransparent
  }

  dlg:check{
    id = "sampleFromComposite",
    label = "Sample from Composite",
    selected = cfg.sampleFromComposite
  }

  dlg:separator()

  dlg:button{
    id = "toggleWatching",
    text = watcher.isRunning() and "Disable Watching" or "Enable Watching",
    onclick = function()
      if watcher.isRunning() then
        watcher.stop()
        config.set("enabled", false)
        dlg:modify{ id = "toggleWatching", text = "Enable Watching" }
        return
      end

      local values, err = valuesFromDialog(dlg)
      if not values then
        app.alert(err)
        return
      end

      config.update(values)
      local ok = watcher.start(config.getAll())
      config.set("enabled", ok)
      if ok then
        dlg:modify{ id = "toggleWatching", text = "Disable Watching" }
      end
    end
  }

  dlg:button{
    id = "save",
    text = "Save Settings",
    onclick = function()
      local values, err = valuesFromDialog(dlg)
      if not values then
        app.alert(err)
        return
      end

      config.update(values)
      if watcher.isRunning() then
        local ok = watcher.updateConfig(config.getAll())
        config.set("enabled", ok)
        if not ok then
          dlg:modify{ id = "toggleWatching", text = "Enable Watching" }
          return
        end
      end

      app.alert("Settings saved")
    end
  }

  dlg:button{ id = "close", text = "Close" }
  dlg:show{ wait = false }
end

return ui

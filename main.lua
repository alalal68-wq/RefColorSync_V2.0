-- main.lua: entry point for the RefColorSync extension.

local config = dofile('./src/config.lua')
local watcher = dofile('./src/watcher.lua')
local ui = dofile('./src/ui.lua')
local autopaint = dofile('./src/autopaint.lua')
local autopaintUi = dofile('./src/autopaint_ui.lua')

function init(plugin)
  config.init(plugin)

  plugin:newCommand{
    id = "RefColorSyncToggle",
    title = "Toggle RefColorSync",
    group = "file_scripts",
    onclick = function()
      if watcher.isRunning() then
        watcher.stop()
        config.set("enabled", false)
      else
        local ok = watcher.start(config.getAll())
        config.set("enabled", ok)
      end
    end
  }

  plugin:newCommand{
    id = "RefColorSyncSettings",
    title = "RefColorSync Settings...",
    group = "file_scripts",
    onclick = function()
      ui.showSettings(config, watcher)
    end
  }

  plugin:newCommand{
    id = "RefColorSyncAutoPaint",
    title = "RefColorSync: Auto-Paint from Reference...",
    group = "file_scripts",
    onclick = function()
      autopaintUi.show(config, watcher, autopaint)
    end
  }

  if config.get("enabled") then
    local ok = watcher.start(config.getAll())
    if not ok then config.set("enabled", false) end
  end
end

function exit(plugin)
  autopaintUi.shutdown(autopaint)
  if watcher.isRunning() then watcher.stop() end
end

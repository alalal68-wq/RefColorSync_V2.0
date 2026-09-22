-- watcher.lua: timer-based cursor monitoring and foreground-color sampling.

local sampler = dofile('./sampler.lua')

local watcher = {
  timer = nil,
  lastPos = nil,
  lastFrameNumber = nil,
  lastSprite = nil,
  observedSprite = nil,
  spriteChangeListener = nil,
  running = false,
  dirty = true,
  config = nil
}

local function disconnectSpriteEvents()
  if watcher.observedSprite and watcher.spriteChangeListener then
    pcall(function()
      watcher.observedSprite.events:off(watcher.spriteChangeListener)
    end)
  end
  watcher.observedSprite = nil
  watcher.spriteChangeListener = nil
end

local function observeSprite(sprite)
  disconnectSpriteEvents()
  watcher.observedSprite = sprite

  local ok, listener = pcall(function()
    return sprite.events:on("change", function()
      if watcher.observedSprite == sprite then
        watcher.dirty = true
        sampler.reset()
      end
    end)
  end)
  if ok then watcher.spriteChangeListener = listener end
end

local function tick()
  if not app.editor or not app.editor.sprite then return end

  local sprite = app.editor.sprite
  local spritePos = app.editor.spritePos
  if not spritePos then return end

  if watcher.lastSprite ~= sprite then
    sampler.reset()
    observeSprite(sprite)
    watcher.lastSprite = sprite
    watcher.lastPos = nil
    watcher.lastFrameNumber = nil
    watcher.dirty = true
  end

  local frame = app.frame
  if not frame or frame.sprite ~= sprite then frame = sprite.frames[1] end
  if not frame then return end

  local samePosition = watcher.lastPos
    and watcher.lastPos.x == spritePos.x
    and watcher.lastPos.y == spritePos.y
  local sameFrame = watcher.lastFrameNumber == frame.frameNumber
  if samePosition and sameFrame and not watcher.dirty then return end

  local color = sampler.getColorAt(
    sprite,
    frame,
    spritePos.x,
    spritePos.y,
    watcher.config)
  if color then app.fgColor = color end

  -- Cache only after a successful tick so errors are never hidden by the position cache.
  watcher.lastPos = { x = spritePos.x, y = spritePos.y }
  watcher.lastFrameNumber = frame.frameNumber
  watcher.dirty = false
end

local function onTick()
  local ok, err = pcall(tick)
  if not ok then
    print("RefColorSync watcher error: " .. tostring(err))
    watcher.stop()
  end
end

function watcher.start(config)
  if app.version and app.version < Version("1.3.0") then
    app.alert("RefColorSync requires Aseprite v1.3 or newer")
    return false
  end

  if app.sprite and not config.sampleFromComposite then
    local layer = sampler.findLayer(app.sprite.layers, config.referenceLayerName)
    if not layer then
      app.alert("Reference layer '" .. config.referenceLayerName .. "' not found in active sprite")
      return false
    end
    if layer.isTilemap then
      app.alert("The reference layer cannot be a tilemap layer")
      return false
    end
  end

  if watcher.running then watcher.stop() end

  watcher.config = config
  watcher.lastPos = nil
  watcher.lastFrameNumber = nil
  watcher.lastSprite = nil
  watcher.dirty = true
  sampler.reset()

  local ticksPerSecond = tonumber(config.ticksPerSecond) or 25
  ticksPerSecond = math.max(15, math.min(40, math.floor(ticksPerSecond)))

  watcher.timer = Timer{
    interval = 1.0 / ticksPerSecond,
    ontick = onTick
  }
  watcher.timer:start()
  watcher.running = true
  return true
end

function watcher.stop()
  if watcher.timer then
    watcher.timer:stop()
    watcher.timer = nil
  end

  disconnectSpriteEvents()
  watcher.running = false
  watcher.lastPos = nil
  watcher.lastFrameNumber = nil
  watcher.lastSprite = nil
  watcher.dirty = true
  sampler.reset()
end

function watcher.isRunning()
  return watcher.running
end

function watcher.updateConfig(config)
  local wasRunning = watcher.running
  if wasRunning then
    watcher.stop()
    return watcher.start(config)
  end
  watcher.config = config
  return true
end

return watcher

-- sampler.lua: reads pixels from reference sources and converts them to Color values.

local sampler = {}

local GRAY_MODE = ColorMode.GRAY or ColorMode.GRAYSCALE

-- Recursive so a reference layer nested in a group is still found.
local function findLayer(layers, name)
  for _, layer in ipairs(layers) do
    if layer.isGroup then
      local found = findLayer(layer.layers, name)
      if found then return found end
    elseif layer.name == name then
      return layer
    end
  end
  return nil
end
sampler.findLayer = findLayer

local function clipBounds(bounds, sprite)
  local x1 = math.max(0, bounds.x)
  local y1 = math.max(0, bounds.y)
  local x2 = math.min(sprite.width, bounds.x + bounds.width)
  local y2 = math.min(sprite.height, bounds.y + bounds.height)

  if x2 <= x1 or y2 <= y1 then return nil end
  return { x = x1, y = y1, width = x2 - x1, height = y2 - y1 }
end

function sampler.isTransparentPixel(px, sprite)
  if px == nil then return true end

  if sprite.colorMode == ColorMode.RGB then
    return app.pixelColor.rgbaA(px) == 0
  elseif sprite.colorMode == GRAY_MODE then
    return app.pixelColor.grayaA(px) == 0
  elseif sprite.colorMode == ColorMode.INDEXED then
    return px == sprite.transparentColor
  end

  return true
end

local function paletteForFrame(sprite, frame)
  local palettes = sprite.palettes
  if not palettes or #palettes == 0 then return nil end
  if #palettes == 1 or not frame then return palettes[1] end

  local frameNumber = frame.frameNumber or 1
  local selected = palettes[1]
  local selectedFrom = 1

  for _, palette in ipairs(palettes) do
    local from = 1
    local ok, marker = pcall(function() return palette.frame end)
    if ok and marker ~= nil then
      if type(marker) == "number" then
        from = marker
      else
        local frameOk, number = pcall(function() return marker.frameNumber end)
        if frameOk and type(number) == "number" then from = number end
      end
    end

    if from <= frameNumber and from >= selectedFrom then
      selected = palette
      selectedFrom = from
    end
  end

  return selected
end

-- Raw pixel value -> Color. Alpha 0 means "transparent" in every color mode.
local function pixelToColor(px, sprite, frame)
  local mode = sprite.colorMode

  if mode == ColorMode.RGB then
    return Color{
      r = app.pixelColor.rgbaR(px),
      g = app.pixelColor.rgbaG(px),
      b = app.pixelColor.rgbaB(px),
      a = app.pixelColor.rgbaA(px)
    }

  elseif mode == GRAY_MODE then
    local value = app.pixelColor.grayaV(px)
    return Color{ r = value, g = value, b = value, a = app.pixelColor.grayaA(px) }

  elseif mode == ColorMode.INDEXED then
    if px == sprite.transparentColor then
      return Color{ r = 0, g = 0, b = 0, a = 0 }
    end

    local palette = paletteForFrame(sprite, frame)
    if palette and px >= 0 and px < #palette then
      local color = palette:getColor(px)
      return Color{ r = color.red, g = color.green, b = color.blue, a = color.alpha }
    end
  end

  return nil
end
sampler.pixelToColor = pixelToColor

-- Composite sampling state used by the cursor watcher.
local dot = nil
local pointSampleWorks = true
local cache = { image = nil, sprite = nil, frameNumber = nil, time = 0 }

local function compositePixel(sprite, frame, x, y)
  -- Fast path: render only the single pixel we need by offsetting the sprite.
  if pointSampleWorks then
    if not dot or dot.colorMode ~= sprite.colorMode then
      dot = Image(1, 1, sprite.colorMode)
    end
    dot:clear()

    local ok = pcall(function()
      dot:drawSprite(sprite, frame, Point(-x, -y))
    end)
    if ok then return dot:getPixel(0, 0) end

    pointSampleWorks = false
  end

  -- Fallback: full composite, rebuilt at most twice per second.
  local now = os.clock()
  if cache.image == nil
     or cache.sprite ~= sprite
     or cache.frameNumber ~= frame.frameNumber
     or (now - cache.time) > 0.5 then
    local image = Image(sprite.spec)
    image:drawSprite(sprite, frame)
    cache.image = image
    cache.sprite = sprite
    cache.frameNumber = frame.frameNumber
    cache.time = now
  end

  return cache.image:getPixel(x, y)
end

-- Returns a raw pixel value, or nil when there is nothing to sample.
function sampler.getPixelAt(sprite, frame, x, y, cfg)
  if not sprite or not frame then return nil end

  if cfg.sampleFromComposite then
    if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height then
      return nil
    end
    return compositePixel(sprite, frame, x, y)
  end

  local layer = findLayer(sprite.layers, cfg.referenceLayerName)
  if not layer or layer.isTilemap then return nil end

  local cel = layer:cel(frame)
  if not cel then return nil end

  local bounds = cel.bounds
  if x < bounds.x or y < bounds.y
     or x >= bounds.x + bounds.width or y >= bounds.y + bounds.height then
    return nil
  end

  return cel.image:getPixel(x - bounds.x, y - bounds.y)
end

-- Returns a Color, or nil when there is nothing to sample.
function sampler.getColorAt(sprite, frame, x, y, cfg)
  local pixel = sampler.getPixelAt(sprite, frame, x, y, cfg)
  if pixel == nil then return nil end

  local color = pixelToColor(pixel, sprite, frame)
  if not color then return nil end
  if cfg.ignoreTransparent and color.alpha == 0 then return nil end

  return color
end

-- Creates an immutable source snapshot for Auto-Paint.
function sampler.createSourceSnapshot(sprite, frame, cfg)
  if cfg.sampleFromComposite then
    local image = Image(sprite.spec)
    image:drawSprite(sprite, frame)
    return {
      image = image,
      originX = 0,
      originY = 0,
      bounds = { x = 0, y = 0, width = sprite.width, height = sprite.height },
      layer = nil
    }
  end

  local layer = findLayer(sprite.layers, cfg.referenceLayerName)
  if not layer then
    return nil, "Reference layer '" .. tostring(cfg.referenceLayerName) .. "' was not found"
  end
  if layer.isTilemap then
    return nil, "The reference layer cannot be a tilemap layer"
  end

  local cel = layer:cel(frame)
  if not cel then
    return nil, "The reference layer has no cel in the selected frame"
  end

  local bounds = clipBounds(cel.bounds, sprite)
  if not bounds then
    return nil, "The reference cel is outside the sprite canvas"
  end

  return {
    image = cel.image:clone(),
    originX = cel.bounds.x,
    originY = cel.bounds.y,
    bounds = bounds,
    layer = layer
  }
end

function sampler.getSnapshotPixel(snapshot, x, y)
  local bounds = snapshot.bounds
  if x < bounds.x or y < bounds.y
     or x >= bounds.x + bounds.width or y >= bounds.y + bounds.height then
    return nil
  end

  return snapshot.image:getPixel(x - snapshot.originX, y - snapshot.originY)
end

-- Drop cached composite data (call on sprite changes / watcher restart).
function sampler.reset()
  cache.image = nil
  cache.sprite = nil
  cache.frameNumber = nil
  cache.time = 0
  dot = nil
  pointSampleWorks = true
end

return sampler

-- autopaint.lua: progressively fills transparent target pixels from a source snapshot.

local sampler = dofile('./sampler.lua')

local autopaint = {}

local PREPARE_INTERVAL = 1.0 / 60.0
local PREPARE_ITEMS_PER_TICK = 20000
local PREPARE_MIN_ITEMS_PER_TICK = 1000
local PREPARE_TIME_BUDGET = 0.010
local RANDOM_MODULUS = 2147483647
local RANDOM_MULTIPLIER = 48271

local current = nil
local nextRunId = 0

local function clampInteger(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not value then return fallback end
  value = math.floor(value)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function safeCallback(run, name, payload)
  local callback = run.callbacks and run.callbacks[name]
  if not callback then return end

  local ok, err = pcall(callback, payload)
  if not ok then
    print("RefColorSync Auto-Paint callback error: " .. tostring(err))
  end
end

local function stopTimer(run)
  if run.timer then
    pcall(function() run.timer:stop() end)
    run.timer = nil
  end
end

local function makeSummary(run, reason, err)
  local total = #run.queue
  return {
    id = run.id,
    phase = run.phase,
    reason = reason,
    error = err,
    painted = run.painted,
    processed = run.processed,
    total = total,
    remaining = math.max(0, total - run.processed),
    preparationSeconds = run.preparationSeconds or (os.clock() - run.startedAt)
  }
end

local function releaseRun(run)
  run.queue = nil
  run.source = nil
  run.targetSnapshot = nil
  run.sprite = nil
  run.layer = nil
  run.frame = nil
  run.targetCel = nil
end

local function finish(run, callbackName, reason, err)
  if current ~= run then return end

  stopTimer(run)
  run.running = false
  local summary = makeSummary(run, reason, err)
  current = nil
  safeCallback(run, callbackName, summary)
  releaseRun(run)
end

local function fail(run, err)
  local message = tostring(err)
  print("RefColorSync Auto-Paint error: " .. message)
  finish(run, "onError", "error", message)
end

local function containsIdentity(items, wanted)
  for _, item in ipairs(items) do
    if item == wanted then return true end
  end
  return false
end

local function containsLayer(layers, wanted)
  for _, layer in ipairs(layers) do
    if layer == wanted then return true end
    if layer.isGroup and containsLayer(layer.layers, wanted) then return true end
  end
  return false
end

local function isSpriteOpen(sprite)
  local ok, sprites = pcall(function() return app.sprites end)
  return ok and sprites and containsIdentity(sprites, sprite)
end

local function isFrameValid(sprite, frame)
  return containsIdentity(sprite.frames, frame)
end

local function isLayerEditable(layer, sprite)
  local node = layer
  while node and node ~= sprite do
    if node.isEditable == false then return false end
    node = node.parent
  end
  return node == sprite
end

local function validateCapturedTarget(run)
  if not isSpriteOpen(run.sprite) then
    return false, "The source sprite was closed"
  end
  if not containsLayer(run.sprite.layers, run.layer) then
    return false, "The target layer was removed"
  end
  if not isFrameValid(run.sprite, run.frame) then
    return false, "The target frame was removed"
  end
  if not isLayerEditable(run.layer, run.sprite) then
    return false, "The target layer is locked"
  end
  return true
end

local function pixelIsEmpty(snapshot, sprite, x, y)
  if not snapshot then return true end

  local bounds = snapshot.bounds
  if x < bounds.x or y < bounds.y
     or x >= bounds.x + bounds.width or y >= bounds.y + bounds.height then
    return true
  end

  local pixel = snapshot.image:getPixel(x - bounds.x, y - bounds.y)
  return sampler.isTransparentPixel(pixel, sprite)
end

local function snapshotTarget(layer, frame)
  local cel = layer:cel(frame)
  if not cel then return nil end

  local bounds = cel.bounds
  return {
    image = cel.image:clone(),
    bounds = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
  }
end

local function makeTransparentImage(sprite, bounds)
  local spec = ImageSpec{
    width = bounds.width,
    height = bounds.height,
    colorMode = sprite.colorMode,
    transparentColor = sprite.transparentColor
  }
  local image = Image(spec)
  image:clear()
  return image
end

local function unionBounds(a, b)
  local x1 = math.min(a.x, b.x)
  local y1 = math.min(a.y, b.y)
  local x2 = math.max(a.x + a.width, b.x + b.width)
  local y2 = math.max(a.y + a.height, b.y + b.height)
  return { x = x1, y = y1, width = x2 - x1, height = y2 - y1 }
end

local function sameBounds(a, b)
  return a.x == b.x and a.y == b.y
     and a.width == b.width and a.height == b.height
end

local function prepareWorkingImage(run)
  local cel = run.layer:cel(run.frame)
  if run.targetCel and cel ~= run.targetCel then
    error("The target cel was removed or replaced")
  end

  if not cel then
    return nil, makeTransparentImage(run.sprite, run.bounds), run.bounds
  end

  local celBounds = cel.bounds
  local currentBounds = {
    x = celBounds.x,
    y = celBounds.y,
    width = celBounds.width,
    height = celBounds.height
  }
  local workingBounds = unionBounds(currentBounds, run.bounds)

  if sameBounds(currentBounds, workingBounds) then
    return cel, cel.image:clone(), workingBounds
  end

  local image = makeTransparentImage(run.sprite, workingBounds)
  image:drawImage(cel.image, Point(
    currentBounds.x - workingBounds.x,
    currentBounds.y - workingBounds.y))
  return cel, image, workingBounds
end

local function writeWorkingImage(run, cel, image, bounds)
  if cel then
    if cel.position.x ~= bounds.x or cel.position.y ~= bounds.y then
      cel.position = Point(bounds.x, bounds.y)
    end
    cel.image = image
    run.targetCel = cel
  else
    run.targetCel = run.sprite:newCel(run.layer, run.frame, image, Point(bounds.x, bounds.y))
  end
end

local function randomIndex(run, maximum)
  run.randomState = (run.randomState * RANDOM_MULTIPLIER) % RANDOM_MODULUS
  return math.floor((run.randomState / RANDOM_MODULUS) * maximum) + 1
end

local function reportPreparation(run, phaseProgress)
  safeCallback(run, "onProgress", {
    phase = run.phase,
    progress = phaseProgress,
    scanned = run.scanCursor,
    candidates = run.scanTotal,
    queued = #run.queue,
    painted = run.painted,
    processed = run.processed,
    total = #run.queue
  })
end

local tickGuard

local function replaceTimer(run, interval)
  stopTimer(run)
  run.timer = Timer{
    interval = interval,
    ontick = function() tickGuard(run) end
  }
  run.timer:start()
end

local function beginPainting(run)
  run.preparationSeconds = os.clock() - run.startedAt
  run.targetSnapshot = nil
  run.phase = "painting"
  run.queueIndex = 1
  run.processed = 0

  safeCallback(run, "onProgress", {
    phase = "painting",
    progress = 0,
    painted = 0,
    processed = 0,
    total = #run.queue
  })
  replaceTimer(run, 1.0 / run.config.ticksPerSecond)
end

local function finishPreparation(run)
  run.preparationSeconds = os.clock() - run.startedAt
  if #run.queue == 0 then
    finish(run, "onEmpty", "empty")
    return
  end

  if run.config.order == "random" and #run.queue > 1 then
    run.phase = "shuffling"
    run.shuffleIndex = #run.queue
    reportPreparation(run, 90)
  else
    beginPainting(run)
  end
end

local function scanQueueTick(run)
  local started = os.clock()
  local count = 0
  local bounds = run.bounds

  while run.scanCursor < run.scanTotal and count < PREPARE_ITEMS_PER_TICK do
    if count >= PREPARE_MIN_ITEMS_PER_TICK
       and (os.clock() - started) >= PREPARE_TIME_BUDGET then
      break
    end

    local offset = run.scanCursor
    local x = bounds.x + (offset % bounds.width)
    local y = bounds.y + math.floor(offset / bounds.width)
    local sourcePixel = sampler.getSnapshotPixel(run.source, x, y)

    if not sampler.isTransparentPixel(sourcePixel, run.sprite)
       and pixelIsEmpty(run.targetSnapshot, run.sprite, x, y) then
      run.queue[#run.queue + 1] = y * run.sprite.width + x
    end

    run.scanCursor = run.scanCursor + 1
    count = count + 1
  end

  local progress = math.floor((run.scanCursor / run.scanTotal) * 90)
  reportPreparation(run, progress)
  if run.scanCursor >= run.scanTotal then finishPreparation(run) end
end

local function shuffleQueueTick(run)
  local started = os.clock()
  local count = 0
  local total = #run.queue

  while run.shuffleIndex > 1 and count < PREPARE_ITEMS_PER_TICK do
    if count >= PREPARE_MIN_ITEMS_PER_TICK
       and (os.clock() - started) >= PREPARE_TIME_BUDGET then
      break
    end

    local index = run.shuffleIndex
    local other = randomIndex(run, index)
    run.queue[index], run.queue[other] = run.queue[other], run.queue[index]
    run.shuffleIndex = index - 1
    count = count + 1
  end

  local shuffled = total - run.shuffleIndex
  local progress = 90 + math.floor((shuffled / math.max(1, total - 1)) * 10)
  reportPreparation(run, math.min(100, progress))
  if run.shuffleIndex <= 1 then beginPainting(run) end
end

local function paintTick(run)
  local valid, message = validateCapturedTarget(run)
  if not valid then error(message) end

  local total = #run.queue
  if run.queueIndex > total then
    finish(run, "onComplete", "complete")
    return
  end

  local first = run.queueIndex
  local last = math.min(total, first + run.config.pixelsPerTick - 1)
  local paintedThisTick = 0

  app.transaction("RefColorSync Auto-Paint", function()
    local cel, image, imageBounds = prepareWorkingImage(run)

    for index = first, last do
      local encoded = run.queue[index]
      local x = encoded % run.sprite.width
      local y = math.floor(encoded / run.sprite.width)
      local imageX = x - imageBounds.x
      local imageY = y - imageBounds.y
      local existingPixel = image:getPixel(imageX, imageY)

      -- Re-check immediately before painting so new hand-drawn work is preserved.
      if sampler.isTransparentPixel(existingPixel, run.sprite) then
        local sourcePixel = sampler.getSnapshotPixel(run.source, x, y)
        if not sampler.isTransparentPixel(sourcePixel, run.sprite) then
          image:drawPixel(imageX, imageY, sourcePixel)
          paintedThisTick = paintedThisTick + 1
        end
      end
    end

    if paintedThisTick > 0 then
      writeWorkingImage(run, cel, image, imageBounds)
    end
  end)

  run.queueIndex = last + 1
  run.processed = last
  run.painted = run.painted + paintedThisTick

  safeCallback(run, "onProgress", {
    phase = "painting",
    progress = math.floor((run.processed / total) * 100),
    painted = run.painted,
    processed = run.processed,
    total = total
  })

  if run.queueIndex > total then
    finish(run, "onComplete", "complete")
  end
end

local function tick(run)
  if current ~= run or not run.running then return end

  if run.phase == "scanning" then
    local valid, message = validateCapturedTarget(run)
    if not valid then error(message) end
    scanQueueTick(run)
  elseif run.phase == "shuffling" then
    local valid, message = validateCapturedTarget(run)
    if not valid then error(message) end
    shuffleQueueTick(run)
  elseif run.phase == "painting" then
    paintTick(run)
  end
end

tickGuard = function(run)
  if current ~= run or not run.running then return end
  local ok, err = pcall(function() tick(run) end)
  if not ok then fail(run, err) end
end

local function normalizeConfig(cfg)
  local name = tostring(cfg.referenceLayerName or "Reference")
  if name:match("^%s*$") then name = "Reference" end

  return {
    referenceLayerName = name,
    sampleFromComposite = cfg.sampleFromComposite == true,
    ticksPerSecond = clampInteger(cfg.autopaintTicksPerSecond, 1, 60, 30),
    pixelsPerTick = clampInteger(cfg.autopaintPixelsPerTick, 1, 500, 50),
    order = cfg.autopaintOrder == "random" and "random" or "raster"
  }
end

local function validateInitialTarget(sprite, layer, frame)
  if not sprite then return false, "Open a sprite before starting Auto-Paint" end
  if not layer then return false, "Select a target layer before starting Auto-Paint" end
  if not frame then return false, "Select a frame before starting Auto-Paint" end
  if layer.isGroup then return false, "The target layer cannot be a group" end
  if layer.isTilemap then return false, "The target layer cannot be a tilemap layer" end
  if layer.isBackground then
    return false, "The target layer must support transparency (background layers are not supported)"
  end
  if layer.isImage == false then return false, "Select a regular image layer" end
  if not isLayerEditable(layer, sprite) then return false, "The target layer is locked" end
  return true
end

function autopaint.start(cfg, callbacks)
  if current then return false, "Auto-Paint is already running" end

  local sprite = app.sprite
  local layer = app.layer
  local frame = app.frame
  local valid, message = validateInitialTarget(sprite, layer, frame)
  if not valid then return false, message end

  local normalized = normalizeConfig(cfg or {})
  local source, sourceError = sampler.createSourceSnapshot(sprite, frame, normalized)
  if not source then return false, sourceError end
  if source.layer and source.layer == layer then
    return false, "The reference layer cannot also be the target layer"
  end

  nextRunId = nextRunId + 1
  local bounds = source.bounds
  local seed = (os.time() + math.floor(os.clock() * 1000000) + nextRunId) % RANDOM_MODULUS
  if seed <= 0 then seed = 1 end

  local run = {
    id = nextRunId,
    running = true,
    phase = "scanning",
    config = normalized,
    callbacks = callbacks or {},
    sprite = sprite,
    layer = layer,
    frame = frame,
    source = source,
    bounds = bounds,
    targetSnapshot = snapshotTarget(layer, frame),
    targetCel = layer:cel(frame),
    queue = {},
    queueIndex = 1,
    scanCursor = 0,
    scanTotal = bounds.width * bounds.height,
    shuffleIndex = 0,
    randomState = seed,
    painted = 0,
    processed = 0,
    startedAt = os.clock(),
    preparationSeconds = nil,
    timer = nil
  }

  current = run
  safeCallback(run, "onProgress", {
    phase = "scanning",
    progress = 0,
    scanned = 0,
    candidates = run.scanTotal,
    queued = 0,
    painted = 0,
    processed = 0,
    total = 0
  })

  local ok, err = pcall(function() replaceTimer(run, PREPARE_INTERVAL) end)
  if not ok then
    fail(run, err)
    return false, tostring(err)
  end

  return true
end

function autopaint.stop(reason, notify)
  local run = current
  if not run then return false end

  stopTimer(run)
  run.running = false
  local summary = makeSummary(run, reason or "stopped")
  current = nil
  if notify ~= false then safeCallback(run, "onStopped", summary) end
  releaseRun(run)
  return true
end

function autopaint.isRunning()
  return current ~= nil and current.running
end

function autopaint.getStatus()
  if not current then return nil end

  local summary = makeSummary(current, "running")
  summary.scanned = current.scanCursor
  summary.candidates = current.scanTotal
  if current.phase == "scanning" then
    summary.remaining = math.max(0, current.scanTotal - current.scanCursor)
  elseif current.phase == "shuffling" then
    summary.remaining = current.shuffleIndex
  end
  return summary
end

return autopaint

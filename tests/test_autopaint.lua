-- tests/test_autopaint.lua: Aseprite-hosted regression tests for Auto-Paint.

local realTimer = Timer
local timers = {}

Timer = function(spec)
  local timer = {
    interval = spec.interval,
    ontick = spec.ontick,
    isRunning = false
  }
  function timer:start() self.isRunning = true end
  function timer:stop() self.isRunning = false end
  timers[#timers + 1] = timer
  return timer
end

local autopaint = dofile('../src/autopaint.lua')
local sampler = dofile('../src/sampler.lua')

local passed = 0
local activeSprite = nil

local function fail(message)
  error(message, 2)
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    fail(string.format(
      "%s (expected %s, got %s)",
      message or "values differ",
      tostring(expected),
      tostring(actual)))
  end
end

local function assertTrue(value, message)
  if not value then fail(message or "expected a truthy value") end
end

local function closeActiveSprite()
  if autopaint.isRunning() then autopaint.stop("test_cleanup", false) end
  if activeSprite then
    pcall(function() activeSprite:close() end)
    activeSprite = nil
  end
end

local function runTest(name, test)
  closeActiveSprite()
  timers = {}
  local ok, err = xpcall(test, debug.traceback)
  closeActiveSprite()
  if not ok then
    print("FAIL: " .. name)
    error(err, 0)
  end
  passed = passed + 1
  print("PASS: " .. name)
end

local function makeSprite(width, height, mode)
  local sprite = Sprite(width, height, mode or ColorMode.RGB)
  local initialCel = sprite.layers[1]:cel(1)
  if initialCel then sprite:deleteCel(initialCel) end
  activeSprite = sprite
  return sprite
end

local function transparentImage(sprite, width, height)
  local image = Image(ImageSpec{
    width = width or sprite.width,
    height = height or sprite.height,
    colorMode = sprite.colorMode,
    transparentColor = sprite.transparentColor
  })
  image:clear()
  return image
end

local function rgba(red, green, blue, alpha)
  return app.pixelColor.rgba(red, green, blue, alpha or 255)
end

local function addImageLayer(sprite, name)
  local layer = sprite:newLayer()
  layer.name = name
  return layer
end

local function addCel(sprite, layer, frame, image, x, y)
  return sprite:newCel(layer, frame or 1, image, Point(x or 0, y or 0))
end

local function selectTarget(sprite, layer, frame)
  app.activeSprite = sprite
  app.activeLayer = layer
  app.activeFrame = frame or sprite.frames[1]
end

local function baseConfig(values)
  local cfg = {
    referenceLayerName = "Reference",
    sampleFromComposite = false,
    autopaintTicksPerSecond = 60,
    autopaintPixelsPerTick = 2,
    autopaintOrder = "raster"
  }
  for key, value in pairs(values or {}) do cfg[key] = value end
  return cfg
end

local function drive(maxTicks)
  maxTicks = maxTicks or 10000
  local ticks = 0
  while autopaint.isRunning() do
    ticks = ticks + 1
    if ticks > maxTicks then fail("Auto-Paint did not finish") end
    local timer = timers[#timers]
    assertTrue(timer and timer.isRunning, "expected a running timer")
    timer.ontick()
  end
  return ticks
end

runTest("raster paint preserves manual pixels and undo is per tick", function()
  local sprite = makeSprite(4, 3, ColorMode.RGB)
  local target = sprite.layers[1]
  target.name = "Target"
  local reference = addImageLayer(sprite, "Reference")

  local source = transparentImage(sprite, 3, 2)
  local sourceColor = rgba(10, 20, 30)
  for y = 0, 1 do
    for x = 0, 2 do source:drawPixel(x, y, sourceColor) end
  end
  addCel(sprite, reference, 1, source, 1, 1)

  local targetImage = transparentImage(sprite)
  local manualColor = rgba(240, 30, 50)
  targetImage:drawPixel(1, 1, manualColor)
  addCel(sprite, target, 1, targetImage)
  selectTarget(sprite, target)

  local completed
  local ok, err = autopaint.start(baseConfig(), {
    onComplete = function(info) completed = info end
  })
  assertTrue(ok, err)
  drive()

  assertEqual(completed.painted, 5, "five transparent target pixels should be painted")
  local result = target:cel(1).image
  assertEqual(result:getPixel(1, 1), manualColor, "manual pixel must be preserved")
  for y = 1, 2 do
    for x = 1, 3 do
      if not (x == 1 and y == 1) then
        assertEqual(result:getPixel(x, y), sourceColor, "source pixel should be copied")
      end
    end
  end
  assertTrue(sampler.isTransparentPixel(result:getPixel(0, 0), sprite), "outside pixels stay empty")

  app.undo()
  result = target:cel(1).image
  assertTrue(sampler.isTransparentPixel(result:getPixel(3, 2), sprite), "one undo reverts the last tick")
  assertEqual(result:getPixel(2, 2), sourceColor, "one undo must not revert earlier ticks")
end)

runTest("small shifted source bounds limit queue preparation", function()
  local sprite = makeSprite(1024, 1024, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite, 16, 16)
  source:drawPixel(0, 0, rgba(1, 2, 3))
  addCel(sprite, reference, 1, source, 500, 600)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig({ autopaintPixelsPerTick = 500 }), {})
  assertTrue(ok, err)
  local status = autopaint.getStatus()
  assertEqual(status.candidates, 256, "only the reference cel bounding box should be scanned")
  drive()
  local cel = target:cel(1)
  assertEqual(cel.bounds.x, 500, "new target cel should start at source x")
  assertEqual(cel.bounds.y, 600, "new target cel should start at source y")
  assertEqual(cel.bounds.width, 16, "new target cel should use source width")
  assertEqual(cel.bounds.height, 16, "new target cel should use source height")
end)

runTest("captured layer and frame remain the target after focus changes", function()
  local sprite = makeSprite(2, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  target.name = "Target"
  local other = addImageLayer(sprite, "Other")
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite, 2, 1)
  source:drawPixel(0, 0, rgba(10, 10, 10))
  source:drawPixel(1, 0, rgba(20, 20, 20))
  addCel(sprite, reference, 1, source)
  sprite:newEmptyFrame(2)
  selectTarget(sprite, target, sprite.frames[1])

  local ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  app.activeLayer = other
  app.activeFrame = sprite.frames[2]
  drive()

  assertTrue(target:cel(1) ~= nil, "captured target cel should be created")
  assertEqual(other:cel(1), nil, "new active layer must stay untouched")
  assertEqual(target:cel(2), nil, "new active frame must stay untouched")
end)

runTest("random order paints every eligible pixel", function()
  local sprite = makeSprite(8, 8, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  local color = rgba(90, 80, 70)
  for y = 0, 7 do
    for x = 0, 7 do source:drawPixel(x, y, color) end
  end
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local complete
  local ok, err = autopaint.start(baseConfig({
    autopaintOrder = "random",
    autopaintPixelsPerTick = 7
  }), { onComplete = function(info) complete = info end })
  assertTrue(ok, err)
  drive()
  assertEqual(complete.painted, 64, "random order should paint all pixels")
end)

runTest("indexed pixels and transparent index are copied correctly", function()
  local sprite = makeSprite(3, 1, ColorMode.INDEXED)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, 1)
  source:drawPixel(1, 0, sprite.transparentColor)
  source:drawPixel(2, 0, 2)
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  drive()
  local result = target:cel(1).image
  assertEqual(result:getPixel(0, 0), 1, "indexed source value one should be copied")
  assertEqual(result:getPixel(1, 0), sprite.transparentColor, "transparent source should be skipped")
  assertEqual(result:getPixel(2, 0), 2, "indexed source value two should be copied")
end)

runTest("grayscale pixels are copied correctly", function()
  local mode = ColorMode.GRAY or ColorMode.GRAYSCALE
  local sprite = makeSprite(2, 1, mode)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  local gray = app.pixelColor.graya(123, 255)
  source:drawPixel(0, 0, gray)
  source:drawPixel(1, 0, app.pixelColor.graya(200, 0))
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  drive()
  local result = target:cel(1).image
  assertEqual(result:getPixel(0, 0), gray, "opaque grayscale source should be copied")
  assertTrue(sampler.isTransparentPixel(result:getPixel(1, 0), sprite), "transparent grayscale source is skipped")
end)

runTest("nested reference layer is found", function()
  local sprite = makeSprite(1, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  local group = sprite:newGroup()
  group.name = "References"
  local reference = sprite:newLayer()
  reference.name = "Reference"
  reference.parent = group
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, rgba(4, 5, 6))
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  drive()
  assertTrue(target:cel(1) ~= nil, "nested reference should paint the target")
end)

runTest("missing source and reference-as-target are rejected", function()
  local sprite = makeSprite(1, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  selectTarget(sprite, target)
  local ok, err = autopaint.start(baseConfig(), {})
  assertEqual(ok, false, "missing reference should fail")
  assertTrue(err:find("not found", 1, true) ~= nil, "missing reference error should be actionable")

  target.name = "Reference"
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, rgba(1, 1, 1))
  addCel(sprite, target, 1, source)
  ok, err = autopaint.start(baseConfig(), {})
  assertEqual(ok, false, "reference layer cannot be the target")
  assertTrue(err:find("cannot also be", 1, true) ~= nil, "same-layer error should be actionable")
end)

runTest("fully painted target reports an empty queue", function()
  local sprite = makeSprite(2, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local color = rgba(22, 33, 44)
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, color)
  source:drawPixel(1, 0, color)
  addCel(sprite, reference, 1, source)
  local filled = transparentImage(sprite)
  filled:drawPixel(0, 0, color)
  filled:drawPixel(1, 0, color)
  addCel(sprite, target, 1, filled)
  selectTarget(sprite, target)

  local empty = false
  local ok, err = autopaint.start(baseConfig(), { onEmpty = function() empty = true end })
  assertTrue(ok, err)
  drive()
  assertTrue(empty, "empty callback should be invoked")
end)

runTest("stopping disposes timer and allows immediate restart", function()
  local sprite = makeSprite(3, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  for x = 0, 2 do source:drawPixel(x, 0, rgba(7, 8, 9)) end
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  local staleTimer = timers[#timers]
  assertTrue(autopaint.stop("test", false), "first stop should succeed")
  assertEqual(staleTimer.isRunning, false, "stale timer should be stopped")
  staleTimer.ontick()
  assertEqual(target:cel(1), nil, "stale timer callback must do nothing")

  ok, err = autopaint.start(baseConfig(), {})
  assertTrue(ok, err)
  drive()
  assertTrue(target:cel(1) ~= nil, "restart should paint normally")
end)

runTest("closing the sprite during preparation is handled", function()
  local sprite = makeSprite(2, 2, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, rgba(1, 2, 3))
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local capturedError
  local ok, err = autopaint.start(baseConfig(), {
    onError = function(info) capturedError = info.error end
  })
  assertTrue(ok, err)
  sprite:close()
  activeSprite = nil
  timers[#timers].ontick()
  assertEqual(autopaint.isRunning(), false, "closed sprite should stop the run")
  assertTrue(capturedError and capturedError:find("closed", 1, true), "closed sprite error should be reported")
end)

runTest("deleting the target layer during preparation is handled", function()
  local sprite = makeSprite(2, 2, ColorMode.RGB)
  local target = sprite.layers[1]
  local reference = addImageLayer(sprite, "Reference")
  local source = transparentImage(sprite)
  source:drawPixel(0, 0, rgba(1, 2, 3))
  addCel(sprite, reference, 1, source)
  selectTarget(sprite, target)

  local capturedError
  local ok, err = autopaint.start(baseConfig(), {
    onError = function(info) capturedError = info.error end
  })
  assertTrue(ok, err)
  sprite:deleteLayer(target)
  timers[#timers].ontick()
  assertEqual(autopaint.isRunning(), false, "deleted target should stop the run")
  assertTrue(capturedError and capturedError:find("removed", 1, true), "deleted target error should be reported")
end)

runTest("composite source snapshot paints visible content", function()
  local sprite = makeSprite(2, 1, ColorMode.RGB)
  local target = sprite.layers[1]
  target.name = "Target"
  local visible = addImageLayer(sprite, "Visible Source")
  local source = transparentImage(sprite)
  local color = rgba(111, 122, 133)
  source:drawPixel(1, 0, color)
  addCel(sprite, visible, 1, source)
  selectTarget(sprite, target)

  local ok, err = autopaint.start(baseConfig({ sampleFromComposite = true }), {})
  assertTrue(ok, err)
  drive()
  local result = target:cel(1).image
  assertEqual(result:getPixel(1, 0), color, "visible composite pixel should be copied")
  assertTrue(sampler.isTransparentPixel(result:getPixel(0, 0), sprite), "transparent composite pixel should be skipped")
end)

Timer = realTimer
closeActiveSprite()
print(string.format("ALL TESTS PASSED (%d)", passed))

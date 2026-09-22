-- tests/test_config.lua: preference validation and command registration smoke tests.

local passed = 0

local function fail(message) error(message, 2) end
local function assertEqual(actual, expected, message)
  if actual ~= expected then
    fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
  end
end
local function assertTrue(value, message)
  if not value then fail(message) end
end

local config = dofile('../src/config.lua')
local plugin = { preferences = {} }
config.init(plugin)

assertEqual(config.get("enabled"), false, "watcher should be disabled by default")
assertEqual(config.get("ticksPerSecond"), 25, "watcher frequency default")
assertEqual(config.get("autopaintTicksPerSecond"), 30, "Auto-Paint frequency default")
assertEqual(config.get("autopaintPixelsPerTick"), 50, "Auto-Paint batch default")
assertEqual(config.get("autopaintOrder"), "raster", "Auto-Paint order default")
passed = passed + 1
print("PASS: configuration defaults")

plugin.preferences.ticksPerSecond = 0
plugin.preferences.autopaintTicksPerSecond = 999
plugin.preferences.autopaintPixelsPerTick = "bad"
plugin.preferences.autopaintOrder = "unknown"
plugin.preferences.referenceLayerName = "   "
plugin.preferences.enabled = "true"
config.init(plugin)

assertEqual(config.get("ticksPerSecond"), 15, "watcher frequency should be clamped")
assertEqual(config.get("autopaintTicksPerSecond"), 60, "Auto-Paint frequency should be clamped")
assertEqual(config.get("autopaintPixelsPerTick"), 50, "invalid batch size should use default")
assertEqual(config.get("autopaintOrder"), "raster", "invalid order should use default")
assertEqual(config.get("referenceLayerName"), "Reference", "blank layer name should use default")
assertEqual(config.get("enabled"), false, "non-boolean enabled value should be rejected")
passed = passed + 1
print("PASS: corrupted preferences are normalized")

config.update({
  ticksPerSecond = 33.8,
  autopaintTicksPerSecond = 7.9,
  autopaintPixelsPerTick = 123.9,
  autopaintOrder = "random",
  unknownKey = "ignored"
})
assertEqual(config.get("ticksPerSecond"), 33, "watcher frequency should be integral")
assertEqual(config.get("autopaintTicksPerSecond"), 7, "Auto-Paint frequency should be integral")
assertEqual(config.get("autopaintPixelsPerTick"), 123, "batch size should be integral")
assertEqual(config.get("autopaintOrder"), "random", "known order should persist")
assertEqual(plugin.preferences.unknownKey, nil, "unknown preferences should not be written")
passed = passed + 1
print("PASS: configuration updates are validated")

-- Load the real entry point with a lightweight plugin boundary.
dofile('../main.lua')
local commands = {}
local commandPlugin = { preferences = {} }
function commandPlugin:newCommand(spec)
  assertTrue(type(spec.id) == "string", "command id should be present")
  assertTrue(type(spec.onclick) == "function", "command callback should be present")
  commands[spec.id] = spec
end

init(commandPlugin)
assertTrue(commands.RefColorSyncToggle ~= nil, "toggle command should be registered")
assertTrue(commands.RefColorSyncSettings ~= nil, "settings command should be registered")
assertTrue(commands.RefColorSyncAutoPaint ~= nil, "Auto-Paint command should be registered")
assertEqual(commands.RefColorSyncAutoPaint.group, "file_scripts", "Auto-Paint should use the scripts menu")
exit(commandPlugin)
passed = passed + 1
print("PASS: extension entry point registers all commands")

print(string.format("ALL TESTS PASSED (%d)", passed))

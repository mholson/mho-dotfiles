-- Relaunch Hammerspoon
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", function()
  hs.reload()
end)
  hs.alert.show("Hammerspoon reloaded")


-- Launch Emacs
hs.hotkey.bind({}, "F1", function()
hs.application.launchOrFocus("Emacs")
end)

-- Launch Xcode
hs.hotkey.bind({}, "F2", function ()
hs.application.launchOrFocus("Xcode")
end)

-- Launch ChatGPT
hs.hotkey.bind({}, "F3", function()
hs.application.launchOrFocus("ChatGPT")
end)

-- Launch Finder
hs.hotkey.bind({}, "F4", function()
hs.application.launchOrFocus("Finder")
end)

-- Launch Keynote
hs.hotkey.bind({}, "F5", function()
hs.application.launchOrFocus("Keynote")
end)

-- Launch Activity Monitor
hs.hotkey.bind({}, "F6", function()
hs.application.launchOrFocus("Activity Monitor")
end)

-- Launch Safari
hs.hotkey.bind({}, "F7", function()
hs.application.launchOrFocus("Safari")
end)

-- Launch Spotify
hs.hotkey.bind({}, "F8", function()
hs.application.launchOrFocus("Spotify")
end)

-- Launch Teams
hs.hotkey.bind({}, "F9", function()
hs.application.launchOrFocus("Microsoft Teams")
end)

-- Launch Outlook
hs.hotkey.bind({}, "F10", function()
hs.application.launchOrFocus("Microsoft Outlook")
end)

-- Launch Calendar
hs.hotkey.bind({"cmd", "alt", "ctrl"}, "C", function()
hs.application.launchOrFocus("Calendar")
end)

-- Launch Terminal
hs.hotkey.bind({}, "F12", function()
hs.application.launchOrFocus("Terminal")
end)

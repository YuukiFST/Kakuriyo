# niri screencast block-out

Kakuriyo cannot hide itself from a full-screen capture on X11 (i3). On **niri** (Wayland), the compositor can replace the window with a black rectangle in portal screencasts (Discord, OBS, Chromium).

Add to `~/.config/niri/config.kdl`:

```kdl
window-rule {
    match app-id="dev.yuukifst.kakuriyo"
    block-out-from "screencast"
}
```

You still see Kakuriyo on the monitor. Discord sees black.

`block-out-from "screen-capture"` also hides it from third-party screenshot tools. Built-in niri screenshot UI still lets you aim; see niri window-rule docs.

Find the live `app-id` with `niri msg pick-window` if the match fails.

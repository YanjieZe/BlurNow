<p align="center"><img src="assets/icon.png" width="128" alt="BlurNow icon"></p>

<h1 align="center">BlurNow</h1>

<p align="center">One click to blur your Mac screen. Touch anything to bring it back.</p>

---

BlurNow is a tiny macOS privacy app. Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd> anywhere and every display is covered, hiding the Dock, menu bar and cursor. Press any key, move or tap the trackpad, scroll, or click, and it fades away.

Think of it as an instant screen saver for when someone walks up behind you.

## Features

- **One shortcut** — press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd> from any app. Press it again, or touch anything, to bring the screen back.
- **Three cover modes** — frosted **blur** with adjustable radius and tint, your **wallpaper** (looks like an empty desktop), or any **image** you pick.
- **Settings window** — click the app icon to change the shortcut, cover mode, blur style and strength, and behavior.
- **Always ready** — runs in the background with no Dock or menu bar icon, and starts at login.
- **All displays** — covers every connected screen.
- **No permissions** — uses the system `NSVisualEffectView` blur and a Carbon global hotkey, so no Screen Recording or Accessibility access is needed.
- **Scriptable** — `blurnow://` URLs for Raycast, Alfred, Shortcuts or the terminal.

## Download

1. Download `BlurNow.zip` from the [latest release](https://github.com/YanjieZe/BlurNow/releases/latest) and unzip it.
2. Move `BlurNow.app` to `/Applications`.
3. The first time, **right-click → Open** (the app is ad-hoc signed, not notarized, so Gatekeeper asks once).

If macOS says the app is damaged, clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/BlurNow.app
```

## Build from source

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/YanjieZe/BlurNow.git
cd BlurNow
./build.sh
cp -R BlurNow.app /Applications/
```

Then drag `BlurNow` from `/Applications` into your Dock, or launch it from Spotlight.

## Settings

Click BlurNow in the Dock, Launchpad or Spotlight to open its settings.

| Setting | Default | What it does |
| --- | --- | --- |
| Shortcut | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd> | Click it, then type a new shortcut. It needs at least one of ⌘, ⌥ or ⌃. <kbd>Esc</kbd> cancels. |
| Show | Blur | **Blur**, **Wallpaper** (your current desktop picture) or **Image** (a file you choose). |
| Style | Auto | Blur tint: follows the system appearance, or force Light / Dark. |
| Blur | More | Blur radius. Turn it down to keep layouts recognizable, up to hide everything. |
| Tint | Clear | Adds an opaque layer on top of the blur. |
| Hide cursor | On | Hide the pointer while covered. |
| Dismiss when the mouse moves | On | Turn off to exit only on keys, clicks and scrolls. |
| Launch at login | On | Start silently in the background after login. |

**Preview** shows the cover right away. **Quit BlurNow** stops the background app.

## URL scheme

```bash
open blurnow://blur       # cover the screen
open blurnow://unblur     # bring it back
open blurnow://toggle
open blurnow://settings
```

## How it works

- One borderless window per screen at `.screenSaver` level, each containing an `NSVisualEffectView` with `.behindWindow` blending. The WindowServer does the blur, so the app never reads screen pixels.
- The blur radius is set through the private `filters.gaussianBlur.inputRadius` key path of the view's `CABackdropLayer`. If a future macOS changes that, BlurNow falls back to the system default radius.
- `LSUIElement` keeps it out of the Dock and the app switcher; it only shows up while the settings window is open.
- The shortcut is registered with Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
- Launch at login uses `SMAppService.mainApp`. When launched as a login item, BlurNow starts silently without blurring.
- Exit is triggered by local and global `NSEvent` monitors, a 50 ms cursor-position poll (robust across multiple displays), and losing focus.

## Limitations

- If **Reduce transparency** is on (System Settings → Accessibility → Display), the blur becomes a solid overlay.
- This is a privacy screen, not a lock screen. Anyone who touches the keyboard can dismiss it. Use <kbd>Ctrl</kbd>+<kbd>Cmd</kbd>+<kbd>Q</kbd> when you need a real lock.

## Regenerating the icon

```bash
swift make_icon.swift assets/icon.png
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) assets/icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## License

[MIT](LICENSE)

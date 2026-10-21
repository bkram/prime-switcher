# Using Prime Switcher

Prime Switcher has two routing sections: **App → Interface** and **Interface → Interface**. Select either at the top of the window. Switching sections leaves existing routes running.

## Before you start

Install the packaged app on macOS 14.2 or later and connect your audio devices. For interface input capture, allow **Microphone** access. For application capture, allow **System Audio Recording** access. The **Privacy Settings…** button in each section opens the relevant macOS privacy settings.

Start with a playing source and verify the destination by listening. The route meter helps identify a signal, but cannot confirm speaker wiring or audibility.

## Send an application to an output

1. Open the source application. Start playback if it does not appear in Prime Switcher.
2. Select **App → Interface** and click **Add Route…**.
3. Choose the application and output device.
4. Choose a mono output channel or stereo pair.
5. Click **Add Route**, then switch the saved route on.
6. Grant capture access if prompted and confirm audio at the selected output.

Each application can have one saved route, including routes switched off. Applications already assigned to a route are excluded from the new-route picker. Edit the existing route to change that app’s destination.

Click **Edit…** or double-click an app route to change it. Switch it off to restore the application’s normal playback without deleting the connection. To delete app routes, select them and press Delete, or use the context menu.

Multiple app routes can share output channels; their audio is mixed. The new-route editor suggests an unused stereo pair when available, but you can choose another output.

## Forward interface inputs

1. Select **Interface → Interface** and click **Add Route…**.
2. Choose the **Input Interface** and **Output Interface**.
3. Set **Channel Count**, **First Input Channel**, and **First Output Channel**.
4. Click **Save Route**, then switch the route on.
5. Feed audio into the input and confirm it reaches the selected output channels.

Channel numbers start at 1. Channels connect in order as one contiguous group:

| Setting | Example |
| --- | --- |
| Channel Count | 4 |
| First Input Channel | 3 |
| First Output Channel | 9 |
| Result | 3 → 9, 4 → 10, 5 → 11, 6 → 12 |

Choose any channel count that fits both devices. This route sends no signal to its unused output channels. Arbitrary channel reordering is not available.

Click **Edit…** to change the connection. Switching it off keeps the settings; the remove button deletes it.

## Saved routes and window behavior

New routes start off. Sources, destinations, channels, switch states, and the selected section are saved locally. Enabled routes are attempted again on launch. If a source app or device is absent, the route waits for it. App routes rebuild when the application’s audio processes change.

Closing the main window leaves routing active. Quitting stops routing and preserves the saved switch states for the next launch. To prevent routes from restarting, turn them off before quitting.

| Action | Control |
| --- | --- |
| Add an app route from either section | **⌘N** |
| Show the main window | **⌘0**, or **Window → Show Prime Switcher** |
| Refresh applications and interfaces | **⌘R**, or **Routes → Refresh Applications and Interfaces** |
| Stop all routes and save every switch as off | **Routes → Turn Off All Routes** |
| Quit | **⌘Q** |

## Understand route status

| Status | What to do |
| --- | --- |
| **Off** | Switch the route on when you want to use it. |
| **Audio passing** | A signal is detected; confirm the intended physical output. |
| **Waiting for audio** | Start playback or check the input signal. Silence during pauses is normal. |
| **Waiting for … to open** | Open the source application and start playback if needed. |
| **… is not connected** / **Waiting for connected devices** | Reconnect the saved device, or edit the route to select another. |
| Error message | Resolve the reported issue, then switch the route off and on. |

## Troubleshooting

### An application or device is missing

Open the app, start playback, and click **Refresh**. If the app already has a saved route, edit that route instead of adding another. Check that external devices are connected and visible in **Audio MIDI Setup**.

### Permission was denied

Click **Privacy Settings…** in the affected section and enable access for Prime Switcher. Interface inputs, including external line inputs, use Microphone permission. Application capture uses System Audio Recording permission; the exact settings label can vary with macOS.

Relaunch if macOS requests it, then switch the route off and on. Refresh alone does not retry a failed app route when its configuration is unchanged.

For source builds, test permissions with the packaged `.app`. A terminal-launched executable may receive a different permission identity.

### The meter moves but there is no sound

Check the output device, selected channels, device volume, and speaker or headphone connections. A virtual device such as BlackHole passes audio to software rather than playing through speakers itself. To listen to that signal, add an interface route from the virtual device’s inputs to a physical output.

### A sample-rate or format error appears

App routes require matching sample rates between the application tap and destination streams, using 32-bit floating-point PCM. In **Audio MIDI Setup**, match the destination rate to the rate reported in the error, then switch the route off and on. App routing does not convert sample rates.

Interface routes use the input device’s sample rate. Check both devices’ rates and available channels if the route cannot start. Bluetooth, AirPlay, HDMI, and unusual multichannel layouts need verification with the actual devices.

### All forwarding needs to stop

Choose **Routes → Turn Off All Routes**. This disables both sections and saves all switches as off. Quitting also stops routing, but retains enabled switch states for the next launch.

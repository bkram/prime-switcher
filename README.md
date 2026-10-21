# Prime Switcher

Send application audio and audio interface inputs to the outputs you choose on macOS. Keep multiple connections saved and switch each one on or off independently.

Requires **macOS 14.2 or later**. Packaged builds contain both Apple silicon and Intel executables.

## Start routing

1. Open `PrimeSwitcher.dmg` and drag **Prime Switcher.app** to **Applications**.
2. Launch Prime Switcher and choose a section:

   | Section | Use it to… |
   | --- | --- |
   | **App → Interface** | Send one application to a mono output or stereo pair. |
   | **Interface → Interface** | Forward a contiguous group of input channels to output channels. |

3. Click **Add Route…**, choose the source, output, and channels, then save.
4. Turn on the route’s switch. Allow the requested macOS audio permission.
5. Play audio and check the intended speakers or physical outputs.

New routes start **off**. Both sections can run at the same time. Routes and switch states are saved automatically; enabled routes are attempted again on launch when their sources and destinations are available.

Closing the window keeps routing active. Press **⌘0** to reopen it, or **⌘Q** to quit and stop routing. **Routes → Turn Off All Routes** stops forwarding and saves every switch as off.

Read the [user guide](docs/USER_GUIDE.md) for channel setup, permissions, shortcuts, and troubleshooting.

## Route applications

Choose a separate destination for each application—for example, a music player to outputs 3–4 and a browser to outputs 5–6 of a multichannel interface. Each app can have one saved route. App routes sharing output channels are mixed.

While a route runs, it captures and redirects the selected app’s playback. Turning it off restores the app’s normal output and keeps the route saved.

![Cog routed to BlackHole outputs 3–4 with a live meter](images/app-to-interface.png)

## Route interface inputs

Forward mono, stereo, or larger channel groups. Selecting four channels starting at input 3 and output 9 connects **3 → 9, 4 → 10, 5 → 11, and 6 → 12**. Arbitrary channel reordering is not available.

![Interface routes mapping inputs 3–6 to outputs 9–12 and inputs 9–10 to speakers](images/interface-to-interface.png)

Virtual devices such as BlackHole work as routing destinations when installed separately. A virtual device needs another audio path to reach physical speakers.

## Build locally

Use full Xcode with Swift 6.2 or newer. From the repository root:

```sh
make run    # Build and launch locally
make dist   # Create dist/Prime Switcher.app
make dmg    # Create dist/PrimeSwitcher.dmg
```

Use the packaged app to test permissions. Packaging uses ad-hoc signing by default and does not notarize the app.

- [Development guide](docs/DEVELOPMENT.md): toolchain, checks, architecture, and packaging.
- [Release checks](docs/RELEASE_CHECKS.md): hardware verification and release evidence.
- [Earlier routing proposal](MACOS_PER_APP_AUDIO_ROUTER_DEVELOPMENT.md): historical design context.

## Compatibility and limits

Application routing requires matching tap/output sample rates and 32-bit floating-point PCM streams; it does not perform sample-rate conversion. Interface routing also depends on the device pair accepting the configured format. Bluetooth, AirPlay, HDMI, and unusual channel layouts need device-specific verification.

A moving meter shows a detected signal. Always confirm sound at the intended output. See the [troubleshooting guide](docs/USER_GUIDE.md#troubleshooting) if a route is silent or reports an error.

## License

[GNU General Public License v3.0](LICENSE).

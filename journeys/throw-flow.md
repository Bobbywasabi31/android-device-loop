# journeys/throw-flow.md

Example Journey for **Throw Assistant** (`Bobbywasabi31/overlay-app`).

Per the [official docs](https://developer.android.com/tools/agents/android-cli/journeys),
a journey is natural-language instructions that the **agent** converts into
device interactions (via `android screen` annotated screenshots,
`android layout` UI trees, and `adb shell input`). The agent runs each step
in order; the journey fails if any step fails or the app crashes/exits.

Journey definition (XML — the documented format):

```xml
<journey name="Throw Assistant smoke">
  <description>
    Install is done via adb beforehand. Launch the app, grant the
    "Display over other apps" permission, confirm the overlay service
    starts, enable dry-run mode, and verify the detector initializes.
    Safe on a lab device: dry-run means no real taps are ever sent.
  </description>
  <actions>
    <action>
      Open the app drawer and tap the Throw Assistant app icon.
    </action>
    <action>
      If a "Display over other apps" permission prompt appears, grant it.
      Verify the app's main screen is visible afterward.
    </action>
    <action>
      Verify the overlay control (floating button / debug HUD entry point)
      is visible on screen.
    </action>
    <action>
      Open the app settings and enable dry-run mode. Confirm the
      dry-run indicator is shown.
    </action>
    <action>
      Verify the detector reports initialized/ready state in the UI
      (or in logcat under the app's tag) without crashing.
    </action>
    <action>
      Press Home, then reopen the app from recents. Verify the overlay
      control is still present (service survived backgrounding).
    </action>
  </actions>
</journey>
```

Evidence to pull after the run (regardless of pass/fail):

- `android screen capture --annotate -o journey-end.png`
- `adb logcat -d` filtered on the app's package/tag
- `android layout --pretty` if a step's assertion is disputed

Notes:

- Steps must be robust to permission-dialog wording differences across
  API levels — prefer "verify visible" assertions over pixel positions.
- Keep the whole journey under ~5 minutes: the free tier is 30 min/month.
- What this does NOT cover: actual ring detection against gameplay.
  That still needs a real phone with the game running (see README).

# Debug Helper

### Requirements

- [NoitaDearImGui](https://github.com/dextercd/Noita-Dear-ImGui/releases)
- [Component Explorer](https://github.com/dextercd/Noita-Component-Explorer)
- `Unsafe mods` enabled in the game's `Mods` menu. The mod does not run without it.

### Installation

- Press the [Download](https://github.com/lamia-zamia/debug_helper/archive/refs/heads/master.zip) button
- Extract the contents into your Noita `mods` folder.
- Rename the folder from `debug_helper-master` to `debug_helper`.
- Enable NoitaDearImGui, Component Explorer and Debug Helper in the `Mods` menu.

## Pixel scenes

Open `View` > `Debug Helper` > `Pixel scenes`.

Draws a box around every pixel scene overlapping the screen, whichever mod or part of the game added it. The boxes are not drawn while the game is paused.

Hover a box to see the scene's file, position, size and state:

- `queued`: the game has the scene but has not processed it, usually because its chunks are not loaded.
- `old`: the game has processed the scene and will not try again. This does not prove it was placed successfully.

## Profiler

Measures what the game spends each frame on, split by mod, script, engine system and material.

Disabled by default since it slightly affects performance. To enable it, turn on `Profiler` in `Mods` > `Mod settings` > `Debug Helper`, then restart the game.

Two entries then appear under `View` > `Debug Helper`:

- `Profiler`: a window with a frame graph and tabs. It stays open while the game is paused.
- `Profiler overlay`: the graph, the last hitch and the largest offenders on top of the game window. It takes no mouse or keyboard input.

The window's tabs:

- `What's lagging`: everything using the frame, largest first. Start here.
- `Mods`: each mod's own Lua and compile time, down to individual functions.
- `Spikes`: frames over 33.3 ms of work, worst first, with what took the most time in each.
- `Entities`: engine time per entity file.
- `Components`: every component type in the world, with counts and which mods' files they came from.
- `All items`: one sortable list of everything, with filters.

`Span` sets the time range of the graph and every tab, from 5 seconds to the whole session. `Freeze` stops them at one moment.

### Output files

All in `mods/debug_helper`:

- `profiler_report.txt`: a plain text summary and detail for the whole session, rewritten every 600 frames. Send this file when reporting lag, and copy it before playing again.
- `profiler_output/spike_1.json` to `spike_8.json`: the 8 worst spikes, saved automatically. To view one, drag it into [ui.perfetto.dev](https://ui.perfetto.dev), which processes it in your browser.
- `profiler_output/manual.json`: written by `Save trace`, viewed the same way.
- `profiler_output/frames.csv`: written by `Save CSV`, up to the last 18,000 frames.
- `profiler_install.log`: each install step. After a crash at startup, its last line shows how far it got.

### Limitations

- Checked on the Steam builds of Noita only. On another build the profiler could crash the game (unverified).
- Lua's JIT compiler is off while the profiler is on, so mods doing heavy Lua calculations can run slower.
- A mod's ranking counts only its own Lua. A mod that spawns many entities can rank low while causing most of the lag, because that time counts as engine work. To judge a mod, compare the numbers with it on and off.
- Without NoitaDearImGui the report and output files are still written, but the window, the overlay and the `View` menu entries are not available.

## Disclaimer

- Assembler and engine disassembly were made by LLM. No water was consumed by author.

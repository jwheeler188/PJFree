# PJFree

**Free PJLink projector control for Control4. Built by an integrator, shared with integrators.**

A Control4 DriverWorks driver that controls projectors over **PJLink Class 1** (TCP port 4352). It uses Control4's **projector proxy**, so it appears in Composer as a projector with discrete video inputs, so sources bind to it and rooms use it as their video end-point like any other display.

Fully tested on Control4 (Composer Pro 2026.5.27 / OS 3.4.3), where it worked flawlessly to control a **Panasonic PT-VMZ51S**. It should work with any PJLink projector. Run the **List Projector Inputs** action to see which inputs the projector has, then change the input codes directly in the driver properties.

> **About this project:** AI code generation was used to produce and test this driver. No warranty is provided. If you find a bug, please [open an issue](https://github.com/jwheeler188/PJFree/issues) so the driver can be improved.

## Why this exists

PJLink is an open standard. Projector manufacturers publish it so any control system can turn a projector on, pick an input and read its lamp hours. It's a handful of plain-text commands over port 4352.

So it's always been a little strange that the AV integration industry treats drivers like this as trade secrets. Some firms gatekeep their drivers and profiles as "tricks of the trade." Others license a driver once and resell it to every integrator who needs it, at a markup. For an open protocol that fits on an index card, that adds up quickly.

To be fair: if you sell a driver and stand behind it with real support, updates and someone who answers the phone, that's a product, and that's great. The problem is the driver that costs more than a nice HDMI cable, ships with no support, and leaves you on the job site at 4:45 on a Friday reading a forum thread from 2019.

PJFree takes the other route. It's free, it's public domain, and the source is right here. Read it, change it, fix it, and send the fixes back.

The bigger point is that when integrators share tools instead of hoarding them, clients get better systems and the whole industry looks better. Better systems sell more projects for everyone. A rising tide and all that. Even the tide doesn't charge a license fee.

## Features

- Discrete **power on/off**, driven by room on/off
- Discrete **input select** from Control4 source selection
- **Auto power-on when a source is selected.** The input command is retried while the projector reports busy (`ERR3`) during warm-up.
- **AV mute** on/off
- **Status polling** for power state, current input, lamp hours, error flags (fan, lamp, temp, cover, filter, other) and projector name
- **PJLink password authentication** (MD5 challenge/response)
- Configurable PJLink code per input, set as a property
- Raw PJLink command for programming and testing
- Connect-on-demand. The driver drains its queue and then drops the socket, which avoids PJLink's 30-second idle timeout.

## Inputs

The default input set matches the PT-VMZ51S, which reports `11 12 31 32 41 51` to `INST ?`.

| Control4 input | Binding ID | Class | PJLink code |
|---|---|---|---|
| HDMI 1 | 1031 | HDMI | 31 |
| HDMI 2 | 1032 | HDMI | 32 |
| Computer 1 | 1011 | VGA | 11 |
| Computer 2 | 1012 | VGA | 12 |
| Memory Viewer | 1041 | HDMI | 41 |
| Network / USB | 1051 | HDMI | 51 |

Binding IDs are in the 1000 range, and the last two digits match the default PJLink code, which makes them easy to read in Lua debug output.

The room binding is **Video End-Point** (7000, `VIDEO_SELECTION`). No audio end-point is included, so room audio isn't routed to the projector's built-in speaker.

PJLink input ranges are: `1x` RGB, `2x` Video, `3x` Digital (HDMI/DVI/HDBaseT), `4x` Storage, `5x` Network. If you're using a different projector, check its codes (see [Testing from the Lua tab](#testing-from-the-lua-tab)) and edit the **PJLink Code** properties. No code changes are needed.

## Installation

1. On the projector, enable **PJLink** in the network menu. Note the password if PJLink authentication is on.
2. Set the projector's standby mode so the **network stays active while it's off**. Eco/low-power standby usually disables LAN, and then power-on won't work.
3. Download `PJFree.c4z` from [Releases](https://github.com/jwheeler188/PJFree/releases) (or this repo). In Composer Pro, go to **Driver > Add or Update Driver** and select it. This step is needed once per PC.
4. In **System Design > Search**, search for **PJFree** and drag **PJFree PJLink Projector** into the room. It appears as a single **Projector** item with a projector icon. The PJLink properties, actions and Lua tab are all on this item.
5. Set **IP Address** and, if used, **Password**.
6. Under **Connections > Control/AV**, bind your sources to the projector inputs and set the projector as the room's video end-point.
7. Press **Query Status** under Actions. Projector Name, Power State and Lamp Hours should populate.

> **Upgrading from v5 or earlier:** v6 moved from the TV proxy to the projector proxy and renumbered the inputs, so delete the old driver and add v6 fresh, then rebind your sources. Composer doesn't always pick up new bindings on an in-place update.

## Properties

| Property | Description |
|---|---|
| IP Address | Projector IP |
| Password | PJLink password. Leave blank if authentication is off. |
| Send Auth With Every Command | `No` (per spec). Set `Yes` only if the projector rejects the second command in a session with `ERRA`. |
| Poll Interval (seconds) | Default 30. `0` disables polling. Lamp and error status are polled every 10th cycle. |
| Debug Mode | Prints TX/RX traffic to the Lua output window |
| Connection Status, Projector Name, Power State, Current Input, Lamp Hours, Error Status | Read-only status |
| *[Input]* PJLink Code | INPT code sent for each Control4 input |

## Actions

- **Query Status** reads the name, power, input, AV mute, error status and lamp hours.
- **Power On / Power Off**
- **List Projector Inputs** prints the projector's supported input codes (`INST ?`) to the Lua output.

## Programming

**Commands**

- Power On
- Power Off
- AV Mute On
- AV Mute Off
- Send PJLink Command, for example `AVMT 31` or `INPT 32`. Leave out the `%1` prefix; the driver adds it along with the carriage return.

**Variables**

| Variable | Values |
|---|---|
| POWER_STATE | Off / On / Cooling / Warming Up |
| POWER_ON | 0 / 1 (warming up counts as on) |
| INPUT | Current input name |
| AV_MUTE | 0 / 1 |
| LAMP_HOURS | Hours per lamp |
| ERROR_STATUS | `OK`, or a list such as `Filter Warning` |

## Testing from the Lua tab

The Lua Command box runs **Lua**, not raw PJLink, so you can't type `INPT 32` directly. Wrap it in `Send()`:

```lua
Send("INPT 32")   -- switch to HDMI 2
Send("POWR ?")    -- query power
Send("INST ?")    -- list supported input codes
QueryAll()        -- full status refresh
```

Turn on **Debug Mode** to see the exchange:

```
PJLink: TX: <md5>%1POWR ?\r
PJLink: RX: POWR=1
PJLink: TX: %1INPT ?\r
PJLink: RX: INPT=31
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Connection Status shows *No response from projector* | Wrong IP, port 4352 blocked, PJLink disabled, or network standby off |
| *Authentication error (check password)* | PJLink password doesn't match the projector |
| `ERR2` on an input change | The projector doesn't use that code. Run `Send("INST ?")` and fix the input's PJLink Code. |
| `ERR3` | Projector is busy (warming, cooling or off). Input and mute commands are retried automatically for about 2 minutes. |
| Won't power on from off | Network standby is disabled on the projector |
| `'=' expected near ...` in the Lua output | A raw PJLink command was typed in the Lua box. Use `Send("...")`. |

## How it works

- **Proxy:** `projector` on binding 5001, with the proxy connection class set to `TV`. This matches Control4's own projector drivers; using a `PROJECTOR` class instead loads the proxy but no inputs. All AV inputs and the room end-point carry `proxybindingid="5001"` so they attach to the proxy device.
- **Input IDs:** video inputs use the 1000 range. Input selection is looked up by `ID % 1000`, and `INPUT_CHANGED` is reported the same way, following Control4's projector driver convention.
- **No `<combo>` tag.** Including `<combo>True</combo>` in a proxy-based driver stops Composer from creating the proxy, and the inputs and room binding then disappear from Connections.
- **Network:** binding 6001, TCP 4352, connected on demand with `C4:NetConnect`.
- **Session flow:**
  1. Connect, then wait for the `PJLINK 0` (no auth) or `PJLINK 1 <random>` (auth) greeting.
  2. When auth is on, prefix the first command with `md5(random + password)`.
  3. Send queued commands one at a time, waiting for each `%1XXXX=` response (5-second timeout).
  4. Disconnect after 3 seconds idle.
- **Power mapping:** `POWR` 1 (on) and 3 (warming) report **ON** to the proxy; 0 (off) and 2 (cooling) report **OFF**. The driver polls every 5 seconds during transitions.

## Repository layout

```
driver.xml               Driver definition (proxy, connections, properties, actions, commands)
driver.lua               Driver logic
www/documentation.rtf    Documentation tab shown in Composer (RTF, like Control4's drivers)
UNLICENSE                Public domain dedication
```

## Building

A `.c4z` is a zip with `driver.xml` at the root:

```bash
zip -r PJFree.c4z driver.xml driver.lua www
```

## Version history

| Version | Changes |
|---|---|
| 6 | Switched to the projector proxy (projector icon in Composer). Inputs renumbered to the 1000 range. Feedback sent as proxy notifications. Documentation converted to RTF so it renders in Composer. |
| 5 | Released as **PJFree**. Removed the `combo` flag so Composer creates the TV proxy. Added TV capability flags. Room end-point marked as a video source. |
| 4 | Inputs trimmed to the PT-VMZ51S set (HDMI 1/2, Computer 1/2, Memory Viewer, Network/USB) |
| 3 | AV and room connections bound to the proxy (`proxybindingid`) |
| 2 | Added the room end-point binding |
| 1 | Initial PJLink Class 1 driver |

## Bug reports

This driver was built with AI code generation and verified on real hardware, but every projector implements PJLink a little differently. If something doesn't work, please open an issue with:

- Projector make and model
- What you did and what happened
- Lua output with **Debug Mode** on

If you get it working on a projector that isn't listed here, please open an issue so it can be added to the list of tested models. Pull requests are welcome too.

## Tested projectors

| Projector | Status |
|---|---|
| Panasonic PT-VMZ51S | Fully working |

## Disclaimer

This is not an official Control4/Snap One, Panasonic or JBMIA (PJLink) product. All trademarks belong to their respective owners. It is provided as-is with no warranty. Test it in your project before deploying.

## License

Released into the public domain under [The Unlicense](UNLICENSE). Use, modify and redistribute it however you like.

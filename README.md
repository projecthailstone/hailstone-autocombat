# Auto Combat for Hailstone

A combat helper for the [Hailstone](https://github.com/projecthailstone) EverQuest client. It runs as a Lua
script and has its own window, **Auto Combat**. It fights for you in one of three modes:

| Mode | What you do | What Auto Combat does |
|---|---|---|
| **Manual: Full** | Run into the mobs. | Targets the mobs that are on you, keeps you in melee range, attacks, sends your pet and uses your spells and abilities. When one mob dies it moves to the next. |
| **Manual: Partial** | Stand where you want and pick the mob. | Uses your spells and abilities on the NPC you target, once it is fighting you or you attack it. It never moves you; it only turns you to face the mob. |
| **Hunter** | Press Start. | Everything Full does. When nothing is on you, it rests, finds a mob and walks to it over the navigation mesh, until you pause it. It can roam the zone (nearby mobs first, then anywhere it can walk to) or pull mobs back to a camp. |
| **Assist** | Group up, or pick who to assist. | Everything Full does, but it only fights what your assist is fighting, once that mob's health is low enough. Between fights it follows the assist. |

## The Spells and Abilities pages

Each page is an ordered list of rows. Every moment, the first row that is ready and whose conditions all hold
fires. A row has:

- **What:** a spell (memorized, or from your spell book), or an ability from the Ability Book (a skill, a
  combat ability or an alternate ability).
- **On whom:** the mob you are fighting, you, your pet, the group member with the lowest health, or your assist.
- **When:** in combat, out of combat, or any time.
- **Recast:** seconds to wait before it fires again. Tick **for each target** to count the wait separately for
  each mob (useful for a damage-over-time spell or a debuff).
- **Conditions:** for example "Me Health % < 50", "Target Health % > 20", "Me lacks Spirit of Wolf",
  "Target is named", "Mobs on me >= 2". Every condition must hold.

The **Now** column says why a row is not firing at the moment (not ready, out of range, conditions, recast ...).

**Import from Autoskill** on the Abilities page copies the Ability Book's autoskill list, with its conditions.
While Auto Combat runs, autoskill waits; the Ability Book's autoskill button shows "On (held)" during that time.

Spells must be memorized to be cast; Auto Combat does not memorize spells for you yet.

## Installing

1. On Hailstone's login screen, click **Add-ons**, paste `https://github.com/projecthailstone/hailstone-autocombat`
   and press Look, then Install. The card lists what it asks to do; it gets no more than that. Hailstone keeps it up
   to date. (By hand instead: copy the `autocombat` folder into the `scripts` folder of your Hailstone folder, so that
   you have `scripts/autocombat/init.lua`.)
2. In the game, type `/lua run autocombat`. To start it at every login, add it to `hailstone.ini`:
   `scripts.autoload = autocombat`.
3. The window opens when the script starts. Hide or show it with `/autocombat`, or from the EQ menu: **Plugins > Auto
   Combat**.

You need a Hailstone client that has `/stick`, `Me.AbilityReady` and `hailstone.use_ability`. Hunter mode also
needs the zone's navigation mesh, which Hailstone builds by itself.

Settings are kept per server and character in `scripts/config/autocombat/`.

## Commands

| Command | |
|---|---|
| `/autocombat` | show or hide the window |
| `/autocombat on`, `off`, `toggle` | start or pause |
| `/autocombat mode manual\|hunter\|assist` | change the mode |
| `/autocombat style full\|partial` | change Manual's style |
| `/autocombat camp` | set Hunter's camp where you stand |
| `/autocombat status` | what it is doing |

When Hunter finds nothing, the status line says why: no NPCs, every NPC left out by the Targeting page, or the
zone's navigation mesh still being built (it waits for it).

Your own movement keys stop any walk or `/stick` it started. Auto Combat pauses by itself when you die, when your
health falls below the mark you set on the Rest page, or when the server does not allow the mode.

## For server owners

Auto Combat is an ordinary player script, so your `hailstone.cfg` decides whether it runs at all
(`[scripts] player = on` and the capabilities in `player_caps`). It needs `read`, `target`, `actions`, `move` and
`ui`.

You can also turn single modes off:

```ini
[autocombat]
manual = on
hunter = off     ; no unattended hunting
assist = on
```

A mode that is off is greyed out in the window, and Auto Combat pauses if someone switches to it.

## Releasing

```sh
tools/release.sh 1.0.0             # runs the tests, packs and signs into release/v1.0.0/
tools/release.sh 1.0.0 --publish   # the same, then a GitHub release of this repository
```

The script's header lists what it needs: a client checkout with `hailstone_sign` built and the add-on key. Keep
signing with the same key: a player's client pins the first key it sees and refuses an update signed with another.
The add-on manager reads releases from public repositories only, so the Add-ons link works once this repository is
public.

## Licence

MIT (see `LICENSE`).

## Development

The pure parts (settings, conditions, row choice, targeting and the mode logic) are tested with plain Lua 5.4:

```sh
lua5.4 tests/run.lua
```

`autocombat/lib/world.lua` (which reads the game) and `autocombat/init.lua` are not covered by these tests. Try
them in the client.

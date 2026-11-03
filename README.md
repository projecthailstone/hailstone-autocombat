# Auto Combat for Hailstone

A combat helper for the [Hailstone](https://github.com/projecthailstone) EverQuest client. It runs as a Lua
script with a small **Auto Combat** window (the mode, Start / Pause and what it is doing) and a settings window
behind its gear button. It fights for you in one of three modes:

| Mode | What you do | What Auto Combat does |
|---|---|---|
| **Manual: Full** | Run into the mobs. | Targets the mobs that are on you, keeps you in melee range, attacks, sends your pet and uses your spells and abilities. When one mob dies it moves to the next. |
| **Manual: Partial** | Stand where you want and pick the mob. | Uses your spells and abilities on the NPC you target, once it is fighting you or you attack it. It never moves you; it only turns you to face the mob. |
| **Hunter** | Press Start. | Everything Full does. When nothing is on you, it rests, finds a mob and walks to it over the navigation mesh, until you pause it. It can roam the zone (nearby mobs first, then anywhere it can walk to) or pull mobs back to a camp. |
| **Assist** | Group up, or pick who to assist. | Everything Full does, but it only fights what your assist is fighting, once that mob's health is low enough. Between fights it follows the assist. |

## The windows

The compact window opens when the script starts. It has the mode (and Manual's Full or Partial), a Start / Pause
button, the Burn button, and what Auto Combat is doing, with the last thing it did under it. Drag it by an empty spot; drag its
bottom-right corner to scale it. The gear opens the settings window, a page list down the left: Spells, Abilities,
Targeting, Hunter, Assist, Rest, General and Log.

## Force and Ignore on the extended target window

While Auto Combat runs, the Modern UI's extended target window gets two buttons on each mob:

- **Force** (the crosshair): fight this one first, in every mode, until it dies. Click again to let Auto Combat
  choose. A forced mob has a pulsing gold outline and FORCED after its name. Forcing one you ignored takes the
  ignore off.
- **Ignore** (the barred circle): leave this one alone while anything else is on the list. An ignored mob is faded,
  struck through and marked IGNORED. Every ignore ends by itself once no mob you did not ignore is on the list, so a
  fight never stalls on ignored mobs.

`/autocombat force` and `/autocombat ignore` do the same for your current target. The buttons need a Hailstone
client whose Modern UI has `lib/xtarget.lua`; an older one keeps its plain window, and the commands still work.

## Burn mode

The compact window's **Burn** button (or `/autocombat burn`) turns burn mode on: rows ticked **Only during burn**
(your big discs, AAs and nukes) may fire as well as the others, and the button pulses while it is on. It ends by
itself once your extended target list is clear after a fight; turned on before the pull, it waits for that fight.
Click Burn again (or `/autocombat burn off`) to end it sooner. Pausing Auto Combat leaves it as it is. The condition
"Me Burn mode on" (with "is not") keeps a row back while you burn, a cheap nuke to save mana for instance.

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
  "Target is named", "Mobs on me within 30 of the target >= 3". Every condition must hold.

**Counting mobs, for AE spells and abilities.** Six conditions count mobs within a distance you set, of you (for a
point-blank AE) or of the target (for a targeted AE); the distance is in three dimensions, as the server measures an
AE's reach, and the spell's AE range is in its Info window:

- *Mobs on me nearby* / *near it*: mobs on your extended target list, the target among them.
- *NPCs nearby (any)* / *near it*: any live NPC that is not a pet.
- *NPCs not on me nearby* / *near it*: the ones an AE would pull in; "<= 0" keeps it from making adds.

For example "Mobs on me within 30 of the target >= 3" and "NPCs not on me within 30 of the target <= 0" on Rain of
Fire. Import spell bar and + Add give an AE spell those two to start with, at its own AE range (a hatelist spell gets
"Mobs on me >= 3").

Each page shows the rotation as tiles, in the books' look: the spell's or ability's icon, its name, a line with on
whom, when and its conditions, and a switch to turn the row off without losing it. Drag a tile to move it up or down
the list, or right-click it (change, move, duplicate, remove). While Auto Combat runs, each tile says why it is not
firing at the moment (not ready, out of range, conditions, recast ...); a row whose spell is no longer in your spell
book is marked.

The selected row shows at the right as the book shows it: its icon, level, cost, cast and recast time or reuse, and
Info for the spell's own window; then on whom, when, the recast and the conditions. **+ Add** and **Change** open
your spell book or the Ability Book as icon tiles to pick from, with a search and filters (memorized, beneficial,
detrimental; AAs, combat abilities, skills). A spell added this way starts with the same guess as Import spell bar.

**Import spell bar** on the Spells page adds a row for each memorized spell, in gem order, as a starting point to
change: harmful spells on the fight target in combat, buffs on you when you lack them, heals on you under 60% health,
pet buffs on your pet again once they run out.

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
3. The compact window opens when the script starts. Hide or show it with `/autocombat`, or from the EQ menu:
   **Plugins > Auto Combat**. Its gear (or `/autocombat settings`) opens the settings.

You need a Hailstone client that has `/stick`, `Me.AbilityReady` and `hailstone.use_ability`. Hunter mode also
needs the zone's navigation mesh, which Hailstone builds by itself.

Settings are kept per server and character in `scripts/config/autocombat/`.

## Commands

| Command | |
|---|---|
| `/autocombat` | show or hide the compact window |
| `/autocombat settings` | show or hide the settings window |
| `/autocombat force`, `ignore` | force or ignore your target (again: undo it) |
| `/autocombat on`, `off`, `toggle` | start or pause |
| `/autocombat burn [on\|off]` | burn mode on or off (no word: switch it) |
| `/autocombat mode manual\|hunter\|assist` | change the mode |
| `/autocombat style full\|partial` | change Manual's style |
| `/autocombat camp` | set Hunter's camp where you stand |
| `/autocombat status` | what it is doing |

When Hunter finds nothing, the status line says why: no NPCs, every NPC left out by the Targeting page, or the
zone's navigation mesh still being built (it waits for it), no path to the nearest mobs, or the nearest mobs past the
longest walk. The Log page has the counts behind it (NPCs in the zone, left out, candidates, no path, too far).

Full and Hunter fight only the mobs on your extended target list (the ones fighting you) and the mob Hunter chose to
go after: never whatever you happen to have targeted with auto attack on. No mode picks someone's pet, a swarm pet
among them (an animated corpse, a necromancer's skeletons ...). Stock EQEmu sends a swarm pet with no owner, so it
is told by its surname, "<owner>'s Pet" (the server's rule `Pets:ClientPetsUseOwnerNameInLastName`, on by default),
or a name that starts with a player's in the zone, as "<owner>`s Animated Corpse".

Pausing stops what Auto Combat started: its walking or sticking, the auto attack it turned on, and the pet it sent
(`/pet back off`).

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

A mode that is off is greyed out in the compact window, and Auto Combat pauses if someone switches to it.

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

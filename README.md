# Level Route Logger

A small World of Warcraft add-on that quietly records your leveling - quests, NPCs, kills, positions, XP - so
the run can be turned into a leveling route for [Itinerary](#what-the-data-is-for) automatically. It doesn't
change how you play: no popups, no chat messages.

## Install
1. Get the folder `LevelRouteLogger` (with its `libs` folder inside).
2. Put it in `World of Warcraft\_classic_beta_\Interface\AddOns\`.
3. Start the game. A map icon appears on your minimap - that's the add-on.

## While you play
- Just level normally. If you can, talk to every quest giver you pass, even if you skip the quest - the add-on
  records what they offer.
- Minimap icon: click = settings, right-click = pause/resume. Pause while AFK or doing non-leveling stuff.
- In the settings you can also turn on a thin XP-bar glow that shows it's recording, turn on a save reminder,
  and write a note at your position ("elite here", "skip this quest").
- Playing in a group is fine; the add-on records the group size.
- `/lrl` opens the settings; `/lrl note <text>` adds a note.

## Saving
The game only writes add-on data to disk when you log out or `/reload`. If the game crashes, everything since
then is lost: log out now and then, click *Save now* in the settings, or switch on the save reminder.

## Sending your data
Log out normally (don't just close the game), then send this file:
`World of Warcraft\_classic_beta_\WTF\Account\<YOUR ACCOUNT>\SavedVariables\LevelRouteLogger.lua`

It contains your character names and what they did - nothing else (no passwords, no account info).

## What the data is for
Each log line is `time ~ level ~ xp ~ TYPE ~ map ~ x ~ y ~ fields...` (see the top of `LevelRouteLogger.lua` for
the types). A converter turns a run into route steps: accept / quest / turn in, the places objectives were done,
the mobs and quest items involved, trainers (class, weapon master, profession), vendors, flight paths and
flights, the hearthstone, dungeons, boats and the Deeprun Tram, death skips, dialogue choices, grinding, the way
you walked between steps, and your notes. Every character gets a run of its own.

## Changes
See [CHANGELOG.md](CHANGELOG.md).

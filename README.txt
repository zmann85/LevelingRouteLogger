Level Route Logger - help us build a WoW Forever leveling route
================================================================

This addon quietly records your leveling (quests, NPCs, kills, positions, XP)
so we can build a fast leveling route for launch. It doesn't change how you
play: no popups, no chat messages.

INSTALL
1. Unzip so you get the folder "LevelRouteLogger".
2. Put it in:  World of Warcraft\_classic_beta_\Interface\AddOns\
3. Start the game. A map icon appears on your minimap - that's the addon.

WHILE YOU PLAY
- Just level normally. If you can, talk to every quest giver you pass,
  even if you skip the quest - the addon records what they offer.
- Minimap icon: click = settings, right-click = pause/resume.
  Pause while AFK or doing non-leveling stuff.
- In the settings you can also:
    - turn on a thin XP-bar glow that shows it's recording
    - turn on a save reminder (see below)
    - write a note at your position ("elite here", "skip this quest")
- Playing in a group is fine; the addon records group size.
- Slash command: /lrl  (opens the settings; /lrl note <text> adds a note)

SAVING - please read
The game only writes addon data to disk when you log out or /reload.
If the game crashes, everything since then is lost. Either log out now and
then, click "Save now" in the settings, or switch on the save reminder.

SENDING YOUR DATA
Log out normally (don't just close the game), then send this file:
  World of Warcraft\_classic_beta_\WTF\Account\<YOUR ACCOUNT>\SavedVariables\LevelRouteLogger.lua
It contains your character names and what they did - nothing else
(no passwords, no account info).

Thanks!

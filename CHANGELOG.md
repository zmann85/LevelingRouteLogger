# Changelog

## 3.1
- **One run per character**: a character made again under an old name (or another one) starts a run of its own
  instead of being added to the old character's.
- **Loading screens** are logged with the instance they lead to (`LW` / `EW`): dungeons, boats, zeppelins, the
  Deeprun Tram and portals are now certain in the data instead of guessed.
- **New flight paths** you learn (`FPNEW`), so opening a flight map to have a look isn't taken for one.
- **Quest items** are logged when you use them (`QU`), also in combat and from action bars, item buttons or
  macros - before, only clicks in the bags were.
- **Trainers** say what kind they are (class trainer, weapon master, profession trainer), and what you buy
  there carries the skill's spell ID.
- **Vendors**: what you sold, whether you repaired and what it did to your money (`VC`); purchases carry the
  item's kind and spell (food, drink).
- **Spirit healer**: resurrecting there is logged (`SPIRIT`), which tells a death skip from a corpse run.
- **Emotes** (`E`) with who you emoted at - for quests that want a /salute or a /dance.
- **Less noise**: your own spells are no longer logged as casts (most of the log was Seal of Righteousness);
  items, objects you open and the hearthstone still are. Quest objectives count as changed by their numbers,
  not their wording (the text changes its form after logging in).

## 3.0 and earlier
- What it recorded up to 3.0: logins (3.0: with the character's race, class and GUID), zones, your position
  every few seconds, quests offered, accepted, progressed, completed, turned in and removed, gossip and the
  options you picked, trainers and what you bought there, vendors and purchases, flight masters and flights,
  where you set your hearthstone, casts and item use out of combat, loot and where it came from, gathering,
  crafting, kills with their XP, level-ups, deaths, skill-ups, group size, time played, notes, pause and
  resume.

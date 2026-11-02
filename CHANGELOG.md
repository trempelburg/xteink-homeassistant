# Changelog

## 0.6 (2026-11-02)

- Brightness and volume bars no longer jump: the answer to a tap that a quicker tap has overtaken
  is not shown, and an answer without the change yet (a light still dimming) keeps your choice on
  the screen while the app asks again three seconds later. − / + on a light go to the next ten
  (65% -> 60% / 70%), and a light at 1-4% shows one segment instead of none.
- The panel says how fresh its states are as the lock screen does: "updated just now",
  "updated 12 min ago", "updated 3 h ago" (also on the lock screen, which said "0 min ago").

## 0.5 (2026-10-28)

- Locks that can unlatch the door (a Nuki, or any lock whose Home Assistant entity supports
  `lock.open`): a tap offers **Open door** beside Lock / Unlock, and asks "Open the door?" once
  more before sending it. Locks that cannot unlatch are unchanged. The tile learns whether a lock
  can unlatch on its first update after installing 0.5.
- Lock screen: a tile whose entity is listed in the box below (an unlocked lock, an open door) is
  no longer shown twice: the tile is left out until it is locked or closed again.

## 0.4 (2026-10-28)

- Lock screen: when the states are old because the reader had no Wi-Fi, a crossed-out Wi-Fi sign
  shows in front of "updated ... ago", or Home Assistant's error is named. A row of tiles is only as tall as its contents: name and value alone take less room.
- Battery: the lock screen waits longer after each try that got no answer (10 minutes up to
  160) and lets Wi-Fi go right after a try. The panel stops asking every minute once it has been
  left alone for ten minutes and lets Wi-Fi go; a touch asks again. Wi-Fi is kept up for two
  minutes after a request instead of five. A finger going down or moving no longer redraws the
  screen, and the minute's update redraws once instead of twice.

## 0.3 (2026-10-28)

- Thermostats: the tile shows what the thermostat is doing and its target ("Heating to 21°",
  "Heat cool · 19-24°"). The controls add the heat/cool range (Heat to / Cool to, sent together,
  never crossing), presets, fan modes and the current humidity, and keep the target within the
  thermostat's minimum and maximum.

## 0.2 (2026-10-28)

- New look: rounded tiles with an icon for each kind of entity, a real on/off switch on lights
  and switches, a brightness bar on lights that are on, the date and time in the header, page
  dots; the lock screen in the same style with a box for open doors and windows.
- Lights: a control screen with brightness in ten steps, − / Night / Max / +, warmth and colours.
- Media players: a control screen with previous / play-pause / next, volume in ten steps and
  − / +, mute, source and on / off; a play / pause button on the tile.
- Thermostats: target temperature and mode. Covers: open, stop, close and position.
- Quick taps are queued: the latest waits until the request before it is done.

## 0.1 (2026-10-27)

- First version: tiles for any entity, toggles, scenes, scripts, locks that ask first, search to
  add tiles, long press to edit, the pinned tiles as the lock screen, a fallback for non-admin
  tokens. Tested on an X4 Pro.

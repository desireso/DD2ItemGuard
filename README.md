# DD2 Item Guard

REFramework Lua mod for Dragon's Dogma 2. It watches item rows shown in the inventory UI and restores configured item counts with `ItemManager:getItem`.

## Features

- In-game REFramework UI under `Script Generated UI > DD2 Item Guard`
- Unified `Items` panel sorted by numeric item ID
- Per-item `Min` rule
- Per-item hide list for equipment, quest, or other unwanted rows
- Direct target count editing with ImGui integer input
- Settings auto-saved to `reframework/data/dd2_item_guard.json`

## Install

Install and enable `DD2_Item_Guard_v1.2.zip` with Fluffy Mod Manager.

Manual layout:

```text
modinfo.ini
reframework/
  autorun/
    dd2_item_guard.lua
```

The config file is created automatically at `reframework/data/dd2_item_guard.json`
when settings change. It is intentionally not included in the release zip so
mod updates do not overwrite your saved item rules.

For Korean item names in the REFramework UI, install `D2Coding.ttf` separately:

```text
Dragon's Dogma 2/
  reframework/
    fonts/
      D2Coding.ttf
```

If `reframework/fonts/D2Coding.ttf` is missing, the mod falls back to English item names.

## Use

1. Open the DD2 inventory so item rows are observed.
2. Open `Script Generated UI > DD2 Item Guard`.
3. Enable `Item Guard Enabled`.
4. Optionally set `Default Min Count` to use the same Min value for new rules.
5. In `Items`, set the target count or use the default value.
6. Click `Min` for the item.
7. Click `Hide` to move unwanted rows to `Hidden Items`.
8. Click active `Min` again to remove that rule.
9. Use `Unhide` in `Hidden Items` to show an item again.

Changes are saved automatically.

## Notes

This is intended for offline play. Back up your save before using item-count mods.

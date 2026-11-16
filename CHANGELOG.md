# Changelog

## 1.1.0
- **Renamed to Mage Dash** (was MageBoard). The command is now `/mage`. `/mageboard` still works. It still talks to players on 1.0.0.
- If you installed by hand, delete the old `Interface\AddOns\MageBoard` folder. Your prices and note reset once because of the rename.
- Fixed: you no longer appear on your own board.
- Find Services can now be filtered by service and sorted by nearest, cheapest, highest rank, highest level or name.
- Warlocks can now list Summon (Ritual of Summoning). The "Find a Mage" tab is now "Find Services".
- Water, food and Arcane Intellect now show their rank. Mages list the highest rank they know; players pick the rank they want, with the best one for their level marked.
- Each realm and each faction now has its own board. You only see, and get requests from, players on your realm and faction.
- Services you haven't learned can no longer be ticked or advertised. They unlock on their own when you learn the spell. If a spell you do know shows as not learned, `/mage unlock` lets you tick it anyway.
- The tab you're on is now the highlighted one.
- Added a bug-report contact line at the bottom of the window.

## 1.0.0
- Initial release: Find a Mage board, My Services provider panel, request / accept / decline flow with auto-invite, busy status, notes, auto-detection of known portals and conjures.

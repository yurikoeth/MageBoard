# MageBoard

<img src="logo.png" width="128" alt="MageBoard logo">

**A marketplace for mage services in WoW: Forever.** Mages put up their portals, food, water and buffs with their own rates. Players see who's online, where they are and what they charge, then send a request with one click.

No more spamming "WTB portal SW" in trade chat and hoping.

## Install
1. Download `MageBoard-1.0.0.zip` from the [Releases page](https://github.com/yurikoeth/MageBoard/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\` so the folder sits at `AddOns\MageBoard`.
3. Restart the game or `/reload`.

## For players
- Open the board with `/mageboard` (or from the addon compartment on the minimap).
- **Find a Mage** lists every mage currently open for business: their level, zone, services and prices, plus any note they've left (where to meet, bulk deals).
- Mages in your zone are listed first and highlighted.
- Hit **Request**, pick a service, and the mage gets your request straight away. When they accept you get an alert with where they are, and a group invite.

## For mages
- Go to **My Services** and tick **Open for business**.
- Services you can already cast are ticked for you. Turn any of them on or off.
- Set a price per service in gold: `5` = 5g, `0.5` = 50s, `0` = free. Leave it blank for **tips**.
- Add a short note ("Mage Quarter fountain, 10% off water stacks").
- Requests show up with a ready-check sound. **Accept** sends the player your location and invites them to your group. **Decline** tells them politely.
- Mark yourself **Busy** to stay listed without implying you're free right now.

## Services
Portals: Stormwind, Ironforge, Darnassus, Orgrimmar, Undercity, Thunder Bluff · Conjured Water · Conjured Food · Arcane Intellect

## Commands
| Command | What it does |
|---|---|
| `/mageboard` or `/mboard` | Show or hide the board |
| `/mageboard find` | Refresh and browse mages |
| `/mageboard open` / `close` | List or unlist yourself |
| `/mageboard busy` | Toggle busy |
| `/mageboard sound` | Toggle the request sound |

## Good to know
- **Both sides need MageBoard.** It talks over a hidden addon channel (`MageBoardSvc`), so only players running the addon can see each other. The more people install it, the better it gets.
- The channel takes one of your 10 chat channel slots. It's removed from your chat windows automatically, so it won't spam you.
- Listings show who's online right now. A mage drops off the board a few minutes after they close, log off or stop sending updates.
- **No gold changes hands through the addon.** Payment happens through the normal trade window.
- Built for WoW: Forever (interface 16001). Also loads on Retail.
- **Status:** new and lightly tested. Bug reports welcome in [Issues](https://github.com/yurikoeth/MageBoard/issues).

## Feedback
Found a bug? Open an issue with the Lua error text (BugSack makes this easy) and what you were doing at the time.

## License
All rights reserved. © yurikoeth

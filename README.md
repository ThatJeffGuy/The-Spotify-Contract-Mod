# The Spotify Contract

A World of Warcraft **Forever** addon that answers price checks in guild chat. A guildmate types `? [item]` in guild chat and gets a whisper back with that item's auction house price. Every guild member running the addon shares their scans, so the prices come from the whole guild's scans, not just one person's.

## Usage

Type in **guild chat**, shift-clicking the item to link it:

| You type | You get |
|---|---|
| `? [Major Healing Potion]` | Your faction's auction house (Horde or Alliance) |
| `? PVP [Major Healing Potion]` | The neutral auction house (Booty Bay, Gadgetzan, Everlook) |

The reply comes back as a whisper, one line per item:

```
[Major Healing Potion] | Horde: 3-day avg 27S 88C | Lowest 27S 84C (774 up) | Data is 5 minutes old.
```

- **3-day avg**: average of the daily price over today and the two days before.
- **Lowest**: the cheapest buyout in the latest scan, and how many are up.
- **Data is … old**: when that item was last scanned.

Linking several items in one message gets one reply line for each. Only messages that start with `?` and contain an item link are answered, so normal chat is ignored.

Type `/tsc` for status: items stored for each auction house, who scanned and when, whether you're syncing, and messages sent and received this session.

## Install

1. Download the latest release zip from the [Releases](../../releases) page.
2. Extract the `TheSpotifyContract` folder into `World of Warcraft/_forever_/Interface/AddOns/`.
3. Restart the game, and make sure **The Spotify Contract** is ticked in the AddOns list.

## Scanning

The addon reads scans from **Auctionator** or **Auctioneer**. You don't need either to answer questions with the guild's data, but you need one of them to add your own scans.

- **Auctionator:** turn on **Replicate mode** in Auctionator's settings and use **Full Scan**. Replicate mode downloads every listing, which gives the outlier-proof price. Without it, a Full Scan only gives each item's lowest price and quantity.
- **Auctioneer:** regular Auctioneer scans work as they are.
- **Neutral AH:** scan at a neutral auction house. With Auctionator, a scan counts toward whichever AH you're standing at when it finishes. With Auctioneer, the two houses are already separate.
- **Pacing:** leave at least 15 minutes between scans. The game limits how often the full download can run.

### How prices are worked out

The daily price is the **quantity-weighted median** of all listings: the unit price at which half of the items for sale are cheaper. So one item listed at 1c next to 727 listed at 5s 30c prices at 5s 30c. On days with no scan that includes every listing, the day's lowest price is used instead.

## Syncing

Data is shared quietly over addon messages and **never while you're in combat**.

- **After a scan:** the scanner shares it with the guild, at most one message per second, while they and at least one other member are **resting** (inns and capital cities count).
- **Catch-up:** when you become eligible, you get what you missed while you were away, privately and paced the same way.
- **On a question:** the answering member first checks for newer data in that item's AH subcategory (for example Consumables › Food & Drink), as long as nobody involved is in combat.

### One answer per question

When several members run the addon, the asker still gets a single reply. Each member's addon waits a short random moment, then claims the question with a tiny guild addon message. The first claim wins and everyone else stays quiet. If two claims land at the same moment, the alphabetically lower character name answers. Members who aren't in combat wait less, so they usually answer first.

A second reply can only happen if guild addon messages lag by more than about 0.7 seconds, so one member doesn't see another's claim in time. That should be rare, and it means one extra line, not a flood.

## Known limits

- Forever's replicate download can be incomplete, so the "up" count can be lower than the real number.
- Any member running the addon can share data, including wrong prices. The median limits the damage from bad listings, but data isn't checked for where it came from.

## License

MIT, see [LICENSE](LICENSE).

Made by Jeff Wilton (in game: Joe Roegan, Horde).

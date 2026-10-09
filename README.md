# PallyLite

A simple PallyPower for Paladins: pick a blessing for each class, then one click (or one key) blesses whoever in your group is missing it. For **OctoWoW** (the 1.12 client). It may work on Turtle WoW and other 1.12 servers, but it was only made and tried on OctoWoW.

> [!WARNING]
> **Made with AI.** This add-on was written by an AI (Claude, by Anthropic) using Claude Code. I'm not a programmer: I described what I wanted, played with it on OctoWoW, and reported problems back for the AI to fix. It has automated tests against a simulated WoW API, but some features have only been tried by me, and a few not in game at all yet, so expect bugs. Please report them under **Issues**.

## What's in it

- **A blessing per class**, plus a **pet** row.
- **One button, or a key binding**, blesses the next person who needs it.
- **Warnings** when your blessings are about to fade.
- **Works with PallyPower users**: it shares assignments using PallyPower's own messages (the N'Zoth/Turtle version), so you can split blessings with Paladins who use PallyPower.

## Install

1. Download `PallyLite.zip` from the [Releases](../../releases) page. Don't use GitHub's green **Code → Download ZIP** button: it gives a folder named `PallyLite-main`, which WoW won't load until you rename it to `PallyLite`.
2. Extract it into `Interface\AddOns`, so you end up with `Interface\AddOns\PallyLite\PallyLite.toc`.
3. Restart the game, or type `/reload` if you're already logged in.

## Usage

`/plite` shows or hides the window, and `/plite help` lists the rest. Set the key under **Key Bindings → PallyLite**.

## Licence

MIT, see [LICENSE](LICENSE).

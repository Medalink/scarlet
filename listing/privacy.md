Scarlet does not store free text. Where a window holds someone's words, it keeps a count, a name or a price instead. This list follows `docs/FORMAT.md` and the website's "What Scarlet never records" table.

Never recorded, with what is kept instead:

- Chat text and whispers: message and word counts per channel.
- Mail subjects and bodies: who sent or received the mail, the money and the items.
- Auction notification text: the item, the count and the price.
- The text of UI errors: the error's name and how often it appeared.
- Support ticket and report text, and who a report was about: that a report was sent, and its type.
- Guild notes, the message of the day and rank names: your rank number, and whether you are an officer or the leader.
- Calendar titles, friend notes and group finder comments: counts of invites waiting, list sizes and listings found.
- Other players' GUIDs, account names and account friend tags: the character names of players you group, trade, mail or roll against.
- What is in your screenshots: only the file name and the time. Scarlet never reads a picture.

Your own chat is kept as counts too. Scarlet counts each `lol` and `rip` you type and stores the number, not the sentence.

What it does keep about other people: the character names of players in your group, players you saw on your target, mouseover or nameplates, and players you traded, mailed or rolled against. These stay in your SavedVariables file on your PC.

Screenshots at key moments are off by default. When you turn them on in Settings, Scarlet calls the game's own screenshot command, at most once every 5 seconds, and records the file name.

Scarlet makes no web requests. While you are in a group it sends one thing through the game's addon channel, to that group only: which creature or object you looted, and the items and coin in its loot window. It sends no names, positions or chat, and "Share loot sources with your group" in Settings turns it off. Your recording leaves your PC only if you copy the file yourself.

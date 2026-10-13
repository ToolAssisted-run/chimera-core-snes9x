# The test roms in this folder

Two homebrew games the tests run, so that the tests can run on a public CI
runner. Each is here as its author published it, for free download. Neither
is under this repository's licence, and for neither was a licence found that
says the file may be passed on (looked 2026-10-13): if you are the author of
one and want it removed, say so in an issue and it goes.

| file | what it is | by | what is known of its terms |
| --- | --- | --- | --- |
| `Christmas_Craze.smc` | Christmas Craze, a platform game (2011) | Shiru; published by RetroZone | The author released the source in 2011 on the nesdev forum with no licence stated. |
| `TheLastSuper.sfc` | The Last Super, made for the console's 30th birthday | Dr. Ludos, <https://drludos.itch.io/the-last-super> | Free download with its source; no licence stated for the game. Its two pieces of music are CC BY-NC-SA: not for commercial use. |

Commercial games are never put here: they stay in `tests/roms-local/`, which
git ignores, and their tests are skipped where they are absent.

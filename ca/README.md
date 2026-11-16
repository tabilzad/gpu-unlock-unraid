# Community Applications files

Community Applications (CA) lists plugins from a feed repository, one wrapper per plugin.
The feed for this account is [tabilzad/unraid-plugins](https://github.com/tabilzad/unraid-plugins);
it holds an unchanged copy of the wrapper below as `plugins/gpu-unlock.xml`. The copy here
is the source: change it here, run `make lint-ca`, then copy it into the feed and run
Scan on <https://ca.unraid.net/submit>.

- `ca/gpu-unlock.xml`: the wrapper CA reads (`<Plugin>` root). Its `PluginURL`, `MinVer`
  and `Support` must be identical to the `pluginURL`, `min` and `support` attributes of
  the plg (`plugin/gpu-unlock.plg.in`); `make lint-ca` checks that against the rendered
  plg, along with the categories and the icon. `RequiresFile` names the Nvidia-Driver
  plugin: while it is missing, CA shows `Requires` and offers no Install button.
- `ca/gpu-unlock.png`: the icon, 256x256, not animated, not NVIDIA's logo or colours.
  Regenerate with `python3 scripts/make-icon.py ca/gpu-unlock.png` (standard library
  only). The wrapper's `Icon` is its raw URL on `main`, so the icon must be pushed before
  the feed is scanned.
- `docs/ca-moderator-notes.md`: facts for the moderators' manual review.

## Submitting

1. The repository is public, has an OSI-approved licence at the root (`LICENSE`,
   GPL-2.0), and `https://github.com/tabilzad/gpu-unlock-unraid/releases/latest/download/gpu-unlock.plg`
   resolves (every `v*` tag is a full release).
2. `make lint-ca` passes, and this directory is pushed to `main`.
3. Copy `ca/gpu-unlock.xml` unchanged to `plugins/gpu-unlock.xml` in the feed, run its
   `scripts/validate`, commit and push.
4. On <https://ca.unraid.net/submit>, pick the feed repository, run **Validate** and
   **Scan**, and fix whatever the validator reports. A plugin new to CA is reviewed by
   hand; `docs/ca-moderator-notes.md` answers what the reviewers are likely to ask.
5. After acceptance the entry shows up in Apps within a few hours. Later releases need
   no resubmission: CA reads the plg at `PluginURL`.

## Moving support to a forum thread

The support link is the GitHub issues page for now. CA shows the plg's `support`
attribute, not the wrapper's, so moving to a forum thread on forums.unraid.net is a
plugin release:

1. Post the thread (Plugin Support).
2. Set its URL as the `support` entity in `plugin/gpu-unlock.plg.in` and as `<Support>`
   in `ca/gpu-unlock.xml`; `make lint-ca` fails until the two agree.
3. Cut a release, copy the wrapper into the feed again, and run Scan.

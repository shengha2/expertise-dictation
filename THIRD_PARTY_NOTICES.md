# Third-party components

The MIT license at the repository root applies to this project's own code,
prompts, documentation and assets. Third-party components retain their licenses:

- Sparkle 2.10.0: [upstream license](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE), also copied into each app bundle as `LICENSE-Sparkle.txt`.
- Inter fonts: [bundled license](Resources/Fonts/LICENSE-Inter.txt).
- Installer build tools: dmgbuild 1.6.2 (New BSD), ds-store 1.3.1 (MIT), and mac-alias 2.2.2 (MIT). Hash-pinned wheels are listed in `scripts/requirements-dmg.txt`; these tools and their installed license files stay in the local build environment and are not embedded in the app.
- UI SFX start and stop sounds: [bundled license](Resources/Sounds/LICENSE-UI-SFX.txt) and [source attribution](Resources/Sounds/SOURCE.md).

OpenAI provides hosted inference under its own service terms. A source-code
license does not grant an API account, service credits, or a guarantee of free
hosted availability. The free beta is funded by its operator within published
usage limits. Self-hosting and using your own provider key remain possible.

Typeless and Wispr Flow are research references, not project dependencies.
Their names, branding, screenshots, and other materials are not licensed by
this repository's MIT license and are not included in its source distribution.

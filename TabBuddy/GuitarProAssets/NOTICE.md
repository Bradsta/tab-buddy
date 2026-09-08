# Guitar Pro player dependencies

Tab Buddy bundles alphaTab **1.8.4**, unmodified, from the official
`@coderline/alphatab` npm package. No CDN or external service is used at runtime.

- alphaTab: Copyright Daniel Kuschny and contributors, MPL-2.0.
  License: `ALPHATAB-LICENSE`. Source: https://github.com/CoderLine/alphaTab/tree/v1.8.4
  Package: https://registry.npmjs.org/@coderline/alphatab/-/alphatab-1.8.4.tgz
- Bravura font: SIL Open Font License; see `font/Bravura-OFL.txt`.
- Sonivox soundfont: Copyright 2004–2006 Sonic Network Inc., Apache-2.0;
  see `soundfont/LICENSE`.

`index.html`, `player.css`, and `player.js` are Tab Buddy's score-only integration.
Controls live in the shared native `TabTransportBar`; `GuitarProPlayer` bridges
playback state and commands without running a second clock.
The vendor runtime, font, and soundfont retain their respective licenses.

To update, download an explicit version of the official npm package, replace
these vendor assets and notices, and run GuitarProTests on an iOS simulator.
The WKWebView uses an allowlisted custom URL scheme; it exposes only the current
score and these bundled assets. Rendering workers are disabled. The audio worker loads the bundled runtime through
a local blob URL; audio uses the ScriptProcessor backend because WebKit custom
schemes cannot load audio worklets.

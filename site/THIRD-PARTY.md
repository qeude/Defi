# Third-party assets

| Asset | Source | Terms |
| --- | --- | --- |
| DM Sans and IBM Plex Mono | Google Fonts | SIL Open Font License; copies are included in `public/fonts/`. |
| Cabinet Grotesk 500 | [Fontshare](https://www.fontshare.com/fonts/cabinet-grotesk) | [ITF Free Font License](https://www.fontshare.com/licenses/itf-ffl); the official license is included in `public/fonts/CabinetGrotesk-LICENSE.txt`. |
| GSAP 3.15.0, ScrollTrigger, CustomEase | GreenSock / Webflow | [Standard No Charge GSAP License](https://gsap.com/community/standard-license/); upstream notices are preserved in `public/motion/`. |

Cabinet Grotesk is downloaded directly from Fontshare by
`script/prepare-fonts.mjs` before development or builds. Unmodified WOFF2 files
are cached locally for this site's self-hosted use and ignored by Git. They are
not redistributed through the source repository or relicensed under Defi's MIT
license. Each developer obtains their own copy from the licensor.

The custom horizon artwork was generated for this landing. Its prompt and
provenance are documented in [ART-DIRECTION.md](ART-DIRECTION.md). Desktop media
provenance is documented in [MEDIA.md](MEDIA.md).

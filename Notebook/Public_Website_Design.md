# Public website design

The public site in `website/` presents Shaar's early public beta and the page inventory from issue #337: home, download, changelog, building, privacy, license, notices and security/verification. Product claims follow the repository README and release notes; release requirements follow `scripts/release-config.sh`. Related: [[Product_Identity]], [[Build_And_Run]], [[Releasing]].

## Composition

An original vector landscape opens the home page: layered green hills, a winding gateway path and a rising/setting sun. Large typography sits in clear sky. Subsequent sections alternate real repository screenshots with concise feature explanations: Spaces/profiles, Command-T and extensions. A compact sticky navigation, continuous rules and generous asymmetric spacing join the sections. A closing download invitation leads to installation details. Supporting pages use the same navigation and an uncluttered reading column.

## Visual system

Self-hosted Manrope provides navigation, body and headings; Newsreader italic gives display phrases a softer contrast. Fluid sizes preserve readable line lengths. The palette uses `Branding/DESIGN.md`: forest `#026748`, deep teal `#013C3C`, dark tile `#071A12`, mint `#83F0B4` and lime `#C8F736`, with warm paper and tinted dark surfaces. The master logo remains unchanged. Light/dark follows the system with an explicit override.

## Motion and accessibility

The sun makes one slow rise-and-set cycle, then rests; hills enter with restrained transform/opacity motion. A visible replay/pause control governs the landscape. Hover/focus transitions stay brief. `prefers-reduced-motion: reduce` disables landscape and entrance animations and smooth scrolling. Content remains visible without JavaScript. Semantic landmarks, skip link, visible keyboard focus, sufficient contrast, image descriptions and 44px control targets apply throughout. Mobile stacks feature stories, keeps navigation reachable and never relies on hover.

## Reference boundaries

Browser research: [Ardia](https://ardia.dev/) supplied only the hills/sun concept; [Yet Another Browser](https://yetanotherbrowser.com/) supplied screenshot-led feature storytelling; [Phi](https://phibrowser.com/) supplied restrained motion and typographic polish; [Aside](https://aside.com/) supplied compact navigation and continuous scrolling composition. No reference code or assets are reused. Zerm's local site supplied only page inventory, not its product claims or license.

## Hosting boundary

TypeScript generates static HTML and a small client bundle. Cloudflare Workers serves `dist/` through the assets binding, with real 404s and clean directory URLs. See [static assets](https://developers.cloudflare.com/workers/static-assets/), [HTML handling](https://developers.cloudflare.com/workers/static-assets/routing/advanced/html-handling/) and [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/). PR checks require no cloud credentials. Deployment runs only on `production` pushes with a separately provisioned token/account variable; domain configuration remains an explicit operator step. The existing Sparkle feed remains `https://arcusis.github.io/shaar/appcast.xml`; this site never publishes or proxies it.

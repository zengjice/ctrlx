# Third-party licenses

CtrlX is built on these open-source projects. Each is used under its own
license; full texts live in the linked repositories. Thank you to all of their
authors and contributors.

> **Maintainers:** the apps surface this entire list in-app (macOS Settings →
> About, iOS Settings → Licenses), grouped by where each project is used
> (apps & relay, build tools, website). When you change any rows below, mirror
> the change in `ThirdPartyLicense.all`
> (`CtrlxPackage/Sources/CtrlxCommon/Constants/ThirdPartyLicenses.swift`).

## Swift packages (apps + relay)

| Project | License |
|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT (bundles permissively licensed components; see its LICENSE) |
| [Vapor](https://github.com/vapor/vapor) | MIT |
| [vapor/apns](https://github.com/vapor/apns) (APNSwift) | MIT / Apache-2.0 |
| [async-http-client](https://github.com/swift-server/async-http-client) | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |
| [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) | MIT |
| [swift-clocks](https://github.com/pointfreeco/swift-clocks) | MIT |
| [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | MIT |
| [ProjectNavigator](https://github.com/mchakravarty/ProjectNavigator) | Apache-2.0 |
| [textual](https://github.com/gonzalezreal/textual) | MIT |
| [Yams](https://github.com/jpsim/Yams) | MIT |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (build tool) | MIT |
| [SFSymbolsMacro](https://github.com/gpambrozio/SFSymbolsMacro) (fork of [lukepistrol/SFSymbolsMacro](https://github.com/lukepistrol/SFSymbolsMacro)) | MIT |
| [GitWorkbench](https://github.com/gpambrozio/GitWorkbench) | MIT |

Transitive dependencies from the Apple, Vapor, and Point-Free ecosystems are
Apache-2.0 or MIT; the pinned set is in
[`CtrlxPackage/Package.resolved`](CtrlxPackage/Package.resolved).

## Agent Browser (macOS development runtime)

| Project | License |
|---|---|
| [agent-browser 0.38.1](https://github.com/vercel-labs/agent-browser/tree/v0.38.1) | Apache-2.0 |
| [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) | BSD-3-Clause; Chromium third-party licenses |

The pinned upstream executable is unmodified. Its full LICENSE is bundled in
`Resources/AgentBrowserEngine/LICENSE.txt`; CEF's LICENSE and CREDITS are bundled
alongside it. The native runtime's distribution archive gate remains in place;
the upstream binary's complete transitive-license audit and hardened-runtime
distribution checks are still required before enabling that gate.

## Website

| Project | License |
|---|---|
| [Astro](https://github.com/withastro/astro) | MIT |
| [@astrojs/sitemap](https://github.com/withastro/astro/tree/main/packages/integrations/sitemap) | MIT |

## Data

Emoji keyword data is generated from the
[Unicode CLDR](https://cldr.unicode.org) annotations (Unicode License).

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
| [SFSymbolsMacro](https://github.com/gpambrozio/SFSymbolsMacro) (fork of [lukepistrol/SFSymbolsMacro](https://github.com/lukepistrol/SFSymbolsMacro)) | MIT |
| [GitWorkbench](https://github.com/gpambrozio/GitWorkbench) | MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT |

Transitive dependencies from the Apple, Vapor, and Point-Free ecosystems are
Apache-2.0 or MIT; the pinned set is in
[`CtrlxPackage/Package.resolved`](CtrlxPackage/Package.resolved).

## Build tools

| Project | License |
|---|---|
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT (bundles permissively licensed components; see its LICENSE) |

## Artifact previews (Mac and iOS)

| Project | License |
|---|---|
| [Mermaid 12.2.0](https://github.com/mermaid-js/mermaid) | MIT; bundled dependency notices |
| [Marked 18.1.1](https://github.com/markedjs/marked) | MIT |
| [DOMPurify 3.4.17](https://github.com/cure53/DOMPurify) | Apache-2.0 OR MPL-2.0 |

The unmodified browser bundles and full licenses are included in
`CtrlxCommon/Resources/ArtifactPreview`. `upstream.json`, `marked-upstream.json`
and `dompurify-upstream.json` record the exact npm archive integrity and JavaScript
SHA-256; upstream dependency notices remain in the bundles. The renderer is
loaded locally, with no runtime CDN dependency.

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

## Agent Simulator

The native simulator XPC handshake and DTUHID wire vocabulary are adapted from
[idb](https://github.com/facebook/idb/tree/45e96c070ce62ee1df14ba21ccd8c07b720a8684)
(MIT). The copyright and permission notice are retained in
[`idb-LICENSE`](CtrlxPackage/Sources/CtrlxSimulatorBridge/ThirdParty/idb-LICENSE).
Native accessibility snapshot attributes and cross-process subtree continuation
follow [idb revision c11e82a](https://github.com/facebook/idb/tree/c11e82abcca6301b21ac024890e09571835f1a7f)
under the same MIT notice; CtrlX uses its existing Mac Inspector transport.

Service profiles and resource measurement use the unmodified
[simslim](https://github.com/MobAI-App/simslim/tree/e752a72898ca69f703c74dc79b7b047a4f2093a3)
CLI (MIT, copyright Interlap), built from a SHA-256-verified source archive at
that fixed commit. Its license is bundled in
`Resources/AgentSimulator/simslim-LICENSE`.
The Go standard-library license and notices for the modules actually linked into
the CLI are bundled in `Resources/AgentSimulator/simslim-NOTICES.txt`.
`simslim-build.json` records the source hash, compiler, signed binary hash and
each linked module's license classification and notice hashes.

## Website

| Project | License |
|---|---|
| [Astro](https://github.com/withastro/astro) | MIT |
| [@astrojs/sitemap](https://github.com/withastro/astro/tree/main/packages/integrations/sitemap) | MIT |

## Data

Emoji keyword data is generated from the
[Unicode CLDR](https://cldr.unicode.org) annotations (Unicode License).

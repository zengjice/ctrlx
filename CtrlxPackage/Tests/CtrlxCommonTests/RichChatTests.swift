#if os(macOS)
    import AppKit
    import Testing
    import WebKit
    @testable import CtrlxCommon

    @MainActor @Suite(.serialized)
    struct RichChatTests {
        @Test
        func referencesDecodeOnceAndRejectTraversal() {
            let text = "`<repo:docs/图%20片%2527.md>` <repo:.> (repo:src/file.swift) <repo:../secret> <repo:/etc/passwd> <repo:bad%ZZ> <repo:unfinished"
            let message = RichChatMessage(id: UUID(), text: "", answer: text)
            #expect(message.references.map(\.path) == ["docs/图 片%27.md", ".", "src/file.swift"])
        }

        @Test
        func incompleteMarkersAndMarkdownLinkDefinitionsKeepValidTargets() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.onReference = { _, path in paths.append(path) }
            let answer = #"""
            <repo:unfinished

            <repo:docs/ok.md>

            [Titled](repo:docs/title.md "Title")

            [Reference][plan]

            [plan]: repo:docs/ref.md "Reference title"

            [Angle](<repo:docs/angle.md> "Angle title")

            转义 \<repo:docs/ok.md> 和 \<repo:docs/example.md>，普通 [URL](https://example.com/repo:docs/ok.md)。

            双反斜线 \\<repo:docs/slash.md>。

            ```text
            <repo:docs/ok.md>
            ```
            """#
            let message = RichChatMessage(id: UUID(), text: "File links", answer: answer)
            let expectedPaths = ["docs/ok.md", "docs/title.md", "docs/ref.md", "docs/angle.md", "docs/slash.md"]
            #expect(Set(message.references.map(\.path)).isSuperset(of: expectedPaths))
            #expect(!message.references.contains { $0.path == "unfinished" })
            renderer.update(messages: [message], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('a.repo').length===5")
            #expect(try await bool(web, "document.querySelectorAll('pre a').length===0 && document.body.textContent.includes('转义 <repo:docs/ok.md>')"))
            _ = try await web.evaluateJavaScript("document.querySelectorAll('a.repo').forEach(a=>a.click())")
            try await Task.sleep(for: .milliseconds(100))
            #expect(paths == expectedPaths)
        }

        @Test
        func svgDecoderUsesTheSameNormalizedPathAsTheLoader() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.imageLoader = { _, target in
                try paths.append(TerminalArtifactPreview.workspacePath(for: target))
                return Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="blue"/></svg>"#.utf8)
            }
            renderer.update(messages: [.init(id: UUID(), text: "SVG", answer: "![control](images/图.svg) ![encoded](images/图%2Esvg)")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(i=>i.naturalWidth===40 && i.src.startsWith('data:image/svg+xml')).length===2")
            #expect(paths == ["images/图.svg", "images/图.svg"])
            #expect(try await bool(web, "document.querySelectorAll('small.issue,.image-placeholder').length===0"))
        }

        @Test
        func svgLocalReferencesRemainVisibleWithoutExternalContent() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            let uses = (0..<57).map { "<use xlink:href=\"#glyph\" x=\"\($0 * 2)\" y=\"10\"/>" }.joined()
            let source = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="128" height="32" onload="window.svgInjected=true">
            <script>window.svgInjected=true</script><foreignObject><div>Unsafe</div></foreignObject>
            <defs><rect id="glyph" width="2" height="10" fill="red"/></defs>
            \(uses)<use href="https://example.com/external.svg#glyph"/>
            </svg>
            """
            renderer.imageLoader = { _, _ in Data(source.utf8) }
            renderer.update(messages: [.init(id: UUID(), text: "SVG references", answer: "![Chart](chart.svg)")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('img')?.naturalWidth===128 && !document.querySelector('.image-placeholder')")
            let result = try await web.callAsyncJavaScript("""
            const image=document.querySelector('.markdown-body img');
            const xml=atob(image.src.split(',')[1]);
            const svg=new DOMParser().parseFromString(xml,'image/svg+xml');
            const local=[...svg.querySelectorAll('use')].filter(e=>[...e.attributes].some(a=>a.localName==='href' && a.value.startsWith('#'))).length;
            const canvas=document.createElement('canvas');canvas.width=128;canvas.height=32;
            const context=canvas.getContext('2d');context.drawImage(image,0,0);
            const pixel=Array.from(context.getImageData(1,12,1,1).data);
            return {local,pixel,safe:!xml.includes('example.com') && !xml.includes('<script') && !xml.includes('foreignObject'),isolated:!document.querySelector('.markdown-body svg') && !window.svgInjected};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            #expect(result?["local"] as? Int == 57)
            #expect(result?["pixel"] as? [Int] == [255, 0, 0, 255])
            #expect(result?["safe"] as? Bool == true && result?["isolated"] as? Bool == true)
        }

        @Test
        func repeatedImagesReadOncePerMessageAndKeepEveryDisplayPosition() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), firstID = UUID(), secondID = UUID()
            let png = try smallPNG()
            var requests: [(UUID, String)] = []
            renderer.imageLoader = { id, target in requests.append((id, target))
                return png
            }
            let answer = Array(repeating: "![same](images/plot.png)", count: 24).joined(separator: " ") + " ![legend](images/legend.png)"
            let messages = [RichChatMessage(id: firstID, text: "Repeated", answer: answer), .init(id: secondID, text: "Separate source", answer: "![separate](images/plot.png)")]
            renderer.update(messages: messages, title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===26 && !document.querySelector('.image-placeholder')")
            #expect(requests.filter { $0.0 == firstID }.map(\.1).sorted() == ["images/legend.png", "images/plot.png"])
            #expect(requests.filter { $0.0 == secondID }.map(\.1) == ["images/plot.png"])
            #expect(try await bool(web, "!document.querySelector('small.issue')"))
            _ = try await web.evaluateJavaScript("window.savedImage=document.querySelector('img');void 0;")
            renderer.update(messages: messages, title: "Orbie", dark: true)
            try await wait(web, "document.documentElement.classList.contains('dark')")
            #expect(requests.count == 3)
            #expect(try await bool(web, "savedImage===document.querySelector('img')"))
        }

        @Test
        func uniqueImageQuotaAllowsDuplicatesAndIsReleasedWithRemovedMessages() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            let png = try smallPNG()
            var requests: [String] = []
            renderer.imageLoader = { _, target in requests.append(target)
                return png
            }
            let unique = (0..<24).map { "![image](images/\($0).png)" }.joined(separator: " ")
            renderer.update(messages: [.init(id: UUID(), text: "Quota", answer: unique + " ![repeat](images/0.png) ![over](images/over.png)")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===25 && document.querySelectorAll('small.issue').length===1")
            #expect(requests.count == 24 && requests.filter { $0 == "images/0.png" }.count == 1)
            #expect(!requests.contains("images/over.png"))
            renderer.update(messages: [.init(id: UUID(), text: "Fresh", answer: "![new](images/new.png)")], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('img').length===1 && document.querySelector('img').naturalWidth===16 && !document.querySelector('small.issue')")
            #expect(requests.last == "images/new.png" && requests.count == 25)
        }

        @Test
        func rollingPanelRetriesRetainedImagesWithoutResettingHTML() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            var requests: [(UUID, String)] = []
            renderer.imageLoader = { id, target in requests.append((id, target))
                return png
            }
            let old = RichChatMessage(id: UUID(), text: "Old", answer: (0..<24).map { "![image](old/\($0).png)" }.joined(separator: " "))
            let middle = RichChatMessage(id: UUID(), text: "Middle", answer: "A short reply.")
            let retained = RichChatMessage(id: UUID(), text: "Retained", answer: "![first](retained.png) ![again](retained.png)\n\n```html\n<input id=\"draft\" value=\"initial\">\n```")
            let newest = RichChatMessage(id: UUID(), text: "Newest", answer: "Another reply.")
            renderer.update(messages: [old], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===24")
            renderer.update(messages: [old, middle, retained], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('small.issue').length===2 && document.querySelector('iframe')?.title==='Interactive HTML preview'")
            #expect(requests.count == 24 && !requests.contains { $0.0 == retained.id })
            let frame = try #require(observer.frame)
            _ = try await web.callAsyncJavaScript("document.getElementById('draft').value='Keep my edits';", arguments: [:], in: frame, contentWorld: .page)
            _ = try await web.evaluateJavaScript("window.savedFrame=document.querySelector('iframe');void 0;")
            renderer.update(messages: [middle, retained, newest], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('img').length===2 && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===16 && !i.classList.contains('image-placeholder')) && !document.querySelector('small.issue')")
            #expect(requests.filter { $0.0 == retained.id }.map(\.1) == ["retained.png"])
            #expect(requests.count == 25)
            #expect(try await bool(web, "savedFrame===document.querySelector('iframe')"))
            let value = try await web.callAsyncJavaScript("return document.getElementById('draft').value;", arguments: [:], in: frame, contentWorld: .page)
            #expect(value as? String == "Keep my edits")
            let refreshed = RichChatMessage(id: retained.id, text: retained.text, answer: retained.answer, activity: ["Refreshed"])
            renderer.update(messages: [middle, refreshed, newest], title: "Orbie", dark: true)
            try await wait(web, "document.documentElement.classList.contains('dark') && document.querySelectorAll('.activity details p').length===1")
            #expect(requests.count == 25)
            #expect(try await bool(web, "savedFrame===document.querySelector('iframe')"))
        }

        @Test
        func quotaReleaseDiscardsRemovedAndChangedWaitingGroups() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            var requests: [String] = []
            renderer.imageLoader = { _, target in requests.append(target)
                return png
            }
            let old = RichChatMessage(id: UUID(), text: "Quota", answer: (0..<24).map { "![image](old/\($0).png)" }.joined(separator: " "))
            let removed = RichChatMessage(id: UUID(), text: "Removed", answer: "![removed](removed.png)")
            let changed = RichChatMessage(id: UUID(), text: "Changed", answer: "![stale](stale.png)")
            renderer.update(messages: [old], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===24")
            renderer.update(messages: [old, removed, changed], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('small.issue').length===2")
            renderer.update(messages: [
                .init(id: old.id, text: old.text, answer: "Quota released by an answer change."),
                .init(id: changed.id, text: changed.text, answer: "![current](current.png) ![again](current.png)"),
            ], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('img').length===2 && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===16) && !document.querySelector('small.issue')")
            #expect(!requests.contains("removed.png") && !requests.contains("stale.png"))
            #expect(requests.filter { $0 == "current.png" }.count == 1 && requests.count == 25)
        }

        @Test
        func quotaRetryReservesAvailableSlotsWithoutRetryingPermanentErrors() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            var requests: [String] = []
            renderer.imageLoader = { _, target in
                requests.append(target)
                if target == "unavailable.png" {
                    throw FileBrowserError.message("Image unavailable")
                }
                return png
            }
            let one = RichChatMessage(id: UUID(), text: "One slot", answer: "![one](one.png)")
            let rest = RichChatMessage(id: UUID(), text: "Remaining slots", answer: (0..<22).map { "![image](rest/\($0).png)" }.joined(separator: " ") + " ![unavailable](unavailable.png)")
            let waiting = RichChatMessage(id: UUID(), text: "Waiting", answer: "![first](first.png) ![again](first.png) ![second](second.png)")
            renderer.update(messages: [one, rest], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('small.issue').length===1 && [...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===23")
            renderer.update(messages: [one, rest, waiting], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('small.issue').length===4")
            #expect(requests.count == 24)
            renderer.update(messages: [rest, waiting], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('small.issue').length===2 && [...document.querySelectorAll('img')].filter(i=>i.naturalWidth===16).length===24")
            #expect(requests.filter { $0 == "first.png" }.count == 1 && !requests.contains("second.png"))
            #expect(requests.count == 25 && requests.filter { $0 == "unavailable.png" }.count == 1)
            renderer.update(messages: [rest, waiting], title: "Orbie", dark: true)
            try await wait(web, "document.documentElement.classList.contains('dark')")
            #expect(requests.count == 25)
            renderer.update(messages: [waiting], title: "Orbie", dark: true)
            try await wait(web, "document.querySelectorAll('img').length===3 && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===16) && !document.querySelector('small.issue')")
            #expect(requests.count == 26 && requests.filter { $0 == "first.png" }.count == 1 && requests.filter { $0 == "second.png" }.count == 1)
        }

        @Test
        func emptyAndTextSVGsShowLocalErrorsWhilePNGAndReplyRemainVisible() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            var requests: [String] = []
            renderer.imageLoader = { _, target in
                requests.append(target)
                if target == "empty.svg" {
                    return Data()
                }
                if target == "text.svg" {
                    return Data("not an SVG".utf8)
                }
                return png
            }
            renderer.update(messages: [.init(id: UUID(), text: "Invalid images", answer: "![empty](empty.svg) ![empty again](empty.svg) ![text](text.svg) ![good](good.png)\n\nReply continues.")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('small.issue').length===3 && document.querySelectorAll('img').length===1 && document.querySelector('img').naturalWidth===16")
            #expect(requests.count == 3 && requests.filter { $0 == "empty.svg" }.count == 1)
            #expect(try await bool(web, "!document.querySelector('.image-placeholder') && document.body.textContent.includes('Reply continues.') && [...document.querySelectorAll('small.issue')].every(e=>e.textContent==='This image cannot be decoded.')"))
            #expect(renderer.error == nil)
        }

        @Test
        func pendingDecodeKeepsPlaceholdersAndCannotModifyAReplacedReply() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            renderer.imageLoader = { _, _ in png }
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "!!window.orbieChat")
            _ = try await web.evaluateJavaScript("""
            window.pendingDecodes=[];
            const originalDecode=HTMLImageElement.prototype.decode;
            HTMLImageElement.prototype.decode=function(){return new Promise(resolve=>pendingDecodes.push(resolve)).then(()=>originalDecode.call(this))};
            void 0;
            """)
            renderer.update(messages: [.init(id: UUID(), text: "Old", answer: "![first](old.png) ![second](old.png)")], title: "Orbie", dark: false)
            try await wait(web, "pendingDecodes.length===2")
            #expect(try await bool(web, "document.querySelectorAll('.image-placeholder').length===2"))
            renderer.update(messages: [.init(id: UUID(), text: "New", answer: "![current](current.png)")], title: "Orbie", dark: false)
            try await wait(web, "pendingDecodes.length===3")
            _ = try await web.evaluateJavaScript("pendingDecodes.forEach(resolve=>resolve());pendingDecodes=[];void 0;")
            try await wait(web, "document.querySelectorAll('img').length===1 && document.querySelector('img').naturalWidth===16 && !document.querySelector('.image-placeholder')")
            #expect(try await bool(web, "document.querySelector('img').alt==='current' && !document.querySelector('small.issue')"))
        }

        @Test
        func oversizedImageTargetsAndEventsShowErrorsBeforeTheBridge() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.imageLoader = { _, target in
                paths.append(target)
                throw FileBrowserError.message("Normal image requested")
            }
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "!!window.orbieChat")
            _ = try await web.evaluateJavaScript("window.imageEventSizes=[];document.addEventListener('orbie-native',e=>{if(JSON.parse(e.detail).kind==='image')imageEventSizes.push(new TextEncoder().encode(e.detail).length)});void 0;")
            let dataURL = "data:image/png;base64," + Data(repeating: 65, count: 20_000).base64EncodedString()
            let longPath = "images/" + String(repeating: "a", count: 4_096) + ".png"
            let escapedEventPath = String(repeating: "&#1;", count: 3_000) + ".png"
            let answer = "![data](\(dataURL)) ![long](\(longPath))\n\nInline <img data-image-key=\"event-limit\" data-image-reference=\"\(escapedEventPath)\">\n\n![normal](images/normal.png)"
            #expect(answer.utf8.count < 512 * 1_024)
            renderer.update(messages: [.init(id: UUID(), text: "Bounded images", answer: answer)], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('small.issue').length===4")
            #expect(paths == ["images/normal.png"])
            #expect(try await bool(web, "document.querySelectorAll('.image-placeholder').length===0 && imageEventSizes.length===1 && imageEventSizes.every(n=>n<=16384)"))
            #expect(try await bool(web, "[...document.querySelectorAll('small.issue')].filter(e=>e.textContent==='Image address exceeds the preview limit.').length===3"))
        }

        @Test
        func mixedReplyKeepsHTMLStateAndRejectsFrameActions() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var references: [String] = [], actions: [String] = []
            renderer.onReference = { _, path in references.append(path) }
            renderer.onAction = { _, action in actions.append(action) }
            let id = UUID()
            let answer = """
            ## 混合回复

            文件 `<repo:docs/图%20片.md>`。

            | Name | Value |
            | --- | --- |
            | Result | 42 |

            ```json
            {"mixed":true}
            ```

            ```html
            <!doctype html><html><head><style>button { color: rgb(20, 80, 160); }</style></head><body>
            <button id="counter" onclick="this.textContent=Number(this.textContent)+1">0</button>
            <script>
            document.getElementById('counter').click();
            console.log('counter='+document.getElementById('counter').textContent);
            try { parent.document.body.textContent='ESCAPED'; } catch { console.log('ISOLATED'); }
            try { webkit.messageHandlers.orbie.postMessage(JSON.stringify({kind:'action',messageID:'\(id)',target:'copy'})); } catch { console.log('NO_BRIDGE'); }
            fetch('https://example.com').catch(()=>console.log('NETWORK_BLOCKED'));
            </script>
            </body></html>
            ```

            回复尾部完整保留。
            """
            let model = RichChatMessage(id: id, text: "Show a mixed reply", answer: answer, actions: [.init(id: "copy", title: "Copy Reply")])
            renderer.update(messages: [model], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('iframe').length===1 && window.orbieChat.activeWidgets()===1")
            try await Task.sleep(for: .seconds(1))
            #expect(try await bool(web, "document.querySelector('h2').textContent==='混合回复' && !!document.querySelector('table') && document.body.textContent.includes('回复尾部完整保留')"))
            #expect(try await bool(web, "document.querySelector('iframe').contentDocument===null"))
            #expect(try await bool(web, "getComputedStyle(document.querySelector('[data-generative-frame]')).opacity==='1' && document.querySelector('iframe').getBoundingClientRect().height>=60"))
            let frame = try #require(observer.frame)
            let count = try await web.callAsyncJavaScript("document.getElementById('counter').click();return document.getElementById('counter').textContent;", arguments: [:], in: frame, contentWorld: .page)
            #expect(count as? String == "2")
            let color = try await web.callAsyncJavaScript("return getComputedStyle(document.getElementById('counter')).color;", arguments: [:], in: frame, contentWorld: .page)
            #expect(color as? String == "rgb(20, 80, 160)")
            let isolated = try await web.callAsyncJavaScript("try {parent.document.body.textContent='escaped';return false;}catch{return true;}", arguments: [:], in: frame, contentWorld: .page)
            #expect(isolated as? Bool == true)
            let networkBlocked = try await web.callAsyncJavaScript("try {await fetch('https://example.com');return false;}catch{return true;}", arguments: [:], in: frame, contentWorld: .page)
            #expect(networkBlocked as? Bool == true)
            _ = try await web.evaluateJavaScript("window.savedFrame=document.querySelector('iframe');document.querySelector('a.repo').click()")
            try await Task.sleep(for: .milliseconds(100))
            #expect(references == ["docs/图 片.md"])
            #expect(actions.isEmpty)
            try await saveEvidence(web, name: "mixed-reply-light.png")
            renderer.update(messages: [model], title: "Orbie", dark: true)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await bool(web, "window.savedFrame===document.querySelector('iframe') && document.documentElement.classList.contains('dark')"))
            let preserved = try await web.callAsyncJavaScript("return document.getElementById('counter').textContent;", arguments: [:], in: frame, contentWorld: .page)
            #expect(preserved as? String == "2")
            try await saveEvidence(web, name: "mixed-reply-dark.png")
            _ = try await web.evaluateJavaScript("document.querySelector('.actions button').click()")
            try await Task.sleep(for: .milliseconds(100))
            #expect(actions == ["copy"])
            _ = try await web.evaluateJavaScript("document.querySelector('[data-expand]').click()")
            #expect(try await bool(web, "Math.abs(document.querySelector('.card.expanded').getBoundingClientRect().height-(innerHeight-20))<2"))
            _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
            #expect(try await bool(web, "document.querySelectorAll('.card.expanded').length===0"))
            _ = try await web.evaluateJavaScript("const run=[...document.querySelectorAll('.card-header button')].find(button=>button.textContent==='Run again');run.click();run.click();")
            let deadline = ContinuousClock.now + .seconds(5)
            var restartedCount: String?
            while ContinuousClock.now < deadline {
                if let frame = observer.frame {
                    restartedCount = (try? await web.callAsyncJavaScript("return document.getElementById('counter')?.textContent;", arguments: [:], in: frame, contentWorld: .page)) as? String
                    if restartedCount == "1" {
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(restartedCount == "1")
            #expect(actions == ["copy"])
            renderer.stop()
            #expect(renderer.webView == nil)
        }

        final private class FrameObserver: NSObject, WKScriptMessageHandler {
            var frame: WKFrameInfo?
            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                if !message.frameInfo.isMainFrame {
                    frame = message.frameInfo
                }
            }
        }

        @Test
        func repoActionsFollowMarkdownTokensAndPreserveEscapedExamples() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.onReference = { _, path in paths.append(path) }
            let answer = #"""
            正文 <repo:docs/图%20片.md>。

            [文件](repo:docs/图%20片.md) 和 `<repo:docs/图%20片.md>`，兼容 (repo:docs/图%20片.md)。

            转义 \<repo:docs/图%20片.md> 与 \(repo:docs/图%20片.md)。

            ```text
            <repo:docs/图%20片.md>
            ```

            无效 <repo:../secret>，普通 [网页](https://example.com)。
            """#
            renderer.update(messages: [.init(id: UUID(), text: "References", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('a.repo').length===4")
            #expect(try await bool(web, "document.querySelectorAll('pre a').length===0 && document.querySelectorAll('iframe').length===0"))
            #expect(try await bool(web, "document.body.textContent.includes('转义 <repo:docs/图%20片.md> 与 (repo:docs/图%20片.md)')"))
            #expect(try await bool(web, "document.querySelector('a[href=\"https://example.com\"]').textContent==='网页'"))
            _ = try await web.evaluateJavaScript("document.querySelectorAll('a.repo').forEach(a=>a.click())")
            try await Task.sleep(for: .milliseconds(100))
            #expect(paths == Array(repeating: "docs/图 片.md", count: 4))
        }

        @Test
        func parsedImageTargetsReachLoaderAndFailuresReplacePlaceholder() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.imageLoader = { _, path in
                paths.append(path)
                throw FileBrowserError.message("Image unavailable: \(path)")
            }
            let answer = #"![escaped](a\(draft\).png) ![unicode](images/图%20片.png) ![relative](./images/plot.png)"#
            renderer.update(messages: [.init(id: UUID(), text: "Images", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('small.issue').length===3")
            #expect(Set(paths) == ["a(draft).png", "images/图%20片.png", "./images/plot.png"])
            #expect(try await bool(web, "document.querySelectorAll('.image-placeholder').length===0 && document.body.textContent.includes('Image unavailable: a(draft).png')"))
        }

        @Test
        func manualPauseSurvivesVisibilityAndActivityUpdatesUntilExplicitRun() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "!!window.orbieChat")
            _ = try await web.evaluateJavaScript("""
            window.cardObservers=[];
            const NativeObserver=IntersectionObserver;
            window.IntersectionObserver=class extends NativeObserver {
                constructor(callback, options){super(callback,options);this.callback=callback;cardObservers.push(this);}
                observe(target){this.target=target;super.observe(target);}
            };
            void 0;
            """)
            let id = UUID(), answer = "```html\n<button>Interactive</button>\n```"
            renderer.update(messages: [.init(id: id, text: "Pause", answer: answer)], title: "Orbie", dark: false)
            try await wait(web, "orbieChat.activeWidgets()===1")
            _ = try await web.evaluateJavaScript("[...document.querySelectorAll('button')].find(b=>b.textContent==='Pause').click()")
            #expect(try await bool(web, "orbieChat.activeWidgets()===0"))
            renderer.update(messages: [.init(id: id, text: "Pause", answer: answer, activity: ["Updated"])], title: "Orbie", dark: true)
            try await wait(web, "document.documentElement.classList.contains('dark')")
            let cycle = "const observer=cardObservers.find(o=>o.target?.classList.contains('card'));observer.callback([{isIntersecting:false,target:observer.target}]);observer.callback([{isIntersecting:true,target:observer.target}]);"
            _ = try await web.evaluateJavaScript("{\(cycle)}")
            #expect(try await bool(web, "orbieChat.activeWidgets()===0 && document.body.textContent.includes('Preview paused. Choose Run again')"))
            _ = try await web.evaluateJavaScript("[...document.querySelectorAll('button')].find(b=>b.textContent==='Run again').click()")
            try await wait(web, "orbieChat.activeWidgets()===1")
            _ = try await web.evaluateJavaScript("{\(cycle)}")
            try await wait(web, "orbieChat.activeWidgets()===1")
        }

        @Test
        func activityKeepsUserChoiceAndUsesRecentThreeUntilCompletion() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), id = UUID()
            func model(_ count: Int, pending: Bool) -> RichChatMessage {
                .init(id: id, text: "Activity", answer: pending ? nil : "Done", activity: (1...count).map { "Progress \($0)" }, pending: pending)
            }
            renderer.update(messages: [model(4, pending: true)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('.recent-activity p').length===3")
            #expect(try await bool(web, "!document.querySelector('.activity details').open && document.querySelector('.recent-activity p').textContent==='Progress 2'"))
            _ = try await web.evaluateJavaScript("document.querySelector('.activity details').open=true")
            renderer.update(messages: [model(5, pending: true)], title: "Orbie", dark: false)
            try await wait(web, "document.querySelector('.recent-activity').textContent.includes('Progress 5')")
            #expect(try await bool(web, "document.querySelector('.activity details').open"))
            _ = try await web.evaluateJavaScript("document.querySelector('.activity details').open=false")
            renderer.update(messages: [model(6, pending: true)], title: "Orbie", dark: false)
            try await wait(web, "document.querySelector('.recent-activity').textContent.includes('Progress 6')")
            #expect(try await bool(web, "!document.querySelector('.activity details').open"))
            renderer.update(messages: [model(6, pending: false)], title: "Orbie", dark: false)
            try await wait(web, "document.querySelectorAll('.recent-activity').length===0 && document.querySelectorAll('.activity details p').length===6")
            #expect(try await bool(web, "!document.querySelector('.activity details').open"))
        }

        @Test
        func largeHistoryPublishesLatestUpdateAndKeepsUnchangedFrame() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            let answer = String(repeating: "Paragraph ", count: 6_554)
            var history = (0..<99).map { RichChatMessage(id: UUID(), text: "History \($0)", answer: answer) }
            let id = UUID(), interactive = "```html\n<button>Keep this frame</button>\n```"
            history.append(.init(id: id, text: "Current", answer: interactive))
            renderer.update(messages: history, title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('article').length===100 && !!document.querySelector('iframe')")
            _ = try await web.evaluateJavaScript("window.savedFrame=document.querySelector('iframe');void 0;")
            for count in 1...12 {
                history[99] = .init(id: id, text: "Current", answer: interactive, activity: ["Update \(count)"])
                renderer.update(messages: history, title: "Orbie", dark: false)
                await Task.yield()
            }
            try await wait(web, "document.querySelector('article:last-child .activity').textContent.includes('Update 12')")
            #expect(try await bool(web, "savedFrame===document.querySelector('iframe')"))
            renderer.stop()
            renderer.update(messages: [.init(id: UUID(), text: "New conversation", answer: "Recovered")], title: "Orbie", dark: true)
            renderer.start()
            let replacement = try #require(renderer.webView)
            window.contentView = replacement
            try await wait(replacement, "document.querySelectorAll('article').length===1 && document.body.textContent.includes('Recovered')")
        }

        @Test
        func rendersDiagramAndWorkspaceImageInBothThemes() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var imageRequests: [String] = []
            renderer.imageLoader = { _, path in
                imageRequests.append(path)
                let image = NSImage(size: .init(width: 120, height: 40))
                image.lockFocus()
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: .init(x: 0, y: 0, width: 120, height: 40), xRadius: 8, yRadius: 8).fill()
                image.unlockFocus()
                let tiff = try #require(image.tiffRepresentation)
                return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            }
            let message = RichChatMessage(id: UUID(), text: "展示方案和可交互示例", answer: """
            ## 阅读与操作放在一起

            打开方案 `<repo:docs/rendering-plan.md>`，也可以直接调整下面的预算。

            | 内容 | 呈现方式 |
            | --- | --- |
            | Markdown / 代码 | 正文与代码卡片 |
            | HTML / JavaScript | 内联交互预览 |

            ```html
            <section style="padding:16px;font:14px -apple-system">
              <h3 style="margin:0 0 12px">调整预算，立即查看结果</h3>
              <div style="display:flex;justify-content:space-between"><span>月度预算</span><strong id="amount">¥ 2,400</strong></div>
              <input aria-label="月度预算" type="range" min="0" max="4000" value="2400" style="width:100%;margin:16px 0" oninput="document.getElementById('amount').textContent='¥ '+Number(this.value).toLocaleString()">
              <small>调整滑杆查看变化</small>
            </section>
            ```

            ```mermaid
            flowchart LR
              Input[请求] --> Render[混合渲染] --> Reply[继续对话]
            ```

            ![工作区图片](images/figure.png)
            """, actions: [.init(id: "copy", title: "Copy Reply")])
            renderer.update(messages: [message], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            window.setContentSize(.init(width: 680, height: 900))
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('img')].filter(image=>image.complete && image.naturalWidth>0).length===2")
            try await wait(web, "document.querySelector('.widget iframe').getBoundingClientRect().height>120")
            #expect(imageRequests == ["images/figure.png"])
            _ = try await web.evaluateJavaScript("window.scrollTo(0,0)")
            try await saveEvidence(web, name: "rich-content-light.png")
            renderer.update(messages: [message], title: "Orbie", dark: true)
            try await Task.sleep(for: .milliseconds(250))
            try await saveEvidence(web, name: "rich-content-dark.png")
        }

        @Test
        func longRepliesRemainWholeAndCodeExamplesAreNotFileActions() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            let answer = "    <div>Indented HTML stays code</div>\n\n" + String(repeating: "这是完整段落。\n\n", count: 800) + """
            ```text
            <repo:example.swift>
            ```

            ```html
            <button>unfinished
            """
            renderer.update(messages: [.init(id: UUID(), text: "Long reply", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView)
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('pre').length===3")
            #expect(try await bool(web, "document.body.textContent.includes('unfinished') && document.querySelectorAll('a.repo').length===0 && document.querySelectorAll('iframe').length===0"))
        }

        @Test
        func pngFixtureContainsOpaqueDeviceBlue() throws {
            let image = try #require(NSBitmapImageRep(data: smallPNG()))
            #expect(image.pixelsWide == 16 && image.pixelsHigh == 16)
            var pixel = [Int](repeating: 0, count: image.samplesPerPixel)
            image.getPixel(&pixel, atX: 0, y: 0)
            #expect(pixel == [0, 0, 255, 255])
        }

        private func smallPNG() throws -> Data {
            let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
            for y in 0..<16 {
                for x in 0..<16 {
                    image.setColor(blue, atX: x, y: y)
                }
            }
            return try #require(image.representation(using: .png, properties: [:]))
        }

        private func mount(_ web: WKWebView) -> NSWindow {
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 680, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.orderBack(nil)
            return window
        }

        private func saveEvidence(_ web: WKWebView, name: String) async throws {
            guard let path = ProcessInfo.processInfo.environment["CTRLX_ORBIE_RENDER_EVIDENCE_DIR"] else { return }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let image = try await web.takeSnapshot(configuration: nil)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent(name))
        }

        private func bool(_ web: WKWebView, _ expression: String) async throws -> Bool {
            try await web.evaluateJavaScript(expression) as? Bool == true
        }

        private func wait(_ web: WKWebView, _ expression: String) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                if (try? await bool(web, expression)) == true {
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("Conversation did not render: \(expression)")
        }
    }
#endif

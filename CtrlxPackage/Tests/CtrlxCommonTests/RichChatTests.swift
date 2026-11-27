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
        func previewKindsUseFileExtensionsAndPreserveExplicitDirectories() {
            let answer = "<repo:html> <repo:html/> <repo:png/> <repo:dir/page.html/> <repo:dir/page.svg%2F> <repo:page.HTML> <repo:plot.svg> <repo:literal%252F.svg>"
            let references = RichChatMessage(id: UUID(), text: "", answer: answer).references
            #expect(references.map(\.previewKind) == [nil, nil, nil, nil, nil, .html, .image, .image])
            #expect(references.last?.path == "literal%2F.svg")
        }

        @Test(arguments: [1, 2])
        func imageAliasesShareOneReadAndKeepExplicitMarkdownPositions(positions: Int) async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.imageLoader = { _, path in
                paths.append(path)
                return Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16"><rect width="24" height="16" fill="blue"/></svg>"#.utf8)
            }
            let answer = "![first](./图.svg)\n\n" + (positions == 2 ? "![second](folder/../%E5%9B%BE.svg)\n\n" : "") + "<repo:图.svg> <repo:%E5%9B%BE.svg>"
            renderer.update(messages: [.init(id: UUID(), text: "Aliases", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('img').length===\(positions) && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===24 && !i.classList.contains('image-placeholder'))")
            #expect(paths == ["图.svg"])
            #expect(try await bool(web, "!document.querySelector('.file-image') && document.querySelectorAll('a.repo').length===2 && !document.querySelector('small.issue')"))
        }

        @Test
        func HTMLAliasesDoNotConsumeAnotherFilesPreviewSlot() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.htmlLoader = { _, path in paths.append(path)
                return Data("<p>\(path)</p>".utf8)
            }
            let answer = "<repo:图.html> <repo:%E5%9B%BE.html>\n\n<repo:b.htm>\n\n<repo:c.html>\n\n<repo:d.html>"
            renderer.update(messages: [.init(id: UUID(), text: "Four files", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('.card').length===4 && [...document.querySelectorAll('iframe')].filter(f=>f.title==='Interactive HTML preview').length===4")
            #expect(paths.sorted() == ["b.htm", "c.html", "d.html", "图.html"])
            #expect(try await bool(web, "!document.body.innerText.includes('at most four HTML files') && !document.body.innerText.includes('Loading HTML preview') && document.querySelectorAll('a.repo').length===5"))
        }

        @Test
        func explicitDirectoryLinksNeverStartAnAutomaticPreview() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.imageLoader = { _, path in paths.append(path)
                throw FileBrowserError.message("Unexpected image")
            }
            renderer.htmlLoader = { _, path in paths.append(path)
                return Data("<p>Valid HTML</p>".utf8)
            }
            let answer = "<repo:html> <repo:html/> <repo:png/> <repo:dir/page.html/> <repo:dir/image.svg%2F>\n\n<repo:page.HTML>"
            renderer.update(messages: [.init(id: UUID(), text: "Directories", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('iframe')?.title==='Interactive HTML preview'")
            #expect(paths == ["page.HTML"])
            #expect(try await bool(web, "document.querySelectorAll('a.repo').length===6 && !document.querySelector('img') && !document.body.innerText.includes('Loading HTML preview')"))
        }

        @Test
        func repoImagesReadLiteralBackslashAndPercentFilenamesWithoutURLParsing() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16"><rect width="24" height="16" fill="red"/></svg>"#.utf8)
            for name in ["chart\\example.svg", "literal%2F.svg"] {
                try svg.write(to: root.appendingPathComponent(name))
            }
            let renderer = RichChatRenderer()
            var paths: [String] = [], references: [String] = []
            renderer.imageLoader = { _, path in paths.append(path)
                return try Data(contentsOf: root.appendingPathComponent(path))
            }
            renderer.onReference = { _, path in references.append(path) }
            renderer.update(messages: [.init(id: UUID(), text: "Literal names", answer: "`<repo:chart%5Cexample.svg>` <repo:literal%252F.svg>\n\n![Markdown remains restricted](chart%5Cexample.svg)")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('img').length===2 && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===24) && document.querySelectorAll('small.issue').length===1")
            #expect(paths.sorted() == ["chart\\example.svg", "literal%2F.svg"])
            #expect(try await bool(web, "document.body.innerText.includes('Only files inside this workspace')"))
            _ = try await web.evaluateJavaScript("document.querySelector('a.repo').click()")
            try await Task.sleep(for: .milliseconds(50))
            #expect(references == ["chart\\example.svg"])
        }

        @Test(arguments: ["file", "fence", "implicit-fence"])
        func completeHTMLFilePreservesDocumentAttributesBeforeScriptsRun(mode: String) async throws {
            _ = NSApplication.shared
            let document = #"""
            <!doctype html><html lang="zh-CN" dir="rtl" data-document="kept"><head data-head="kept">
            <meta name="initial" content="41"><script>window.headParent=document.currentScript.parentElement===document.head;</script>
            <style>body.app > #result { color:rgb(12,34,56); }</style></head>
            <body id="page" class="app" data-initial="41" data-sample="x</script>y" onload="document.body.dataset.loaded='yes'">
            <p id="result">waiting</p><script>document.getElementById('result').textContent=Number(document.head.querySelector('meta[name=initial]').content)+1;</script>
            </body></html>
            """#
            let source = mode == "implicit-fence" ? document
                .replacingOccurrences(of: #"<!doctype html><html lang="zh-CN" dir="rtl" data-document="kept"><head data-head="kept">"#, with: "")
                .replacingOccurrences(of: "</head>", with: "")
                .replacingOccurrences(of: "</html>", with: "") : document
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let direct = WKWebView(frame: .zero, configuration: configuration), directWindow = mount(direct)
            defer { directWindow.close() }
            direct.loadHTMLString(source, baseURL: nil)
            try await wait(direct, "document.querySelector('#result')?.textContent==='42' && document.body.dataset.loaded==='yes'")
            let inspect = "return {value:document.getElementById('result').textContent,color:getComputedStyle(document.getElementById('result')).color,lang:document.documentElement.lang,dir:document.documentElement.dir,body:document.body.id,initial:document.body.dataset.initial,sample:document.body.dataset.sample,head:document.head.dataset.head??'',loaded:document.body.dataset.loaded,headScript:String(window.headParent),metaParent:String(document.head.querySelector('meta[name=initial]').parentElement===document.head),directChild:String(document.getElementById('result').parentElement===document.body)};"
            let baseline = try await direct.callAsyncJavaScript(inspect, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
            let renderer = RichChatRenderer()
            renderer.htmlLoader = { _, _ in Data(source.utf8) }
            renderer.update(messages: [.init(id: UUID(), text: "Whole document", answer: mode == "file" ? "<repo:page.html>" : "```html\n\(source)\n```")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('iframe')?.title==='Interactive HTML preview'")
            let frame = try #require(observer.frame)
            let actual = try await web.callAsyncJavaScript("for(let n=0;n<100 && document.body.dataset.loaded!=='yes';n++)await new Promise(resolve=>setTimeout(resolve,20));" + inspect, arguments: [:], in: frame, contentWorld: .page) as? [String: String]
            #expect(baseline?["value"] == "42" && baseline?["color"] == "rgb(12, 34, 56)")
            #expect(actual == baseline)
            #expect(actual?["headScript"] == "true" && actual?["metaParent"] == "true" && actual?["directChild"] == "true")
            #expect(try await bool(web, "document.querySelector('iframe').contentDocument===null && !document.querySelector('#result')"))
        }

        @Test(arguments: ["file", "fence"], [180, 600])
        func documentMarginsKeepBottomContentVisible(mode: String, height: Int) async throws {
            _ = NSApplication.shared
            let source = """
            <!doctype html><html><head><style>body { margin:24px; } #total { height:\(height)px;display:flex;align-items:flex-end; }</style></head>
            <body><main id="total"><span id="bottom">Bottom content</span></main></body></html>
            """
            let renderer = RichChatRenderer()
            renderer.htmlLoader = { _, _ in Data(source.utf8) }
            renderer.update(messages: [.init(id: UUID(), text: "Document margins", answer: mode == "file" ? "<repo:page.html>" : "```html\n\(source)\n```")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('iframe')?.title==='Interactive HTML preview' && document.querySelector('iframe').getBoundingClientRect().height>100")
            let frame = try #require(observer.frame)
            let metrics = try await web.callAsyncJavaScript("""
            const overflow=getComputedStyle(document.documentElement).overflowY;
            if (innerHeight===480) window.scrollTo(0,document.documentElement.scrollHeight);
            return {viewport:innerHeight,bottom:document.getElementById('bottom').getBoundingClientRect().bottom,overflow,scrolled:scrollY>0};
            """, arguments: [:], in: frame, contentWorld: .page) as? [String: Any]
            #expect(metrics?["viewport"] as? Int == min(height + 48, 480))
            #expect(try #require(metrics?["bottom"] as? Double) <= Double(try #require(metrics?["viewport"] as? Int)))
            #expect(metrics?["overflow"] as? String == (height + 48 > 480 ? "auto" : "hidden"))
            #expect(metrics?["scrolled"] as? Bool == (height + 48 > 480))
        }

        @Test
        func documentContentSizeCanShrinkWithoutViewportFloor() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "!!window.OrbieWidgets")
            _ = try await web.evaluateJavaScript("""
            const container=document.createElement('div');document.body.append(container);
            window.testEnded=false;
            window.testWidget=OrbieWidgets.createWidget({container,code:OrbieWidgets.prepareDocument('<html><head><style>body { margin:24px; }</style></head><body><div id="content" style="height:600px">Content</div></body></html>',true),opaqueOrigin:true,csp:{cdnOrigins:[]},animate:false,minHeight:60,maxHeight:480});
            testWidget.on('end',()=>window.testEnded=true);void 0;
            """)
            try await wait(web, "testEnded")
            let tall = try await web.callAsyncJavaScript("return (await testWidget.inspect()).size.height;", arguments: [:], in: nil, contentWorld: .page)
            #expect(tall as? Int == 648)
            let frame = try #require(observer.frame)
            _ = try await web.callAsyncJavaScript("document.getElementById('content').style.height='180px';", arguments: [:], in: frame, contentWorld: .page)
            let short = try await web.callAsyncJavaScript("return (await testWidget.inspect()).size.height;", arguments: [:], in: nil, contentWorld: .page)
            #expect(short as? Int == 228)
            try await wait(web, "testWidget.iframe.getBoundingClientRect().height===228")
            _ = try await web.callAsyncJavaScript("document.body.style.marginTop='48px';", arguments: [:], in: frame, contentWorld: .page)
            try await wait(web, "testWidget.iframe.getBoundingClientRect().height===252")
            _ = try await web.evaluateJavaScript("testWidget.dispose()")
        }

        @Test
        func completeDocumentKeepsRuntimeAndSizingAfterReplacingBodyContents() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            renderer.htmlLoader = { _, _ in Data(#"""
            <!doctype html><html><head><meta name="initial" content="41"><style>body { margin:0;padding:16px; }</style></head>
            <body><p>waiting</p><script>document.body.innerHTML='<div id="total" style="height:180px">'+(Number(document.head.querySelector('meta[name=initial]').content)+1)+'</div>';</script></body></html>
            """#.utf8) }
            renderer.update(messages: [.init(id: UUID(), text: "Body replacement", answer: "<repo:page.html>")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('iframe')?.getBoundingClientRect().height>=212")
            let frame = try #require(observer.frame)
            let value = try await web.callAsyncJavaScript("return document.querySelector('body > #total')?.textContent;", arguments: [:], in: frame, contentWorld: .page)
            #expect(value as? String == "42")
            #expect(try await bool(web, "[...document.querySelectorAll('.card-error')].every(e=>!e.textContent)"))
        }

        @Test
        func documentReplacementRemountsAndKeepsFragmentRenderingAndTheme() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "!!window.OrbieWidgets")
            _ = try await web.evaluateJavaScript("""
            const container=document.createElement('div');document.body.append(container);
            window.testEnded=false;
            window.testDocument='<html style="--document-value:42"><head><meta name="value" content="42"></head><body><p id="total">42</p></body></html>';
            window.testWidget=OrbieWidgets.createWidget({container,code:OrbieWidgets.prepareDocument(testDocument,true),opaqueOrigin:true,csp:{cdnOrigins:[]},animate:false,minHeight:60,tokens:OrbieWidgets.defaultThemeTokens('dark')});
            testWidget.on('end',()=>window.testEnded=true);void 0;
            """)
            try await wait(web, "testEnded")
            let initial = try #require(observer.frame)
            let initialTheme = try await web.callAsyncJavaScript("return genframe.theme==='dark' && document.documentElement.dataset.theme==='dark' && getComputedStyle(document.documentElement).colorScheme==='dark' && document.documentElement.style.getPropertyValue('--document-value')==='42';", arguments: [:], in: initial, contentWorld: .page)
            #expect(initialTheme as? Bool == true)
            _ = try await web.callAsyncJavaScript("window.oldDocument=testWidget.iframe;await testWidget.replace('<button id=fragment>Fragment</button>');", arguments: [:], in: nil, contentWorld: .page)
            #expect(try await bool(web, "oldDocument!==testWidget.iframe && !oldDocument.isConnected"))
            let fragment = try #require(observer.frame)
            let isFragment = try await web.callAsyncJavaScript("return document.querySelector('#gf-root > #fragment')?.textContent;", arguments: [:], in: fragment, contentWorld: .page)
            #expect(isFragment as? String == "Fragment")
            _ = try await web.callAsyncJavaScript("window.oldFragment=testWidget.iframe;await testWidget.replace(OrbieWidgets.prepareDocument(testDocument,true));testWidget.setTheme(OrbieWidgets.defaultThemeTokens('dark'));await testWidget.inspect();", arguments: [:], in: nil, contentWorld: .page)
            #expect(try await bool(web, "oldFragment!==testWidget.iframe && !oldFragment.isConnected"))
            let document = try #require(observer.frame)
            let themed = try await web.callAsyncJavaScript("return document.querySelector('body > #total')?.textContent==='42' && !!document.head.querySelector('meta[name=value]') && genframe.theme==='dark';", arguments: [:], in: document, contentWorld: .page)
            #expect(themed as? Bool == true)
            _ = try await web.callAsyncJavaScript("document.body.innerHTML='<div style=\"height:180px\">Updated</div>';", arguments: [:], in: document, contentWorld: .page)
            let height = try await web.callAsyncJavaScript("return (await testWidget.inspect()).size.height;", arguments: [:], in: nil, contentWorld: .page)
            #expect(height as? Int == 180)
            _ = try await web.evaluateJavaScript("testWidget.dispose()")
        }

        @Test
        func repoImageLinksPreviewWithoutDuplicatingMarkdownImages() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), png = try smallPNG()
            var requests: [String] = [], references: [String] = []
            renderer.imageLoader = { _, path in requests.append(path)
                return png
            }
            renderer.onReference = { _, path in references.append(path) }
            let answer = #"""
            四款商品图放在一起，方便比较：`<repo:outputs/背%20包.jpg>`。

            [再次打开](repo:outputs/背%20包.jpg)

            ![已有图片](outputs/direct.png)

            <repo:outputs/direct.png>

            转义 \<repo:outputs/example.png>。

            ```text
            <repo:outputs/code.png>
            ```
            """#
            renderer.update(messages: [.init(id: UUID(), text: "图片引用", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelectorAll('img').length===2 && [...document.querySelectorAll('img')].every(i=>i.naturalWidth===16 && !i.classList.contains('image-placeholder'))")
            #expect(requests.sorted() == ["outputs/direct.png", "outputs/背 包.jpg"])
            #expect(try await bool(web, "document.querySelectorAll('a.repo').length===3 && document.querySelectorAll('.file-image').length===1 && !document.querySelector('pre img')"))
            _ = try await web.evaluateJavaScript("document.querySelector('a.repo').click()")
            try await Task.sleep(for: .milliseconds(50))
            #expect(references == ["outputs/背 包.jpg"])
        }

        @Test
        func repoHTMLFileRunsInIsolatedFrameAndSurvivesRefresh() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), id = UUID()
            var requests: [(UUID, String)] = []
            let png = try smallPNG().base64EncodedString()
            renderer.htmlLoader = { id, path in
                requests.append((id, path))
                return Data("<button id='counter' onclick='this.textContent=Number(this.textContent)+1'>0</button><img src='data:image/png;base64,\(png)'><script>window.fileScriptRan=true;</script>".utf8)
            }
            let answer = "已改成本地单文件网页：`<repo:outputs/图%2525表.html>`。\n\n[再次打开](repo:outputs/图%2525表.html)"
            renderer.update(messages: [.init(id: id, text: "直接写一个本地网页", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), observer = FrameObserver()
            web.configuration.userContentController.add(observer, name: "chatTest")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window.parent!==window)window.webkit.messageHandlers.chatTest.postMessage('frame');", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.querySelector('iframe')?.title==='Interactive HTML preview'")
            let frame = try #require(observer.frame)
            let result = try await web.callAsyncJavaScript("await document.querySelector('img').decode();document.getElementById('counter').click();return {count:document.getElementById('counter').textContent,script:window.fileScriptRan,image:document.querySelector('img').naturalWidth};", arguments: [:], in: frame, contentWorld: .page) as? [String: Any]
            #expect(result?["count"] as? String == "1" && result?["script"] as? Bool == true && result?["image"] as? Int == 16)
            #expect(requests.count == 1 && requests.first?.0 == id && requests.first?.1 == "outputs/图%25表.html")
            #expect(try await bool(web, "!window.fileScriptRan && document.querySelector('iframe').contentDocument===null && document.querySelectorAll('a.repo').length===2"))
            let blocked = try await web.callAsyncJavaScript("try {await fetch('https://example.com');return false;}catch{return true;}", arguments: [:], in: frame, contentWorld: .page)
            #expect(blocked as? Bool == true)
            _ = try await web.evaluateJavaScript("window.savedFrame=document.querySelector('iframe');void 0;")
            renderer.update(messages: [.init(id: id, text: "直接写一个本地网页", answer: answer, activity: ["Refreshed"])], title: "Orbie", dark: true)
            try await wait(web, "document.documentElement.classList.contains('dark')")
            #expect(try await bool(web, "savedFrame===document.querySelector('iframe')"))
            #expect(requests.count == 1)
            let value = try await web.callAsyncJavaScript("return document.getElementById('counter').textContent;", arguments: [:], in: frame, contentWorld: .page)
            #expect(value as? String == "1")
        }

        @Test
        func HTMLFileFailuresAreLocalAndReadCountIsBounded() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer()
            var paths: [String] = []
            renderer.htmlLoader = { _, path in paths.append(path)
                return Data()
            }
            let answer = (0..<5).map { "`<repo:outputs/\($0).html>`" }.joined(separator: "\n\n") + "\n\n正文继续显示。"
            renderer.update(messages: [.init(id: UUID(), text: "HTML files", answer: answer)], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "[...document.querySelectorAll('.markdown-body .issue')].filter(e=>e.textContent.includes('UTF-8')).length===4")
            #expect(paths.count == 4 && !paths.contains("outputs/4.html"))
            #expect(try await bool(web, "document.querySelectorAll('a.repo').length===5 && !document.querySelector('iframe') && document.body.innerText.includes('正文继续显示') && document.body.innerText.includes('at most four HTML files') && !document.body.innerText.includes('Loading HTML preview')"))
            #expect(renderer.error == nil)
        }

        @Test
        func removedHTMLFileCannotInstallLatePreview() async throws {
            _ = NSApplication.shared
            let renderer = RichChatRenderer(), id = UUID()
            var pending: CheckedContinuation<Data, Never>?
            renderer.htmlLoader = { _, _ in await withCheckedContinuation { pending = $0 } }
            renderer.update(messages: [.init(id: id, text: "Old file", answer: "`<repo:old.html>`")], title: "Orbie", dark: false)
            renderer.start()
            let web = try #require(renderer.webView), window = mount(web)
            defer { renderer.stop()
                window.close()
            }
            try await wait(web, "document.body.innerText.includes('Loading HTML preview')")
            for _ in 0..<50 where pending == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let continuation = try #require(pending)
            renderer.update(messages: [.init(id: id, text: "New reply", answer: "当前回复无需网页预览。")], title: "Orbie", dark: false)
            try await wait(web, "document.body.innerText.includes('当前回复无需网页预览')")
            continuation.resume(returning: Data("<button>Stale HTML</button>".utf8))
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await bool(web, "!document.querySelector('iframe') && !document.querySelector('.card') && !document.body.innerText.includes('Stale HTML')"))
        }

        @Test
        func HTMLSourceRejectsInvalidEncodingAndSize() throws {
            for bytes in [Data(), Data([0xFF]), Data([0]), Data(repeating: 65, count: 512 * 1_024 + 1)] {
                #expect(throws: CocoaError.self) { try RichChatRenderer.htmlSource(bytes) }
            }
            #expect(try RichChatRenderer.htmlSource(Data("<h1>HTML</h1>".utf8)) == "<h1>HTML</h1>")
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
                paths.append(target)
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
            #expect(paths == ["images/图.svg"])
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
            #expect(Set(paths) == ["a(draft).png", "images/图 片.png", "images/plot.png"])
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

//
//  ExamplesTests.swift
//  ExamplesTests
//
//  Created by Sondra on 2026/3/23.
//

import Foundation
import Testing
@testable import Examples

@MainActor
struct ExamplesTests {

    @Test func decodesGiftEffectsFromJSON() throws {
        let data = """
        [
          {
            "name": "萌萌花束",
            "url": "https://qiniu-xbyy.yinyou.live/channel/gift/AMZZpp-1778586158262.svga"
          },
          {
            "name": "欢乐节拍",
            "url": "https://ymres.yinyou.live/channel/gift/Zy76Wn-1679971764876.svga"
          }
        ]
        """.data(using: .utf8)!

        let effects = try GiftEffectsDataSource.decode(data)

        #expect(effects.count == 2)
        #expect(effects[0].name == "萌萌花束")
        #expect(effects[0].sourceLabel == "qiniu")
        #expect(effects[1].sourceLabel == "ymres")
    }

    @Test func filtersGiftEffectsByNameAndSource() {
        let effects = [
            GiftEffect(name: "萌萌花束", url: URL(string: "https://qiniu-xbyy.yinyou.live/a.svga")!),
            GiftEffect(name: "欢乐节拍", url: URL(string: "https://ymres.yinyou.live/b.svga")!)
        ]

        #expect(GiftEffectsDataSource.filter(effects, query: "花束").map(\.name) == ["萌萌花束"])
        #expect(GiftEffectsDataSource.filter(effects, query: "ymres").map(\.name) == ["欢乐节拍"])
        #expect(GiftEffectsDataSource.filter(effects, query: "  ").count == 2)
    }

    @Test func formatsDownloadProgressAsPercentText() {
        #expect(DownloadProgressFormatter.percentText(for: -0.2) == "0%")
        #expect(DownloadProgressFormatter.percentText(for: 0.427) == "43%")
        #expect(DownloadProgressFormatter.percentText(for: 1.4) == "100%")
    }
}

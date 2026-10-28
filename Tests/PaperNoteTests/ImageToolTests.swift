import XCTest
@testable import PaperNote

/// 回報的需求：插入圖片要有自己的工具，照片列出來點一下就加入；常常要連續把不同照片加到不同頁
final class ImageToolTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
    }

    private final class FakeTap: UITapGestureRecognizer {
        let point: CGPoint
        init(_ p: CGPoint) {
            point = p
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "ImageToolTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<2 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
        session.save()
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func photo(_ color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: fmt).image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
    }

    private func images(onPage i: Int) -> [PageElement] {
        editor.pages[i].elements.filter { if case .image = $0.content { return true }; return false }
    }

    func testImageToolIsOnTheToolbarAndShowsThePhotoStrip() {
        XCTAssertNotNil(editor.toolButtons[.image], "插入圖片要有自己的工具")
        editor.setTool(.image)
        XCTAssertFalse(editor.photoStrip.isHidden, "圖片工具要列出照片")
        editor.setTool(.pen)
        XCTAssertTrue(editor.photoStrip.isHidden)
    }

    func testPickingPhotosKeepsTheToolAndAddsToTheCurrentPage() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        XCTAssertEqual(images(onPage: 0).count, 1, "點一下照片就放到目前這頁")
        XCTAssertEqual(editor.tool, .image, "加完還在圖片工具，可以接著加")
        editor.insertPhotoFromStrip(photo(.blue))
        let two = images(onPage: 0)
        XCTAssertEqual(two.count, 2)
        XCTAssertNotEqual(two[0].frame.origin, two[1].frame.origin, "同一頁連續加的照片不能完全疊在一起")

        // 捲到第 2 頁再加
        let r = editor.pagesContainer.convert(editor.pageFrames[1], to: editor.canvas)
        editor.canvas.contentOffset.y = r.minY
        editor.canvas.layoutIfNeeded()
        XCTAssertEqual(editor.currentPageIndex, 1)
        editor.insertPhotoFromStrip(photo(.green))
        XCTAssertEqual(images(onPage: 1).count, 1, "捲到別頁加的照片要放在那一頁")
        XCTAssertEqual(images(onPage: 0).count, 2)
    }

    /// 回報的需求：圖片模式下也可以移動圖片
    func testImagesCanBeMovedInTheImageTool() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        let ref = try XCTUnwrap(editor.selected, "剛加的照片要先選起來")
        let start = try XCTUnwrap(images(onPage: 0).first).frame
        let o = editor.contentOrigin(0)
        let grab = CGPoint(x: start.midX + o.x, y: start.midY + o.y)
        XCTAssertNotNil(editor.dragTarget(at: grab), "按在圖片上要能拖")
        let g = FakePan(target: nil, action: nil)
        for (i, d) in [CGFloat(0), 20, 40].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, CGPoint(x: grab.x + d, y: grab.y + d))
        }
        guard case let (pi, ei)? = editor.locate(ref) else { return XCTFail("圖片不見了") }
        let moved = editor.pages[pi].elements[ei].frame
        XCTAssertEqual(moved.minX, start.minX + 40, accuracy: 0.5)
        XCTAssertEqual(moved.minY, start.minY + 40, accuracy: 0.5)
        XCTAssertEqual(editor.tool, .image, "還在圖片工具")
    }

    func testTappingAnImageInTheImageToolSelectsIt() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        let f = try XCTUnwrap(images(onPage: 0).first).frame
        let o = editor.contentOrigin(0)
        editor.handleTap(FakeTap(CGPoint(x: o.x + f.maxX + 200, y: o.y + f.maxY + 200)))
        XCTAssertNil(editor.selected, "點空白處取消選取")
        editor.handleTap(FakeTap(CGPoint(x: o.x + f.midX, y: o.y + f.midY)))
        XCTAssertNotNil(editor.selected, "點圖片選起來")
        XCTAssertEqual(editor.tool, .image)
    }

    /// 回報的需求：圖片長按要有「剪下」
    func testImageMenuHasCut() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        let ref = try XCTUnwrap(editor.selected)
        XCTAssertTrue(editor.longPressGesture.isEnabled, "圖片工具也可以長按打開選單")
        let titles = editor.elementMenu(ref, at: .zero).children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.map(\.title)
        XCTAssertTrue(titles.contains("剪下"))
        editor.cutElement(ref)
        XCTAssertTrue(images(onPage: 0).isEmpty, "剪下之後圖片不在頁面上")
        XCTAssertNotNil(editor.clipboardElement, "剪下的圖片可以貼上")
    }

    /// 回報的需求：圖片左上角、鎖頭旁邊多一個紅色叉叉
    func testRedCrossNextToTheLockDeletesTheImage() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        let ref = try XCTUnwrap(editor.selected)
        let lock = try XCTUnwrap(editor.lockIconTargets().first { $0.ref == ref })
        let cross = try XCTUnwrap(editor.imageDeleteTarget(), "選到的圖片要有紅色叉叉")
        XCTAssertEqual(cross.point.y, lock.point.y, accuracy: 0.5, "和鎖頭同一排")
        XCTAssertGreaterThan(cross.point.x, lock.point.x, "在鎖頭右邊")
        editor.handleTap(FakeTap(cross.point))
        XCTAssertTrue(images(onPage: 0).isEmpty, "點紅色叉叉刪除圖片")
        XCTAssertNil(editor.imageDeleteTarget())
    }

    func testLockedImageHasNoRedCross() throws {
        editor.setTool(.image)
        editor.insertPhotoFromStrip(photo(.red))
        let ref = try XCTUnwrap(editor.selected)
        editor.toggleLock(ref)
        editor.select(ref)
        XCTAssertNil(editor.imageDeleteTarget(), "鎖定的圖片不顯示叉叉，免得誤刪")
    }

    func testInsertMenuHasNoPaste() {
        let titles = editor.makeInsertMenu().children.map(\.title)
        XCTAssertFalse(titles.contains("貼上"), "長按畫面就能貼上，＋選單裡不放")
    }
}

import SwiftUI
import UIKit

struct PhotoPager: UIViewControllerRepresentable {
    let photos: [PhonePhoto]
    @Binding var selectedID: UUID
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                        options: [.interPageSpacing: 16])
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator; pager.delegate = context.coordinator
        context.coordinator.pager = pager
        if let page = context.coordinator.page(selectedID) { pager.setViewControllers([page], direction: .forward, animated: false) }
        return pager
    }
    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard !coordinator.transitioning,
              let old = pager.viewControllers?.first as? PhotoPageController,
              old.id != selectedID, let next = coordinator.page(selectedID) else { return }
        old.resetZoom(); coordinator.pagingEnabled(true)
        let direction: UIPageViewController.NavigationDirection = coordinator.index(selectedID) > coordinator.index(old.id) ? .forward : .reverse
        coordinator.transitioning = true
        pager.setViewControllers([next], direction: direction, animated: true) { [weak coordinator] _ in
            coordinator?.transitioning = false; coordinator?.trimCache()
        }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        weak var pager: UIPageViewController?
        var transitioning = false
        private var cache: [UUID: PhotoPageController] = [:]
        init(_ parent: PhotoPager) { self.parent = parent }
        func index(_ id: UUID) -> Int { parent.photos.firstIndex(where: { $0.id == id }) ?? 0 }
        func page(_ id: UUID) -> PhotoPageController? {
            if let cached = cache[id] { return cached }
            guard let photo = parent.photos.first(where: { $0.id == id }) else { return nil }
            let page = PhotoPageController(id: id, url: photo.url)
            page.zoomChanged = { [weak self] zoomed in
                guard let self, (self.pager?.viewControllers?.first as? PhotoPageController)?.id == id else { return }
                self.pagingEnabled(!zoomed)
            }
            cache[id] = page; return page
        }
        func pagingEnabled(_ enabled: Bool) {
            pager?.view.subviews.compactMap { $0 as? UIScrollView }.forEach { $0.isScrollEnabled = enabled }
        }
        func trimCache() {
            let position = index(parent.selectedID)
            let keep = Set(parent.photos.enumerated().filter { abs($0.offset - position) <= 1 }.map { $0.element.id })
            cache = cache.filter { keep.contains($0.key) }
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PhotoPageController else { return nil }
            let position = index(current.id); return position > 0 ? page(parent.photos[position - 1].id) : nil
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PhotoPageController else { return nil }
            let position = index(current.id); return position + 1 < parent.photos.count ? page(parent.photos[position + 1].id) : nil
        }
        func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let visible = controller.viewControllers?.first as? PhotoPageController {
                previousViewControllers.compactMap { $0 as? PhotoPageController }.forEach { $0.resetZoom() }
                parent.selectedID = visible.id
                pagingEnabled(true); trimCache()
            }
        }
    }
}
final class PhotoPageController: UIViewController {
    let id: UUID
    let url: URL
    var zoomChanged: ((Bool) -> Void)?
    init(id: UUID, url: URL) { self.id = id; self.url = url; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let image = PhotoScrollView()
        image.setPhoto(url)
        image.zoomChanged = { [weak self] in self?.zoomChanged?($0) }
        view = image
    }
    func resetZoom() {
        guard let image = viewIfLoaded as? PhotoScrollView else { return }
        image.setZoomScale(1, animated: false)
    }
}

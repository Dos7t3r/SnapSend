import SwiftUI
import UIKit
import AVFoundation
import AVKit

final class CameraCapture: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum State: Equatable { case preparing, ready, denied, unavailable, interrupted, failed(String) }
    #if targetEnvironment(simulator)
    @Published private(set) var state: State = .unavailable
    #else
    @Published private(set) var state: State = .preparing
    #endif
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomPresets: [CGFloat] = [1]
    private var wideFactor: CGFloat = 1
    @Published private(set) var pending = 0
    @Published private(set) var captureReady = false
    private var readiness: NSKeyValueObservation?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.snapsend.camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var desired = false
    private var shots: [Int64: (Data) -> Void] = [:]
    private var observers: [NSObjectProtocol] = []
    override init() {
        super.init()
        readiness = output.observe(\.captureReadiness, options: [.initial, .new]) { [weak self] output, _ in
            let ready = output.captureReadiness == .ready
            DispatchQueue.main.async { self?.captureReady = ready }
        }
        #if !targetEnvironment(simulator)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in self?.publish(.interrupted) })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in self?.resume() })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset { self?.resume() }
            else { self?.publish(.failed(error?.localizedDescription ?? "相机暂时不可用")) }
        })
        #endif
    }
    #if DEBUG || targetEnvironment(simulator)
    func configurePreview(presets: [CGFloat]) { zoomPresets = presets }
    #endif
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func publish(_ state: State) { DispatchQueue.main.async { self.state = state } }
    func setActive(_ active: Bool) {
        queue.async {
            self.desired = active
            guard active else { if self.session.isRunning { self.session.stopRunning() };
                #if targetEnvironment(simulator)
                self.publish(.unavailable)
                #else
                self.publish(.preparing)
                #endif
                return }
            #if targetEnvironment(simulator)
            self.publish(.unavailable)
            #else
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndRun()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in self.queue.async { if granted && self.desired { self.configureAndRun() } else if !granted { self.publish(.denied) } } }
            default: self.publish(.denied)
            }
            #endif
        }
    }
    private func resume() { queue.async { if self.desired { self.configureAndRun() } } }
    private func configureAndRun() {
        guard desired else { return }
        do {
            if !configured {
                let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
                guard let camera = types.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first else { publish(.unavailable); return }
                if let wideIndex = camera.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), wideIndex > 0 {
                    wideFactor = camera.virtualDeviceSwitchOverVideoZoomFactors[wideIndex - 1].doubleValue
                }
                let minZoom = camera.minAvailableVideoZoomFactor / wideFactor
                let maxZoom = min(camera.maxAvailableVideoZoomFactor / wideFactor, 5)
                let presets: [CGFloat] = [0.5, 1, 2, 3].filter { $0 >= minZoom && $0 <= maxZoom }
                DispatchQueue.main.async { self.zoomPresets = presets }
                let input = try AVCaptureDeviceInput(device: camera)
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); publish(.unavailable); return }
                session.sessionPreset = .photo; session.addInput(input); session.addOutput(output)
                output.maxPhotoQualityPrioritization = .balanced
                if let dimension = camera.activeFormat.supportedMaxPhotoDimensions.filter({ Int64($0.width) * Int64($0.height) <= 12_500_000 && abs(Double($0.width) / Double($0.height) - 4.0 / 3.0) < 0.01 }).max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) { output.maxPhotoDimensions = dimension }
                if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
                session.commitConfiguration(); device = camera; configured = true
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                camera.isSubjectAreaChangeMonitoringEnabled = true; camera.unlockForConfiguration()
            }
            if !session.isRunning { applyZoom(1); session.startRunning() }
            publish(.ready)
        } catch { publish(.failed(error.localizedDescription)) }
    }
    func capture(flash: Bool, fast: Bool, angle: CGFloat, completion: @escaping (Data) -> Void) {
        queue.async {
            guard self.desired, self.session.isRunning, self.output.captureReadiness == .ready, self.shots.count < 2 else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = fast ? .speed : .balanced
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            if self.device?.hasFlash == true { settings.flashMode = flash ? .on : .off }
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            self.shots[settings.uniqueID] = completion
            DispatchQueue.main.async { self.pending += 1 }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            if let completion = self.shots.removeValue(forKey: photo.resolvedSettings.uniqueID) {
                if let error { self.publish(.failed(error.localizedDescription)) }
                else if let data = photo.fileDataRepresentation() { DispatchQueue.main.async { completion(data) } }
                else { self.publish(.failed("拍摄数据无法读取，请重试")) }
                DispatchQueue.main.async { self.pending = max(0, self.pending - 1) }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        queue.async {
            if self.shots.removeValue(forKey: resolvedSettings.uniqueID) != nil { DispatchQueue.main.async { self.pending = max(0, self.pending - 1) } }
            self.publish(.failed("拍摄被中断，请重试：" + error.localizedDescription))
        }
    }
    func focus(_ point: CGPoint) {
        queue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) { device.focusPointOfInterest = point; device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) { device.exposurePointOfInterest = point; device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            } catch { self.publish(.failed(error.localizedDescription)) }
        }
    }
    func setZoom(_ value: CGFloat) { queue.async { self.applyZoom(value) } }
    private func applyZoom(_ value: CGFloat) {
        guard let device else { return }
        let factor = min(max(value * wideFactor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 5 * wideFactor))
        do { try device.lockForConfiguration(); device.videoZoomFactor = factor; device.unlockForConfiguration(); DispatchQueue.main.async { self.zoom = factor / self.wideFactor } }
        catch { publish(.failed(error.localizedDescription)) }
    }

}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraCapture
    var volumeEnabled: Bool
    var shutter: () -> Void
    var focus: (CGPoint) -> Void
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface(); view.camera = camera
        #if !targetEnvironment(simulator)
        view.layerView.session = camera.session
        #endif
        view.focus = focus; view.shutter = shutter; view.updateVolume(volumeEnabled && camera.state == .ready && camera.captureReady && camera.pending < 2)
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {
        view.focus = focus; view.shutter = shutter; view.updateVolume(volumeEnabled && camera.state == .ready && camera.captureReady && camera.pending < 2)
    }
    final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        weak var camera: CameraCapture?
        var shutter: (() -> Void)?
        var focus: ((CGPoint) -> Void)?
        private var baseZoom: CGFloat = 1
        private var captureInteraction: UIInteraction?
        override init(frame: CGRect) {
            super.init(frame: frame); layerView.videoGravity = .resizeAspect
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            let angle = Self.angle(window?.windowScene?.interfaceOrientation ?? .portrait)
            if let c = layerView.connection, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
        static func angle(_ orientation: UIInterfaceOrientation) -> CGFloat {
            switch orientation { case .landscapeLeft: return 0; case .landscapeRight: return 180; case .portraitUpsideDown: return 270; default: return 90 }
        }
        @objc private func tapped(_ tap: UITapGestureRecognizer) {
            let point = tap.location(in: self); camera?.focus(layerView.captureDevicePointConverted(fromLayerPoint: point)); focus?(point)
        }
        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            if pinch.state == .began { baseZoom = camera?.zoom ?? 1 }
            camera?.setZoom(baseZoom * pinch.scale)
        }
        func updateVolume(_ enabled: Bool) {
            if #available(iOS 17.2, *) {
                if captureInteraction == nil && enabled {
                    let interaction = AVCaptureEventInteraction { [weak self] event in if event.phase == .ended { self?.shutter?() } }
                    addInteraction(interaction); captureInteraction = interaction
                }
                (captureInteraction as? AVCaptureEventInteraction)?.isEnabled = enabled
            }
        }
    }
}

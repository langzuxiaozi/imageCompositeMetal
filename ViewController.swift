//
//  ViewController.swift
//  imageCompositeMetal
//
//  Created by Yz on 2019/6/20.
//  Copyright © 2019 Yz. All rights reserved.
//

import UIKit
import AVFoundation
import os.signpost
import VideoToolbox
import Accelerate

var useMetal = false

class ViewController: UIViewController {

    let metalUtils = MetalUtils()
    var timer: YzSwiftTimer?
    var timer2: YzSwiftTimer?

    var _filterCount = 0
    fileprivate var _sampleBuffer: CMSampleBuffer? = nil
    //互斥锁
    fileprivate let _buffer_lock = NSLock()
    fileprivate let _buffer_lock2 = NSLock()
    
    fileprivate var _outputConnect :AVCaptureConnection?
    fileprivate lazy var cameraSession: AVCaptureSession = {
        let capture = AVCaptureSession()
        capture.sessionPreset = .medium
        return capture
    }()
    fileprivate let captureDevice: AVCaptureDevice? = {
        let devices = AVCaptureDevice.devices(for: AVMediaType.video)
        for device in devices {
            if device.position == AVCaptureDevice.Position.front {
                return device
            }
        }
        return nil
    }()

    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let preview =  AVCaptureVideoPreviewLayer(session: self.cameraSession)
        preview.videoGravity = AVLayerVideoGravity.resizeAspectFill
        return preview
    }()


    var mainTexture :MTLTexture?
    fileprivate lazy var _bgPixelBuffer: CVPixelBuffer? = nil
    fileprivate lazy var _outputBufferPool: CVPixelBufferPool? = nil



    fileprivate lazy var _bgImage: UIImage? = nil

    override func viewDidLoad() {

        print (ProcessInfo.processInfo.environment)

//        wolfLog = .disabled
//        signpost(pointOfInterset: ViewController.wolf)
        let name:StaticString = "viewDidLoad"
        os_signpost(.begin, log: wolfLog, name: name)
        defer {
            os_signpost(.end, log: wolfLog, name: name)
        }

        super.viewDidLoad()

        // 初始化摄像头
        configCapture()
        self.previewLayer.frame = CGRect.init(x: 100, y: 100, width: 200, height: 150)
        self.view.layer.addSublayer(self.previewLayer)

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)


        //用于屏幕截图
        let viewSize = UIScreen.main.bounds.size
        let sourcePixelBufferOptions: NSDictionary = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32ARGB,
                                                      kCVPixelBufferWidthKey: viewSize.width,
                                                      kCVPixelBufferHeightKey: viewSize.height,
                                                      kCVPixelFormatOpenGLESCompatibility: true,
                                                      kCVPixelBufferMetalCompatibilityKey:true,
                                                      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]

        CVPixelBufferPoolCreate(nil, nil, sourcePixelBufferOptions, &_outputBufferPool)
    }

    @IBAction func start(_ sender: Any) {
        if  !self.cameraSession.isRunning {
             self.cameraSession.startRunning()
        }
        //视频帧与屏幕合并100毫秒一次
        timer = YzSwiftTimer.repeaticTimer(interval: .milliseconds(100),queue: DispatchQueue.global(), handler: { [weak self](time) in
            self?._buffer_lock.lock()
            guard let sampleBuffer = self?._sampleBuffer ,let pix_buffer = CMSampleBufferGetImageBuffer(sampleBuffer)else{
                self?._buffer_lock.unlock()
                return
            }

            os_signpost(.begin, log: wolfLog, name: "mergeTexture")
            defer {
                os_signpost(.end, log: wolfLog, name: "mergeTexture")
            }

            var pixelBuffer:CVPixelBuffer?
            let p = CVPixelBufferGetPixelFormatType(pix_buffer)
            if useMetal {
            // 通过metal 来合成视频帧 begin
            if p == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange{
                guard let (y_Texture,uv_Texture) = self?.metalUtils.makeTextureFromYUVCVPixelBuffer(pixelBuffer: pix_buffer), let y_inputTexture = y_Texture,let uv_inputTexture = uv_Texture else {
                    self?._buffer_lock.unlock()
                    return
                }
                pixelBuffer = self?.mergeYuvTexture(y_inputTexture: y_inputTexture, uv_inputTexture: uv_inputTexture, region: float4(100,100,200,150))
                self?._buffer_lock.unlock()

            }else if p == kCVPixelFormatType_32BGRA{
                guard let texture = self?.metalUtils.makeTextureFromCVPixelBuffer(pixelBuffer: pix_buffer, textureFormat: .bgra8Unorm) else{
                    self?._buffer_lock.unlock()
                    return
                }
                pixelBuffer = self?.mergeBGRATexture(bgraTexture: texture, region: float4(100,100,200,150))
                self?._buffer_lock.unlock()

            }
            // 通过metal 来合成视频帧 end
            }else{
                let rect = CGRect(x: 100,y: 100,width: 200,height: 150)
                var dstImage = self?._bgImage
                if p == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange{


                    guard let cgImage = self?.yuv2argb(pixelBuffer: pix_buffer) else {
                        self?._buffer_lock.unlock()
                        return
                    }

                    guard let bufferTem = cgImage.transformToPixelBuffer() else {
                        self?._buffer_lock.unlock()
                        return
                    }
                    if let s_image = bufferTem.toImage()?.byResize(to: rect.size * 0.6) {
                        dstImage = dstImage?.overlayWith(image: s_image, posX: rect.origin.x * 0.6, posY: rect.origin.y * 0.6)
                        pixelBuffer = dstImage?.toCVPixelBuffer()
                    }

                }else if p == kCVPixelFormatType_32BGRA{
                    if let s_image = pix_buffer.toImage()?.byResize(to: rect.size * 0.6) {
                        dstImage = dstImage?.overlayWith(image: s_image, posX: rect.origin.x * 0.6, posY: rect.origin.y * 0.6)
                        pixelBuffer = dstImage?.toCVPixelBuffer()
                    }
                }
                self?._buffer_lock.unlock()
            }

            if let smb = pixelBuffer?.transformToCMSampleBuffer(){
                // smb:CMSampleBuffer? 是可以通过 腾讯的 TXLivePush 直播和录播
            }
        })
        //截取屏幕1秒一次
        timer2 = YzSwiftTimer.repeaticTimer(interval: .seconds(1), handler: { [weak self](time) in
            self?._buffer_lock2.lock()
            if useMetal {
                guard let bgPB = self?.captureScreenPixelBuffer(),let texture  =  self?.metalUtils.makeTextureFromCVPixelBuffer(pixelBuffer: bgPB,textureFormat:.rgba8Unorm)  else{
                    self?._buffer_lock2.unlock()
                    return
                }
                self?._bgPixelBuffer = bgPB

                self?.metalUtils.setThreadgroupsPerGrid(texture: texture)
                self?.mainTexture = texture

            }else{
                guard let bgPB = self?.captureScreenPixelBuffer() else{
                    self?._buffer_lock2.unlock()
                    return
                }
                self?._bgPixelBuffer = bgPB
                self?._bgImage = self?._bgPixelBuffer?.toImage()?.byResize(to: UIScreen.main.bounds.size * 0.6)
            }



            self?._buffer_lock2.unlock()
        })
        timer?.start()
        timer2?.start()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.cameraSession.stopRunning()
        timer = nil
        timer2 = nil
    }

    func mergeYuvTexture(y_inputTexture:MTLTexture,uv_inputTexture:MTLTexture,region:float4) -> CVPixelBuffer?{
        guard  let texture = mainTexture else {
            return nil
        }
        self.metalUtils.mergeYuvTextureToTexture(y_Texture: y_inputTexture, uv_Texture: uv_inputTexture, toTextue: texture, region:region )
        return self._bgPixelBuffer
    }

    func mergeBGRATexture(bgraTexture:MTLTexture,region:float4) -> CVPixelBuffer?{
        guard  let texture = mainTexture else {
            return nil
        }
        self.metalUtils.mergeBGRATextureToTexture(texture: bgraTexture, toTextue: texture, region: region)
        return self._bgPixelBuffer
    }

    func configCapture() {
        if captureDevice == nil {
            print("get font device failed!")
            return
        }
        do {
            let deviceInput = try AVCaptureDeviceInput(device: captureDevice!)
            let queue = DispatchQueue(label: "com.invasivecode.videoQueue", qos: DispatchQoS.background)
            cameraSession.beginConfiguration()

            if (cameraSession.canAddInput(deviceInput) == true) {
                cameraSession.addInput(deviceInput)
            }

            let dataOutput = AVCaptureVideoDataOutput()

            //kCVPixelFormatType_32BGRA 和 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange 都可以用
//            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as [String : Any] // 3
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as [String : Any] // 3

            dataOutput.alwaysDiscardsLateVideoFrames = true

            if (cameraSession.canAddOutput(dataOutput) == true) {
                cameraSession.addOutput(dataOutput)
            }

            _outputConnect = dataOutput.connection(with: AVMediaType.video)

            cameraSession.commitConfiguration()

            if _outputConnect?.isVideoMirroringSupported ?? false {
                _outputConnect?.isVideoMirrored = true
            }
            dataOutput.setSampleBufferDelegate(self, queue: queue)

            switch UIApplication.shared.statusBarOrientation {
            case .landscapeLeft:
                previewLayer.connection?.videoOrientation = .landscapeLeft
                _outputConnect?.videoOrientation = .landscapeLeft
            case .landscapeRight:
                previewLayer.connection?.videoOrientation = .landscapeRight
                _outputConnect?.videoOrientation = .landscapeRight
            default:
                previewLayer.connection?.videoOrientation = .landscapeLeft
                _outputConnect?.videoOrientation = .landscapeLeft
            }
        }
        catch let error as NSError {
            NSLog("\(error), \(error.localizedDescription)")
        }
    }

    //屏幕截图
    func captureScreenPixelBuffer() -> CVPixelBuffer?{
        let scale: CGFloat = 1.0
        let viewSize = UIScreen.main.bounds.size
        var pixelBuffer: CVPixelBuffer? = nil
        autoreleasepool {
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _outputBufferPool!, &pixelBuffer)
            guard status == kCVReturnSuccess, pixelBuffer != nil else {
                return
            }
            CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
            let data = CVPixelBufferGetBaseAddress(pixelBuffer!)
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
            let context = CGContext(data: data, width: Int(viewSize.width), height: Int(viewSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            context?.scaleBy(x: scale, y: scale)
            let flipVertical = CGAffineTransform.init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: viewSize.height)
            context?.concatenate(flipVertical)
            guard let bitmapContext = context else {
                print("context is null ...........")
                CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
                return
            }
            objc_sync_enter(self)
            UIGraphicsPushContext(bitmapContext)
            self.view.layer.render(in: bitmapContext)
            UIGraphicsPopContext()
            objc_sync_exit(self)
            CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        }
        return pixelBuffer
    }



    private func yuv2argb(pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        var cgImageFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent)

        var infoYpCbCrToARGB = vImage_YpCbCrToARGB()
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16,
                                                 CbCr_bias: 128,
                                                 YpRangeMax: 235,
                                                 CbCrRangeMax: 240,
                                                 YpMax: 235,
                                                 YpMin: 16,
                                                 CbCrMax: 240,
                                                 CbCrMin: 16)

        let error1 = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4!,
            &pixelRange,
            &infoYpCbCrToARGB,
            kvImage422CbYpCrYp8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags))
        var destinationBuffer = vImage_Buffer()
        let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        var sourceLumaBuffer = vImage_Buffer(data: lumaBaseAddress,
                                             height: vImagePixelCount(lumaHeight),
                                             width: vImagePixelCount(lumaWidth),
                                             rowBytes: lumaRowBytes)

        let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var sourceChromaBuffer = vImage_Buffer(data: chromaBaseAddress,
                                               height: vImagePixelCount(chromaHeight),
                                               width: vImagePixelCount(chromaWidth),
                                               rowBytes: chromaRowBytes)

        var error = kvImageNoError

        //        var scale_lumaBuffer = vImage_Buffer()
        //        error = vImageBuffer_Init(&scale_lumaBuffer, vImagePixelCount(_size.height), vImagePixelCount(_size.width), cgImageFormat.bitsPerPixel, vImage_Flags(kvImageNoFlags))
        //        guard error == kvImageNoError else {
        //            return nil
        //        }
        //
        //        var scale_chromaBuffer = vImage_Buffer()
        //        error = vImageBuffer_Init(&scale_chromaBuffer, vImagePixelCount(_size.height), vImagePixelCount(_size.width), cgImageFormat.bitsPerPixel, vImage_Flags(kvImageNoFlags))
        //        guard error == kvImageNoError else {
        //            return nil
        //        }
        //        error = vImageScale_Planar8(&sourceLumaBuffer, &scale_lumaBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        //        guard error == kvImageNoError else {
        //            return nil
        //        }
        //        error = vImageScale_Planar8(&sourceChromaBuffer, &scale_chromaBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        //        guard error == kvImageNoError else {
        //            return nil
        //        }

        if destinationBuffer.data == nil {
            error = vImageBuffer_Init(&destinationBuffer,
                                      sourceLumaBuffer.height,
                                      sourceLumaBuffer.width,
                                      cgImageFormat.bitsPerPixel,
                                      vImage_Flags(kvImageNoFlags))

            guard error == kvImageNoError else {
                return nil
            }
        }

        error = vImageConvert_420Yp8_CbCr8ToARGB8888(&sourceLumaBuffer,
                                                     &sourceChromaBuffer,
                                                     &destinationBuffer,
                                                     &infoYpCbCrToARGB,
                                                     nil,
                                                     255,
                                                     vImage_Flags(kvImagePrintDiagnosticsToConsole))

        guard error == kvImageNoError else {
            return nil
        }


        let cgImage = vImageCreateCGImageFromBuffer(
            &destinationBuffer,
            &cgImageFormat,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &error)
        destinationBuffer.data.deallocate()
        return cgImage?.takeRetainedValue()
        //        return nil
    }

}

extension ViewController:AVCaptureVideoDataOutputSampleBufferDelegate{

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){

        if ((output as? AVCaptureVideoDataOutput) != nil) {
            willOutputSampleBuffer(sampleBuffer)
        }
    }

    fileprivate func willOutputSampleBuffer(_ sampleBuffer: CMSampleBuffer){
        if _filterCount % 3 != 0 {
            _filterCount += 1
            return
        }
        _filterCount = 1

        if CMSampleBufferDataIsReady(sampleBuffer) {
            _buffer_lock.lock()
            _sampleBuffer = sampleBuffer
            _buffer_lock.unlock()
        }
    }
}

extension ViewController {
    @objc func didEnterBackground() {
        print("💕 didEnterBackground")
//        videoCacheManager.backgroundCleanDisk()
        self.cameraSession.stopRunning()
        timer = nil
        timer2 = nil
    }
}
extension CVPixelBuffer {

public func transformToCMSampleBuffer() -> CMSampleBuffer? {
    var info = CMSampleTimingInfo()
    info.presentationTimeStamp = .zero
    info.duration = .invalid
    info.decodeTimeStamp = .invalid

    var formatDesc: CMFormatDescription? = nil
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: self, formatDescriptionOut: &formatDesc)

    var sampleBuffer: CMSampleBuffer? = nil

    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                             imageBuffer: self,
                                             formatDescription: formatDesc!,
                                             sampleTiming: &info,
                                             sampleBufferOut: &sampleBuffer);
    return sampleBuffer
}

    public func toImage()->UIImage? {
        var cgImage: CGImage?
        if #available(iOS 9.0, *) {
            VTCreateCGImageFromCVPixelBuffer(self, options: nil, imageOut: &cgImage)
        } else {
            return nil
        }
        if let cgImage = cgImage {
            return UIImage.init(cgImage: cgImage)
        }
        return nil
    }
}

extension UIImage {
    func byResize(to size:CGSize) -> UIImage?{
        if (size.width <= 0 || size.height <= 0){
            return nil
        }
        UIGraphicsBeginImageContextWithOptions(size, false, self.scale)
        self.draw(in: CGRect(x: 0,y: 0,width: size.width,height: size.height))
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }

    func overlayWith(image: UIImage, posX: CGFloat, posY: CGFloat) -> UIImage? {
        let newWidth = posX < 0 ? abs(posX) + max(self.size.width, image.size.width) :
            size.width < posX + image.size.width ? posX + image.size.width : size.width
        let newHeight = posY < 0 ? abs(posY) + max(size.height, image.size.height) :
            size.height < posY + image.size.height ? posY + image.size.height : size.height
        let newSize = CGSize(width: newWidth, height: newHeight)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        let originalPoint = CGPoint(x: posX < 0 ? abs(posX) : 0, y: posY < 0 ? abs(posY) : 0)
        self.draw(in: CGRect(origin: originalPoint, size: self.size))
        let overLayPoint = CGPoint(x: posX < 0 ? 0 : posX, y: posY < 0 ? 0 : posY)
        image.draw(in: CGRect(origin: overLayPoint, size: image.size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage
    }

    func toCVPixelBuffer() -> CVPixelBuffer? {

        let width = self.size.width
        let height = self.size.height
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(width),
                                         Int(height),
                                         kCVPixelFormatType_32ARGB,
                                         attrs,
                                         &pixelBuffer)

        guard let resultPixelBuffer = pixelBuffer, status == kCVReturnSuccess else {
            return nil
        }

        CVPixelBufferLockBaseAddress(resultPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(resultPixelBuffer)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pixelData,
                                      width: Int(width),
                                      height: Int(height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(resultPixelBuffer),
                                      space: rgbColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                                        return nil
        }

        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1.0, y: -1.0)
        self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(resultPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        return resultPixelBuffer
    }

}

extension CGSize {
    static func * (left: CGSize, scale: CGFloat) -> CGSize {
        return CGSize.init(width: left.width * scale, height: left.height * scale)
    }
}

extension CGImage {
    public func transformToPixelBuffer() -> CVPixelBuffer? {
        //        guard let cgImage = self else {
        //            return nil
        //        }
        let cgImage = self

        let frameSize = CGSize(width: cgImage.width, height: cgImage.height)

        var pixelBuffer:CVPixelBuffer? = nil
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(frameSize.width), Int(frameSize.height), kCVPixelFormatType_32ARGB , nil, &pixelBuffer)

        if status != kCVReturnSuccess && pixelBuffer == nil {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags.init(rawValue: 0))
        let data = CVPixelBufferGetBaseAddress(pixelBuffer!)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        //        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let context = CGContext(data: data, width: Int(frameSize.width), height: Int(frameSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: bitmapInfo.rawValue)

        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))

        return pixelBuffer
    }
}

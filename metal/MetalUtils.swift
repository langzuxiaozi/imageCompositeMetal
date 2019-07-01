//
//  MetalUtils.swift
//  imageCompositeMetal
//
//  Created by Yz on 2019/6/21.
//  Copyright © 2019 Yz. All rights reserved.
//

import UIKit
import Foundation
//import CoreImage
import Metal
import simd
class MetalUtils: NSObject {

    var regionBuffer: MTLBuffer?
    var regionBuffer2:MTLBuffer?
    var queue: MTLCommandQueue?
    var cpsComputeNoStudent:MTLComputePipelineState?
    var cpsComputeAll:MTLComputePipelineState?
    var cpsNergeBgra:MTLComputePipelineState?
    var texture:MTLTexture?


    let metalDevice:  MTLDevice? =  MTLCreateSystemDefaultDevice()
    //    var metalDevice:  MTLDevice?
    struct REGIONS{
        var regionIjkVideo:float4
        var regionStudent:float4
    };

    var cpsThreadgroupsPerGrid:MTLSize!
    var computeNoStudentThreadsPerThreadgroup:MTLSize!
    var computeAllThreadsPerThreadgroup:MTLSize!
    var mergeBGRAThreadsPerThreadgroup:MTLSize!

    private lazy var textureCache: CVMetalTextureCache? = {
        guard let metalDevice = metalDevice else{
            return nil
        }
        var metalTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
            assertionFailure("Unable to allocate texture cache")
        }
        return metalTextureCache
    }()

    override init() {
        super.init()
        registerMetalFunction()
    }

    func setThreadgroupsPerGrid(texture:MTLTexture){
        let width = texture.width
        let height = texture.height
        let w = self.computeAllThreadsPerThreadgroup.width
        let h = self.computeAllThreadsPerThreadgroup.height
        if w == 0 || h == 0{
            self.cpsThreadgroupsPerGrid = MTLSize(width: width,
                                                  height: height,
                                                  depth: 1)
        }else{
            self.cpsThreadgroupsPerGrid = MTLSize(width: (width + w - 1) / w,
                                                  height: (height + h - 1) / h,
                                                  depth: 1)
        }
    }

    func registerMetalFunction() {
        queue = metalDevice?.makeCommandQueue()
        do {
            let library = metalDevice?.makeDefaultLibrary()
            if let computeNoStudent = library?.makeFunction(name: "computeNoStudent"),let cps = try metalDevice?.makeComputePipelineState(function: computeNoStudent){
                self.cpsComputeNoStudent = cps
                let w = cps.threadExecutionWidth
                let h = cps.maxTotalThreadsPerThreadgroup / w
                computeNoStudentThreadsPerThreadgroup = MTLSizeMake(w, h, 1)
            }

            if let computeAll = library?.makeFunction(name: "computeAll"),let cps = try metalDevice?.makeComputePipelineState(function: computeAll){
                self.cpsComputeAll = cps
                let w = cps.threadExecutionWidth
                let h = cps.maxTotalThreadsPerThreadgroup / w
                computeAllThreadsPerThreadgroup = MTLSizeMake(w, h, 1)
            }

            if let mergeBgra = library?.makeFunction(name: "mergeBgra"),let cps = try metalDevice?.makeComputePipelineState(function: mergeBgra){
                self.cpsNergeBgra = cps
                let w = cps.threadExecutionWidth
                let h = cps.maxTotalThreadsPerThreadgroup / w
                mergeBGRAThreadsPerThreadgroup = MTLSizeMake(w, h, 1)
            }

        } catch _ {
            //            Swift.print("\(e)")
        }
        regionBuffer = metalDevice?.makeBuffer(length: MemoryLayout<float4>.size , options: [])
        regionBuffer2 = metalDevice?.makeBuffer(length: MemoryLayout<REGIONS>.size , options: .cpuCacheModeWriteCombined)
    }

    func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
        guard let textureCache = textureCache else{
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create a Metal texture from the image buffer
        var cvTextureOut: CVMetalTexture?
        let _ = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)

        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return nil
        }

        return texture
    }
    func makeTextureFromYUVCVPixelBuffer(pixelBuffer: CVPixelBuffer)-> (MTLTexture?,MTLTexture?) {

        guard let textureCache = textureCache else{
            return (nil,nil)
        }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)


        var y_textureOut: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .r8Unorm, lumaWidth, lumaHeight, 0, &y_textureOut)
        if result != kCVReturnSuccess{
            return (nil,nil)
        }
        guard let y_texture = y_textureOut, let y_inputTexture = CVMetalTextureGetTexture(y_texture) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return (nil,nil)
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var uv_textureOut: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .rg8Unorm, chromaWidth, chromaHeight,1, &uv_textureOut)
        if result != kCVReturnSuccess{
            return (nil,nil)
        }
        guard let uv_texture = uv_textureOut, let uv_inputTexture = CVMetalTextureGetTexture(uv_texture) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return (nil,nil)
        }
        return (y_inputTexture ,uv_inputTexture)
    }

    func mergeAllCVPixelBuffer(pixelBuffer: CVPixelBuffer,region:float4,studentPB:CVPixelBuffer,regionStudent:float4){

        guard let cps = cpsComputeAll else{
            return
        }
        let (y_Texture,uv_Texture) = makeTextureFromYUVCVPixelBuffer(pixelBuffer: pixelBuffer)
        guard let y_inputTexture = y_Texture,let uv_inputTexture = uv_Texture else {
            return
        }

        let texture_student =  makeTextureFromCVPixelBuffer(pixelBuffer: studentPB,textureFormat:.bgra8Unorm)

        //        var convertMatrix = float3x3(float3(1.164, 1.164, 1.164),
        //                                     float3(0, -0.231, 2.112),
        //                                     float3(1.793, -0.533, 0))
        if let commandBuffer = queue?.makeCommandBuffer(),let commandEncoder = commandBuffer.makeComputeCommandEncoder(),let bp = regionBuffer2?.contents(){
            //            if let commandBuffer = queue?.makeCommandBuffer(),let commandEncoder = commandBuffer.makeComputeCommandEncoder(), let bufferPointer = regionBuffer?.contents(),let bp = regionBuffer2?.contents(){
            commandEncoder.setComputePipelineState(cps)
            commandEncoder.setTexture(self.texture,index: 0)
            commandEncoder.setTexture(y_inputTexture, index: 1)
            commandEncoder.setTexture(uv_inputTexture,index: 2)
            commandEncoder.setTexture(texture_student,index: 3)
            //            commandEncoder.setBytes(&convertMatrix, length: MemoryLayout<float3x3>.size, index: 0)
            //            if #available(iOS 8.3, *) {
            //                commandEncoder.setBytes(&convertMatrix, length: MemoryLayout<float3x3>.size, index: 0)
            //            } else {
            //                // Fallback on earlier versions
            //            }
            //            var r = region
            //            memcpy(bufferPointer, &r,  MemoryLayout<float4>.size)
            //            commandEncoder.setBuffer(regionBuffer, offset: 0, index: 1)
            //            var r2 = regionStudent
            //            memcpy(bp, &r2,  MemoryLayout<float4>.size)
            //            commandEncoder.setBuffer(regionBuffer2, offset: 0, index: 2)

            var regions = REGIONS.init(regionIjkVideo: region, regionStudent: regionStudent)
            memcpy(bp, &regions,  MemoryLayout<REGIONS>.size)
            commandEncoder.setBuffer(regionBuffer2, offset: 0, index: 1)


            commandEncoder.dispatchThreadgroups(cpsThreadgroupsPerGrid, threadsPerThreadgroup: computeAllThreadsPerThreadgroup)
            commandEncoder.endEncoding()
            //            commandBuffer.present(drawable)
            commandBuffer.commit()
        }


    }

    func mergeYuvTextureToTexture(y_Texture:MTLTexture,uv_Texture:MTLTexture,toTextue:MTLTexture,region:float4){
        guard let cps = cpsComputeNoStudent else{
            return
        }
        //        var convertMatrix = float3x3(float3(1.164, 1.164, 1.164),
        //                                     float3(0, -0.231, 2.112),
        //                                     float3(1.793, -0.533, 0))
        if let commandBuffer = queue?.makeCommandBuffer(),let commandEncoder = commandBuffer.makeComputeCommandEncoder(), let bufferPointer = regionBuffer?.contents(){
            commandEncoder.setComputePipelineState(cps)
            commandEncoder.setTexture(toTextue,index: 0)
            commandEncoder.setTexture(y_Texture, index: 1)
            commandEncoder.setTexture(uv_Texture,index: 2)
            //            if #available(iOS 8.3, *) {
            //                commandEncoder.setBytes(&convertMatrix, length: MemoryLayout<float3x3>.size, index: 0)
            //            } else {
            //                // Fallback on earlier versions
            //            }
            var r = region
            memcpy(bufferPointer, &r,  MemoryLayout<float4>.size)
            commandEncoder.setBuffer(regionBuffer, offset: 0, index: 0)

            commandEncoder.dispatchThreadgroups(cpsThreadgroupsPerGrid, threadsPerThreadgroup: computeNoStudentThreadsPerThreadgroup)
            commandEncoder.endEncoding()
            //            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

    }
    func mergeBGRATextureToTexture(texture:MTLTexture,toTextue:MTLTexture,region:float4)
    {
        guard let cps = cpsNergeBgra else{
            return
        }

        if let commandBuffer = queue?.makeCommandBuffer(),let commandEncoder = commandBuffer.makeComputeCommandEncoder(), let bufferPointer = regionBuffer?.contents(){
            commandEncoder.setComputePipelineState(cps)
            commandEncoder.setTexture(toTextue,index: 0)
            commandEncoder.setTexture(texture, index: 1)
            var r = region
            memcpy(bufferPointer, &r,  MemoryLayout<float4>.size)
            commandEncoder.setBuffer(regionBuffer, offset: 0, index: 0)

            commandEncoder.dispatchThreadgroups(cpsThreadgroupsPerGrid, threadsPerThreadgroup: mergeBGRAThreadsPerThreadgroup)
            commandEncoder.endEncoding()
            //            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

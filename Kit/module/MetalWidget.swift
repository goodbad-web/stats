//
//  MetalWidget.swift
//  Kit
//
//  Created by Antigravity on 08/05/2026.
//

import Metal
import QuartzCore
import Cocoa
import simd

/// Metalデバイスの管理と低電力GPUの優先選択
internal class MetalDeviceManager {
    static let shared = MetalDeviceManager()
    
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    var pipelineState: MTLRenderPipelineState?
    
    private init() {
        let devices = MTLCopyAllDevices()
        self.device = devices.first { $0.isLowPower } ?? MTLCreateSystemDefaultDevice()
        self.commandQueue = self.device?.makeCommandQueue()
        
        if let device = self.device, let library = device.makeDefaultLibrary() {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "widget_vertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "widget_fragment")
            
            if pipelineDescriptor.vertexFunction != nil && pipelineDescriptor.fragmentFunction != nil {
                pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
                pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
                pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                
                self.pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            }
        }
    }
}

/// CAMetalLayerを直接制御するウィジェット用のView基盤
internal class MetalWidgetView: NSView {
    let metalLayer = CAMetalLayer()
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupLayer()
    }
    
    private func setupLayer() {
        self.wantsLayer = true
        self.layer = metalLayer
        
        metalLayer.device = MetalDeviceManager.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer.drawableSize = CGSize(
            width: newSize.width * metalLayer.contentsScale,
            height: newSize.height * metalLayer.contentsScale
        )
    }
    
    func render() {
        guard MetalDeviceManager.shared.pipelineState != nil,
              MetalDeviceManager.shared.device != nil,
              let commandQueue = MetalDeviceManager.shared.commandQueue,
              let drawable = metalLayer.nextDrawable() else {
            return
        }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        self.draw(in: renderEncoder)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func draw(in encoder: MTLRenderCommandEncoder) {}
}

struct MetalVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

internal class LineChartMetalView: MetalWidgetView {
    private var vertices: [MetalVertex] = []
    private var vertexBuffer: MTLBuffer?
    
    func update(points: [Double], color: NSColor, fixedScale: Double) {
        guard !points.isEmpty else { return }
        
        let domainMax = Float(max(fixedScale, points.max() ?? 0))
        guard domainMax > 0 else { return }
        
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else { return }
        let r = Float(rgbColor.redComponent)
        let g = Float(rgbColor.greenComponent)
        let b = Float(rgbColor.blueComponent)
        let a = Float(rgbColor.alphaComponent)
        let metalColor = SIMD4<Float>(r, g, b, a)
        
        var newVertices: [MetalVertex] = []
        let count = points.count
        for (i, val) in points.enumerated() {
            // Normalize to [-1, 1] range for Metal NDC
            let x = (Float(i) / Float(count - 1)) * 2.0 - 1.0
            let y = (Float(val) / domainMax) * 2.0 - 1.0
            newVertices.append(MetalVertex(position: SIMD2<Float>(x, y), color: metalColor))
        }
        
        self.vertices = newVertices
        if let device = MetalDeviceManager.shared.device {
            self.vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<MetalVertex>.stride, options: [])
        }
        
        self.render()
    }
    
    override func draw(in encoder: MTLRenderCommandEncoder) {
        guard let pipelineState = MetalDeviceManager.shared.pipelineState,
              let vertexBuffer = self.vertexBuffer,
              !vertices.isEmpty else {
            return
        }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: vertices.count)
    }
}

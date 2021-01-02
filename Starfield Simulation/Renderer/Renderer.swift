//
//  Renderer.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

import Foundation
import Metal
import MetalKit
import ARKit
import simd

protocol RenderDestinationProvider {
    var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
    var currentDrawable: CAMetalDrawable? { get }
    var colorPixelFormat: MTLPixelFormat { get set }
    var depthStencilPixelFormat: MTLPixelFormat { get set }
    var sampleCount: Int { get set }
}

// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 1

// The 16 byte aligned size of our uniform structures
let kAlignedSharedUniformsSize: Int = (MemoryLayout<SharedUniforms>.size & ~0xFF) + 0x100

// Vertex data for an image plane
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
]

// The point size (in pixels) of rendered bodies
let bodyPointSize = 15;

// Size of gaussian map to create rounded smooth points
let gaussianMapSize = 64;

class Renderer {
    let session: ARSession
    let device: MTLDevice
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    var renderDestination: RenderDestinationProvider
    
    // Metal objects
    var commandQueue: MTLCommandQueue!
    var sharedUniformBuffer: MTLBuffer!
    var anchorUniformBuffer: MTLBuffer!
    var imagePlaneVertexBuffer: MTLBuffer!
    var capturedImagePipelineState: MTLRenderPipelineState!
    var capturedImageDepthState: MTLDepthStencilState!
    var capturedImageTextureY: CVMetalTexture?
    var capturedImageTextureCbCr: CVMetalTexture?
    var starPipelineState: MTLRenderPipelineState!
    var starDepthState:    MTLDepthStencilState!
    var interactivePipelineState: MTLRenderPipelineState!
    var interactiveDepthState: MTLDepthStencilState!
    var gaussianMap: MTLTexture!
    var _colors: MTLBuffer!
    var _interpolation: MTLBuffer!
    let maxInteractiveVertices = 1024
    var interactiveVertexBuffer: MTLBuffer!
    var currentBufferIndex: Int = 0
    var _renderScale: Float = 1
    var dayLightMode: Float = 0.5
    var laserPointer: Bool = true

    
    // Captured image texture cache
    var capturedImageTextureCache: CVMetalTextureCache!
    
    // Metal vertex descriptor specifying how vertices will by laid out for input into our
    //   anchor geometry render pipeline and how we'll layout our Model IO vertices
    var geometryVertexDescriptor: MTLVertexDescriptor!
    
    var uniformBufferIndex: Int = 0
    
    // Offset within _sharedUniformBuffer to set for the current frame
    var sharedUniformBufferOffset: Int = 0

    // Addresses to write shared uniforms to each frame
    var sharedUniformBufferAddress: UnsafeMutableRawPointer!

    // The current viewport size
    var viewportSize: CGSize = CGSize()
    
    // Flag for viewport size changes
    var viewportSizeDidChange: Bool = false
    
    // starting starsize
    var starSize: Float = 5
    
    var falseColour: Bool = false // if true / one galaxy is red, the other is blue
    var split: UInt = 0 // below = red, over will be blue
       
    init(session: ARSession, metalDevice device: MTLDevice, renderDestination: RenderDestinationProvider, numBodies: Int) {
        self.session = session
        self.device = device
        self.renderDestination = renderDestination
        loadMetal(numBodies: numBodies)
        generateGaussianMap()
    }
    
    func generateGaussianMap() {
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2D
        textureDescriptor.pixelFormat = .r8Unorm
        textureDescriptor.width = gaussianMapSize
        textureDescriptor.height = gaussianMapSize
        textureDescriptor.mipmapLevelCount = 1
        textureDescriptor.cpuCacheMode = .defaultCache
        textureDescriptor.usage = .shaderRead
        
        gaussianMap = device.makeTexture(descriptor: textureDescriptor)

        let nDelta = vector_float2 ( 2.0 / Float(textureDescriptor.width), 2.0 / Float(textureDescriptor.height ))

        var texel = [UInt8]()
        
        var SNormCoordinate = vector_float2 (-1.0, -1.0)
        var distance, t, color : Float
        
        for y in 0..<textureDescriptor.height {
            SNormCoordinate.y = -1.0 + Float(y) * nDelta.y
            
            for x in 0..<textureDescriptor.width {
                SNormCoordinate.x = -1.0 + Float(x) * nDelta.x
                
                distance = length(SNormCoordinate)
                t = (distance < 1.0) ? distance: 1.0
                
                color = (( 2.0 * t - 3.0) * t * t + 1.0)
                
                texel.append(UInt8(255 * color))
            }
        }
        
        
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: textureDescriptor.width, height: textureDescriptor.height, depth: 1))
        
        gaussianMap.replace(region: region, mipmapLevel: 0, withBytes: texel, bytesPerRow: MemoryLayout<UInt8>.size * textureDescriptor.width)
 
        gaussianMap.label = "Gaussian Map"
        

    }
    
    func setRenderScale(renderScale: Float)
    {
        _renderScale = renderScale
    }
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
        viewportSizeDidChange = true
    }

    func draw(positionsBuffer1: MTLBuffer, positionsBuffer2: MTLBuffer, interpolation: Float, numBodies: Int, inView: MTKView, finger: vector_float4)
    {
        // Wait to ensure only kMaxBuffersInFlight are getting processed by any stage in the Metal
        //   pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        // Create a new command buffer for each renderpass to the current drawable
        if let commandBuffer = commandQueue.makeCommandBuffer() {
            commandBuffer.label = "MyCommand"
            
            // Add completion handler which signal _inFlightSemaphore when Metal and the GPU has fully
            //   finished processing the commands we're encoding this frame.  This indicates when the
            //   dynamic buffers, that we're writing to this frame, will no longer be needed by Metal
            //   and the GPU.
            // Retain our CVMetalTextures for the duration of the rendering cycle. The MTLTextures
            //   we use from the CVMetalTextures are not valid unless their parent CVMetalTextures
            //   are retained. Since we may release our CVMetalTexture ivars during the rendering
            //   cycle, we must retain them separately here.
            var textures = [capturedImageTextureY, capturedImageTextureCbCr]
            commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.inFlightSemaphore.signal()
                }
                textures.removeAll()
            }
            
            updateBufferStates()
            updateGameState()
            
            if let renderPassDescriptor = renderDestination.currentRenderPassDescriptor, let currentDrawable = renderDestination.currentDrawable, let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                
                renderEncoder.label = "MyRenderEncoder"
                
                drawCapturedImage(renderEncoder: renderEncoder)
               
                drawStars(renderEncoder: renderEncoder, numBodies: numBodies, positionsBuffer1: positionsBuffer1, positionsBuffer2: positionsBuffer2, interpolation: interpolation)

                drawInteractive(renderEncoder: renderEncoder, numBodies: numBodies, positionsBuffer1: positionsBuffer1, positionsBuffer2: positionsBuffer2, interpolation: interpolation, finger: finger)

               
                // We're done encoding commands
                renderEncoder.endEncoding()
                
                // Schedule a present once the framebuffer is complete using the current drawable
                commandBuffer.present(currentDrawable)
            }
            
            // Finalize rendering here & push the command buffer to the GPU
            commandBuffer.commit()
        }
    }
    
    // MARK: - Private
    
    func loadMetal(numBodies: Int) {
        // Create and load our basic Metal state objects
        
        // Set the default formats needed to render
        renderDestination.depthStencilPixelFormat = .depth32Float_stencil8
        renderDestination.colorPixelFormat = .bgra8Unorm
        renderDestination.sampleCount = 1

        // Calculate our uniform buffer sizes. We allocate kMaxBuffersInFlight instances for uniform
        //   storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        //   buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        //   to another. Anchor uniforms should be specified with a max instance count for instancing.
        //   Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        //   argument in the constant address space of our shading functions.
        let sharedUniformBufferSize = kAlignedSharedUniformsSize * kMaxBuffersInFlight

        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        //   CPU can access the buffer
        sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize, options: .storageModeShared)
        sharedUniformBuffer.label = "SharedUniformBuffer"

        // Create a vertex buffer with our image plane vertex data.
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        imagePlaneVertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
        
        interactiveVertexBuffer = device.makeBuffer(length: maxInteractiveVertices *  MemoryLayout<InteractiveVertex>.size, options: [])
        interactiveVertexBuffer.label = "InteractiveVertexBuffer"
        
        // Load all the shader files with a metal file extension in the project
        let defaultLibrary = device.makeDefaultLibrary()!
        
        let capturedImageVertexFunction = defaultLibrary.makeFunction(name: "capturedImageVertexTransform")!
        let capturedImageFragmentFunction = defaultLibrary.makeFunction(name: "capturedImageFragmentShader")!
        
        // Create a vertex descriptor for our image plane vertex buffer
        let imagePlaneVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        imagePlaneVertexDescriptor.attributes[0].format = .float2
        imagePlaneVertexDescriptor.attributes[0].offset = 0
        imagePlaneVertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Texture coordinates.
        imagePlaneVertexDescriptor.attributes[1].format = .float2
        imagePlaneVertexDescriptor.attributes[1].offset = 8
        imagePlaneVertexDescriptor.attributes[1].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Buffer Layout
        imagePlaneVertexDescriptor.layouts[0].stride = 16
        imagePlaneVertexDescriptor.layouts[0].stepRate = 1
        imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Create a pipeline state for rendering the captured image
        let capturedImagePipelineStateDescriptor = MTLRenderPipelineDescriptor()
        capturedImagePipelineStateDescriptor.label = "MyCapturedImagePipeline"
        capturedImagePipelineStateDescriptor.sampleCount = renderDestination.sampleCount
        capturedImagePipelineStateDescriptor.vertexFunction = capturedImageVertexFunction
        capturedImagePipelineStateDescriptor.fragmentFunction = capturedImageFragmentFunction
        capturedImagePipelineStateDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
        capturedImagePipelineStateDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        capturedImagePipelineStateDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        capturedImagePipelineStateDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        
        do {
            try capturedImagePipelineState = device.makeRenderPipelineState(descriptor: capturedImagePipelineStateDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
        
        let capturedImageDepthStateDescriptor = MTLDepthStencilDescriptor()
        capturedImageDepthStateDescriptor.depthCompareFunction = .always
        capturedImageDepthStateDescriptor.isDepthWriteEnabled = false
        capturedImageDepthState = device.makeDepthStencilState(descriptor: capturedImageDepthStateDescriptor)
        
        // Create captured image texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capturedImageTextureCache = textureCache
        
        let starVertexFunction = defaultLibrary.makeFunction(name: "starVertexShader")!
        let starFragmentFunction = defaultLibrary.makeFunction(name: "starFragmentShader")!

        let starPipelineDescriptor = MTLRenderPipelineDescriptor()
        starPipelineDescriptor.label = "StarRenderPipeline"
        starPipelineDescriptor.sampleCount = renderDestination.sampleCount
        starPipelineDescriptor.vertexFunction = starVertexFunction
        starPipelineDescriptor.fragmentFunction = starFragmentFunction
        starPipelineDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        starPipelineDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        starPipelineDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        starPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true;
        starPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        starPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        starPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        starPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor  = .sourceAlpha
        starPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        starPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        
        do {
            try starPipelineState = device.makeRenderPipelineState(descriptor: starPipelineDescriptor)
        } catch let error {
            print("Failed to create star pipeline state, error \(error)")
        }
        
        let starDepthStateDescriptor = MTLDepthStencilDescriptor()
        starDepthStateDescriptor.depthCompareFunction = .always
        starDepthStateDescriptor.isDepthWriteEnabled = false
        starDepthState = device.makeDepthStencilState(descriptor: starDepthStateDescriptor)
        
        // Create the command queue
        
        setNumRenderBodies(numBodies: numBodies)
        
        // interactive stuff
        
        let interactiveVertexFunction = defaultLibrary.makeFunction(name: "interactiveVertexShader")
        let interactiveFragmentFunction = defaultLibrary.makeFunction(name: "interactiveFragmentShader")
        
        let interactivePipelineDescriptor = MTLRenderPipelineDescriptor()
        interactivePipelineDescriptor.label = "InteractivePipeline"
        interactivePipelineDescriptor.sampleCount = renderDestination.sampleCount
        interactivePipelineDescriptor.vertexFunction = interactiveVertexFunction
        interactivePipelineDescriptor.fragmentFunction = interactiveFragmentFunction
        interactivePipelineDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        interactivePipelineDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        interactivePipelineDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        // see for each of these whether necessary
        interactivePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true;
        interactivePipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        interactivePipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        interactivePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        interactivePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor  = .sourceAlpha
        interactivePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        interactivePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        
        do {
            try interactivePipelineState = device.makeRenderPipelineState(descriptor: interactivePipelineDescriptor)
        } catch let error {
            print("Failed to create interactive pipeline state, error \(error)")
        }
        
        let interactiveDepthStateDescriptor = MTLDepthStencilDescriptor()
        interactiveDepthStateDescriptor.depthCompareFunction = .always
        interactiveDepthStateDescriptor.isDepthWriteEnabled = false
        interactiveDepthState = device.makeDepthStencilState(descriptor: interactiveDepthStateDescriptor)
        
        commandQueue = device.makeCommandQueue()
        
        _interpolation = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func setNumRenderBodies(numBodies: Int) {
        if (_colors == nil || ((_colors.length / MemoryLayout<vector_uchar4>.size)) < numBodies) {
            // If the number of colors stored is less than the number of bodies, recreate the color buffer

            let bufferSize = numBodies * MemoryLayout<vector_uchar4>.size
            
            _colors = device.makeBuffer(length: bufferSize, options: .storageModeShared) // in MacOs this is Managed, maybe we need only gpu or something.
            _colors.label = "Colors"
            
            let colors = _colors.contents().assumingMemoryBound(to: vector_uchar4.self)
            
            var color : vector_float3
            
            for i in 0..<numBodies {
                color = generate_random_vector(min: 0, max: 1)

                colors[i].x = UInt8(255 * abs(color.x))
                colors[i].y = UInt8(255 * abs(color.y))
                colors[i].z = UInt8(255 * abs(color.z))
                colors[i].w = 255
                
            }
        }
    }

    func updateBufferStates() {
        // Update the location(s) to which we'll write to in our dynamically changing Metal buffers for
        //   the current frame (i.e. update our slot in the ring buffer used for the current frame)
        
        uniformBufferIndex = (uniformBufferIndex + 1) % kMaxBuffersInFlight
        
        sharedUniformBufferOffset = kAlignedSharedUniformsSize * uniformBufferIndex
        sharedUniformBufferAddress = sharedUniformBuffer.contents().advanced(by: sharedUniformBufferOffset)
    }
    
    func updateGameState() {
        // Update any game state
        
        guard let currentFrame = session.currentFrame else {
            return
        }
        
        
        updateSharedUniforms(frame: currentFrame)
        updateCapturedImageTextures(frame: currentFrame)
        
        if viewportSizeDidChange {
            viewportSizeDidChange = false
            
            updateImagePlane(frame: currentFrame)
        }
    }
    
    func updateSharedUniforms(frame: ARFrame) {
        // Update the shared uniforms of the frame
        
        let uniforms = sharedUniformBufferAddress.assumingMemoryBound(to: SharedUniforms.self)
        
        let cameraMatrix = arEnabled ? frame.camera.viewMatrix(for: .landscapeRight) : matrix_identity_float4x4
        let myScaleMatrix = scaleMatrix(scale: 1/_renderScale)
        let viewMatrix = cameraMatrix * trackingMatrix * myScaleMatrix
        let projectionMatrix = frame.camera.projectionMatrix(for: .landscapeRight, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
            
        uniforms.pointee.viewMatrix = viewMatrix
        uniforms.pointee.sharedMatrix = projectionMatrix * viewMatrix
       
        //let myvector = vector_float4(0,0,0,1)
        //let myvector2 = vector_float4(1,1,0,1)
        //let myvector3 = vector_float4(0,0,-1,1)
        //let myvector4 = vector_float4(1,1,-1,1)

        //print (projectionMatrix * myvector)
        //print (projectionMatrix * myvector2)
        //print (projectionMatrix * myvector3)
        //print (projectionMatrix * myvector4)

        
     //     uniforms.pointee.viewMatrix = frame.camera.viewMatrix(for: .landscapeRight)
       //     * scaleMatrix(scale: 1/_renderScale)

// not used        uniforms.pointee.projectionMatrix = frame.camera.projectionMatrix(for: .landscapeRight, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
        
        uniforms.pointee.starSize = starSize
    }

    func updateCapturedImageTextures(frame: ARFrame) {
        // Create two textures (Y and CbCr) from the provided frame's captured image
        let pixelBuffer = frame.capturedImage
        
        if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            return
        }
        
        capturedImageTextureY = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
        capturedImageTextureCbCr = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
    }
    
    func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, capturedImageTextureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)
        
        if status != kCVReturnSuccess {
            texture = nil
        }
        
        return texture
    }
    
    func updateImagePlane(frame: ARFrame) {
        // Update the texture coordinates of our image plane to aspect fill the viewport
        let displayToCameraTransform = frame.displayTransform(for: .landscapeRight, viewportSize: viewportSize).inverted()
        
        let vertexData = imagePlaneVertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex]), y: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = Float(transformedCoord.y)
        }
    }
    
    func drawCapturedImage(renderEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY, let textureCbCr = capturedImageTextureCbCr else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawCapturedImage")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(capturedImagePipelineState)
        renderEncoder.setDepthStencilState(capturedImageDepthState)
        
        // Set mesh's vertex buffers
        renderEncoder.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: Int(kBufferIndexMeshPositions.rawValue))
        
        // Set any textures read/sampled from our render pipeline
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: Int(kTextureIndexY.rawValue))
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: Int(kTextureIndexCbCr.rawValue))
        renderEncoder.setFragmentBytes(&dayLightMode, length: MemoryLayout<Float>.size, index: Int(kTextureIndexDayLight.rawValue))
        
        // Draw each submesh of our mesh
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.popDebugGroup()
    }

    func drawStars(renderEncoder: MTLRenderCommandEncoder, numBodies: Int, positionsBuffer1: MTLBuffer, positionsBuffer2: MTLBuffer, interpolation: Float) {
        guard numBodies > 0 else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawStars")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(starPipelineState)
        renderEncoder.setDepthStencilState(starDepthState)
        
        _interpolation.contents().assumingMemoryBound(to: Float.self).pointee = interpolation
        
        // Set any buffers fed into our render pipeline
        renderEncoder.setVertexBuffer(positionsBuffer1, offset: 0, index: Int(starRenderBufferIndexPositions1.rawValue))
        renderEncoder.setVertexBuffer(positionsBuffer2, offset: 0, index: Int(starRenderBufferIndexPositions2.rawValue))
        renderEncoder.setVertexBuffer(_interpolation, offset: 0, index: Int(starRenderBufferIndexInterpolation.rawValue))
        renderEncoder.setVertexBuffer(_colors, offset: 0, index: Int(starRenderBufferIndexColors.rawValue))
        renderEncoder.setVertexBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(starRenderBufferIndexSharedUniforms.rawValue))

        
        var partitioner : Float = (1.0 / Float(numBodies)) * (Float(min(16,max(partitions,1))) / 16.0) // 0...1 is color spectrum, ~ 16 colours , e.g. want to map it this way.
        renderEncoder.setFragmentTexture(gaussianMap, index: Int(starTextureIndexColorMap.rawValue))
        renderEncoder.setFragmentBytes(&falseColour, length: MemoryLayout<Bool>.size, index: Int(starTextureIndexFalseColour.rawValue))
        renderEncoder.setFragmentBytes(&partitioner, length: MemoryLayout<Float>.size, index: Int(starTextureIndexPartitioner.rawValue))

        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: numBodies, instanceCount: 1)
        
        renderEncoder.popDebugGroup()
    }
     
    func drawInteractive(renderEncoder: MTLRenderCommandEncoder, numBodies: Int, positionsBuffer1: MTLBuffer, positionsBuffer2: MTLBuffer, interpolation: Float, finger: vector_float4) {
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("Rays")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(interactivePipelineState)
        renderEncoder.setDepthStencilState(interactiveDepthState)
        
        let vertices = interactiveVertexBuffer.contents().assumingMemoryBound(to: InteractiveVertex.self)

        
        if !laserPointer {
            //camera
            guard let currentFrame = session.currentFrame else {
                return
            }

            let transform = currentFrame.camera.transform
            
            
            let actual_camera_position = transform*vector_float4(0,0,0,1) // faster is just to take transform.columns.3
            
            let camera_position = extractOrientationMatrix(fullmatrix: transform) *
                translationMatrix(translation: vector_float3(0.0,0.0,-0.5)) *
                extractOrientationMatrix(fullmatrix: transform).inverse * actual_camera_position

            
           // print(camera_position - finger)
            //print(finger)
       
            // black holes
            
            //print(actual_camera_position)
            let positions1 = positionsBuffer1.contents().assumingMemoryBound(to: vector_float4.self)
            let positions2 = positionsBuffer2.contents().assumingMemoryBound(to: vector_float4.self)
            let blackhole1 = (1-interpolation) * positions1[numBodies-1] + interpolation * positions2[numBodies-1]
            
            var index_blackhole2 = numBodies - 1
            if split > 0 {
                index_blackhole2 = Int(split - 1)
            }

            let blackhole2 = (1-interpolation) * positions1[index_blackhole2] + interpolation * positions2[index_blackhole2]
            let attractor = (1-interpolation) * positions1[0] + interpolation * positions2[0]

            
            
           //print(split, numBodies)

            vertices[0] = InteractiveVertex(position: attractor, color: [0, 1, 0, 1])
            vertices[1] = InteractiveVertex(position: blackhole1, color: [0, 0, 1, 1])
            vertices[2] = InteractiveVertex(position: attractor, color: [1, 0, 0, 1])
            vertices[3] = InteractiveVertex(position: blackhole2, color: [0, 1, 0, 1])
            
            /*
            vertices[3] = InteractiveVertex(position: camera_position, color: [0, 0, 1, 1])
            vertices[4] = InteractiveVertex(position: blackhole2, color: [0, 1, 0, 1])
            vertices[5] = InteractiveVertex(position: camera_position, color: [0, 0, 1, 1])
            vertices[6] = InteractiveVertex(position: blackhole2, color: [0, 1, 0, 1])
            vertices[7] = InteractiveVertex(position: blackhole1, color: [0, 1, 0, 1])
            vertices[8] = InteractiveVertex(position: blackhole2, color: [0, 1, 0, 1]) */
            /*
            vertices[0] = InteractiveVertex(position: camera_position, color: [1, 0, 0, 1])
            vertices[1] = InteractiveVertex(position: [-0.0025,-0.0025, -0.5, 0], color: [0, 1, 0, 1])
            vertices[2] = InteractiveVertex(position: [-0.0025,0.0025, -0.5, 0 ], color: [0, 0, 1, 1])
            vertices[3] = InteractiveVertex(position: camera_position, color: [1, 0, 0, 1])
            vertices[4] = InteractiveVertex(position: [-0.0025,0.0025, -0.5, 0], color: [0, 1, 0, 1])
            vertices[5] = InteractiveVertex(position: [0.0025,0.0025, -0.5, 0 ], color: [0, 0, 1, 1])
            vertices[6] = InteractiveVertex(position: camera_position, color: [1, 0, 0, 1])
            vertices[7] = InteractiveVertex(position: [0.0025,0.0025, -0.5, 0], color: [0, 1, 0, 1])
            vertices[8] = InteractiveVertex(position: [0.0025,-0.0025, -0.5,0 ], color: [0, 0, 1, 1])
            vertices[9] = InteractiveVertex(position: camera_position, color: [1, 0, 0, 1])
            vertices[10] = InteractiveVertex(position: [0.0025,-0.0025, -0.5, 0], color: [0, 1, 0, 1])
            vertices[11] = InteractiveVertex(position: [-0.0025,-0.0025, -0.5, 0 ], color: [0, 0, 1, 1]) */
            
            renderEncoder.setVertexBuffer(interactiveVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: 1)

            //renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
            renderEncoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: 4)
        }
        
        renderEncoder.popDebugGroup()
    }
    
    
    func increaseStarSize() {
        if starSize < 10 {
                starSize *= 1.25 // increase size
        }
    }
    
    func decreaseStarSize() {
        if starSize > 1.25 {
            starSize *= 1/1.25 // decrease size
        }
    }
    
    func decreaseCameraExposure() {
        if dayLightMode > 0 {
            dayLightMode -= 0.5
        }
    }
    
    func increaseCameraExposure() {
        if dayLightMode < 1 {
            dayLightMode += 0.5
        }
    }
    
    func toggleFalseColours(_split: UInt) {
        split = _split
        falseColour = !falseColour
    }
    
    func disableFalseColours() {
        split = 0
        falseColour = false
    }
}

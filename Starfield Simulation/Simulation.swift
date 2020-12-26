//
//  Simulation.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 23/12/2020.
//

import Foundation
import Metal
import MetalKit
import simd

let NumUpdateBuffersStored = 3

func generate_random_vector(min: Float, max: Float) -> vector_float3 {
//    return vector_float3.random(in: min...max)
    let r = Float.random(in: min...max)
    let theta = Float.random(in: 0...Float.pi)
    let phi = Float.random(in: 0...(2*Float.pi))
    let vector = vector_float3(r * sin(theta) * cos(phi), r * sin(theta) * sin(phi), r * cos(theta));
    return vector;
}

func generate_random_normalized_vector() -> vector_float3 {
/*    let rand = vector_float3.random(in: min...max)
    let rand_sq = rand.x * rand.x + rand.y * rand.y + rand.z*rand.z
    let rand_normal = rand / rand_sq.squareRoot()
    return rand_normal */
    return generate_random_vector(min: 1, max: 1)
}

class StarSimulation : NSObject {
    let block_size: UInt32 = 2048   // // 4096> does weird things... 2048 // max particles that we can calculate before we need to redraw, for iphone 8 / my ipad 2048 if we need 32768 bodies is a good choice, 4096 for 8192 etc. (n*n calculations, so this needs to scale as 1/n*n)
    var _blocks = [MTLBuffer]()
    
    var _device: MTLDevice!
    var _commandQueue: MTLCommandQueue!
    var _computePipeline : MTLComputePipelineState!
    var model: Int = 0
    
    var _updateBuffer = [MTLBuffer]()
    
    var _updateData = [NSData]()
    
    var _currentBufferIndex: Int = 0
    
    var _positions = [MTLBuffer]()
    var _velocities = [MTLBuffer]()
    
    var _dispatchExecutionSize: MTLSize!
    var _threadsperThreadgroup: MTLSize!
    var _threadgroupMemoryLength: Int = 0
    
    var _oldestBufferIndex: Int = 0
    var _oldBufferIndex: Int = 0
    var _newBufferIndex: Int = 0
    
    var _simulationParams: MTLBuffer!
    
    var _config: SimulationConfig!
 

    var blockBegin : UInt = 0
    var currentSplit: UInt32 = 0
    var newSplit: UInt32 = 0
    
    var _simulationTime: CFAbsoluteTime = 0
    
    var halt: Bool = false // apparently this needs to be thread safe.
    var advanceIndex: Bool = false
    
    //var nextModel: Bool = false
    
    init(computeDevice: MTLDevice, config: SimulationConfig) {
        super.init()
        
        _device = computeDevice
        _config = config
        
        createMetalObjectsAndMemory()
        initalizeData()
    }
    
/*    init(computeDevice: MTLDevice, config: SimulationConfig, positionData: NSData, velocityData: NSData, forSimulationTime: CFAbsoluteTime) {
    }
*/
    func createMetalObjectsAndMemory() {
        let defaultLibrary : MTLLibrary = _device.makeDefaultLibrary()!
        let nbodySimulation : MTLFunction = defaultLibrary.makeFunction(name: "NBodySimulation")!
        do {
            try _computePipeline = _device.makeComputePipelineState(function: nbodySimulation)
        } catch let error {
            print("Failed to create compute pipeline state, error \(error)")
        }
       
        _threadsperThreadgroup = MTLSizeMake(_computePipeline.threadExecutionWidth, 1, 1)
        _dispatchExecutionSize = MTLSizeMake((Int(block_size) + _computePipeline.threadExecutionWidth - 1) / _computePipeline.threadExecutionWidth, 1, 1)
        _threadgroupMemoryLength = _computePipeline.threadExecutionWidth * MemoryLayout<vector_float4>.size
        
        let bufferSize = MemoryLayout<vector_float3>.size * Int(_config.numBodies)
     
        
        for i in 0..<3 {
            _positions.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
            _velocities.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
            _blocks.append(_device.makeBuffer(length: MemoryLayout<StarBlock>.size, options: .storageModeShared)!)
       
            _positions[i].label = "Positions" + String(i)
            _velocities[i].label = "Velocities" + String(i)
            _blocks[i].label = "Blocks" + String(i)
        }
 
        _simulationParams = _device.makeBuffer(length: MemoryLayout<StarSimParams>.size, options: .storageModeShared)
        _simulationParams.label = "Simulation Params"
        
        let params = _simulationParams.contents().assumingMemoryBound(to: StarSimParams.self)
        
        params[0].timestep = _config.simInterval
        params[0].damping = _config.damping
        params[0].softeningSqr = _config.softeningSqr
        params[0].numBodies = _config.numBodies
        
     //   params[0].block_begin = 0
     //   params[0].block_end = min(_config.numBodies, block_size)
        
        // don't think this is needed...
        let updateDataSize: Int = Int(_config.renderBodies) * MemoryLayout<vector_float3>.size
        
        for i in 0..<NumUpdateBuffersStored {
            _updateBuffer.append(_device.makeBuffer(length: updateDataSize, options: .storageModeShared)!)
            _updateBuffer[i].label = "Update Buffer" + String(i)
        }
    }
    
    func makegalaxy(first: Int, last: Int, positionOffset: vector_float3, velocityOffset: vector_float3, rotation: vector_float3, flatten: Float, prescale : Float = 1, vrescale: Float = 1) {
        let pscale : Float = _config.clusterScale * prescale
        let vscale : Float = _config.velocityScale * pscale * vrescale
        let inner : Float = 2.5 * pscale
        let outer : Float = 4.0 * pscale
        var total_mass: Float = 0
        let alpha = rotation.x //https://en.wikipedia.org/wiki/Rotation_matrix
        let beta = rotation.y
        let gamma = rotation.z
        
        let rotation_matrix = simd_float4x4(simd_float4(cos(alpha)*cos(beta), cos(alpha)*sin(beta)*sin(gamma)-sin(alpha)*cos(gamma), cos(alpha)*sin(beta)*cos(gamma)+sin(alpha)*sin(gamma), 0),
                                              simd_float4(sin(alpha)*cos(beta), sin(alpha)*sin(beta)*sin(gamma)+cos(alpha)*cos(gamma), sin(alpha)*sin(beta)*cos(gamma)-cos(alpha)*sin(gamma), 0),
                                              simd_float4(-sin(beta), cos(beta)*sin(gamma), cos(beta)*cos(gamma),0),
                                              simd_float4(0, 0, 0, 1))
    
        _oldBufferIndex = 0
        _newBufferIndex = 1
        _oldestBufferIndex = 2

        blockBegin = 0 // make sure we start calculations from the beginning.
        advanceIndex = true // make sure we start calculations from the beginning.
        
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = _velocities[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions2 = _positions[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities2 = _velocities[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions3 = _positions[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities3 = _velocities[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)

        for i in first...last {
            
            if i == last {
                // stationary supermassive black hole in the middle.
                positions[i] = vector_float4(0,0,0,0)
                positions[i].w = pow ((1/400) * total_mass, 1/3) // black hole is approximately 1/400 of the total mass, radius is cube root.
                velocities[i] = vector_float4(0,0,0,0)

            } else {

                let nrpos = generate_random_normalized_vector()
                let position = nrpos * abs(generate_random_vector(min:inner, max: outer))
                
                positions[i].x = position.x
                positions[i].y = position.y
                positions[i].z = position.z
                positions[i].w = 1 / Float.random(in: 0.465...1) // star size, Mass is this "to the power of three", masses differ factor 10 max, sizes 1..2.15
                //positions[Int(i)].w = 1 // star size, Mass is this "to the power of three" - model with all equal mass.
                total_mass += positions[Int(i)].w + positions[Int(i)].w + positions[Int(i)].w
                
                var axis = vector_float3 (0.0, 0.0, 1.0)
                
                let scalar = nrpos.x * axis.x + nrpos.y * axis.y + nrpos.z * axis.z
                
                if ((1 - scalar) < 0.000001) {
                    axis.x = nrpos.y
                    axis.y = nrpos.x
                    
                    let axis_sq = axis.x*axis.x + axis.y*axis.y + axis.z * axis.z
                    
                    axis = axis / axis_sq.squareRoot()
                }
                
                var velocity = vector_float4(0,0,0,0)
                
                // cross product
                velocity.x = position.y * axis.z - position.z * flatten * axis.y
                velocity.y = position.z * flatten * axis.x - position.x * axis.z
                velocity.z = position.x * axis.y - position.y * axis.x
     
                /*     if ((position.x*position.x + position.y*position.y) > (inner * inner * 0.1)) {
                 
                 let radialvelocitysq = velocity.x*velocity.x * velocity.y*velocity.y // radial velocity doesn't really depend too much on where in the galaxy once > inner
                 
                 velocity.x *= 0.3 * inner / radialvelocitysq.squareRoot()
                 velocity.y *= 0.3 * inner / radialvelocitysq.squareRoot()
                 
                 } */
                
                //velocity = velocity * (vector_float4(1,1,1,0) +  0.05 * vector_float4(generate_random_normalized_vector(), 0))
                
                velocities[i] = velocity * vscale
            }
            
            // flatten
            positions[i].z *= flatten // flatten galaxiy.
            
            // rotate
            positions[i] = rotation_matrix * positions[i]
            velocities[i] = rotation_matrix * velocities[i]

            // translate (for speed this means initial "movement direction").
            positions[i] = positions[i] + vector_float4(positionOffset, 0)
            velocities[i] = velocities[i] + (vector_float4(velocityOffset, 0) * vscale)
           
            
            // in case we are "on halt", we still want it to display, e.g. copy to all buffers
            positions2[i] = positions[i]
            positions3[i] = positions[i]
            velocities2[i] = velocities[i]
            velocities3[i] = velocities[i]
        }
    }
    
    
    func initalizeData() {
 
        let maxModel = 12
                
        switch model {
        case 0: // one galaxy
            newSplit = 0
            makegalaxy(first:0, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.05)
        case 1: // small & big galaxy
            newSplit = _config.numBodies/8
            makegalaxy(first:0, last: Int(_config.numBodies)/8 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0/*.05*/,0,0), rotation: vector_float3(0,0,0), flatten: 0.05, prescale: 0.125)
            makegalaxy(first: Int(_config.numBodies)/8,  last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
        case 2: // make them collide
            newSplit = 0
        case 3: // equal galaxies, parallel
            newSplit = _config.numBodies/2
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
        case 4: // make them collide
            newSplit = 0
        case 5:// equal galaxies / parallel / opposite rotation
            newSplit = _config.numBodies/2
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,-Float.pi/2,Float.pi/2), flatten: 0.05)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
        case 6: // make them collide
            newSplit = 0
        case 7: // equal galaxies, same plane
            newSplit = _config.numBodies/2
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.05)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.05)
        case 8: // make them collide
            newSplit = 0
        case 9: // equal galaxies, same plane / opposite rotation
            newSplit = _config.numBodies/2
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,Float.pi), flatten: 0.05)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.05)
        case 10: // make them collide
            newSplit = 0
        case 11: // equal galaxies / different orientations
            newSplit = _config.numBodies/2
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.05)
            makegalaxy(first: Int(_config.numBodies)/2,  last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, -0.25), velocityOffset: vector_float3(0,0,-0), rotation: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
        case 12: // make them collide
            newSplit = 0
        default:
            newSplit = 0
            makegalaxy(first:0, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0, 0, -0.25), velocityOffset: vector_float3(0,0,0), rotation: vector_float3(0,0,0), flatten: 0.25)
        }
        
        if (model == maxModel) {
            model = 0

        } else {
            model += 1
        }
    }
    /*
    func randomMoveStars() {
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
//        let numBodies : Int = 4096
        
        for i in 0..<_config.numBodies {
            
            positions[Int(i)].x += Float.random(in: -0.01..<0.01)
            positions[Int(i)].y += Float.random(in: -0.01..<0.01)
            positions[Int(i)].z += Float.random(in: -0.01..<0.01)
        }
    }

    func fillUpdateBufferWithPositionBuffer(buffer: MTLBuffer, commandBuffer: MTLCommandBuffer) {
        
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        
        blitEncoder.label = "Position Update Blit Encoder"
        blitEncoder.pushDebugGroup("Position Update Blit Commands")
        blitEncoder.copy(from: buffer, sourceOffset: 0, to: _updateBuffer[_currentBufferIndex], destinationOffset: 0, size: _updateBuffer[_currentBufferIndex].length)
        blitEncoder.popDebugGroup()
        blitEncoder.endEncoding()
    }
    */
    func getStablePositionBuffer1() -> MTLBuffer {
        return _positions[_oldestBufferIndex]
    }

    func getStablePositionBuffer2() -> MTLBuffer {
        return _positions[_oldBufferIndex]
    }
    
    func getInterpolation() -> Float {
        let blocks = _blocks[_oldBufferIndex].contents().assumingMemoryBound(to: StarBlock.self)
        return Float(blocks[0].begin)/Float(_config.numBodies)
    }
    

    
    func simulateFrameWithCommandBuffer(commandBuffer: MTLCommandBuffer) {
        if (!halt) {
            if advanceIndex {
                advanceIndex = false
                
                let tmpIndex = _oldestBufferIndex
                _oldestBufferIndex = _oldBufferIndex
                _oldBufferIndex = _newBufferIndex
                _newBufferIndex = tmpIndex
                
                _simulationTime += CFAbsoluteTime(_config.simInterval)
                
                currentSplit = newSplit // only apply new split at beginning of an entire block (as otherwise part of the particles will have only partially calculated stuff)

            }
            let blocks = _blocks[_oldBufferIndex].contents().assumingMemoryBound(to: StarBlock.self) // ensure we start at the beginning with compute!
            blocks[0].begin = UInt32(blockBegin) // the block we want to calculate
            blocks[0].split = currentSplit
            
            commandBuffer.pushDebugGroup("Simulation")
            
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
            computeEncoder.setComputePipelineState(_computePipeline)
            
            computeEncoder.setBuffer(_positions[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewPosition.rawValue))
            computeEncoder.setBuffer(_velocities[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewVelocity.rawValue))
            computeEncoder.setBuffer(_positions[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldPosition.rawValue))
            computeEncoder.setBuffer(_velocities[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldVelocity.rawValue))
            computeEncoder.setBuffer(_simulationParams, offset: 0, index: Int(starComputeBufferIndexParams.rawValue))
            computeEncoder.setBuffer(_blocks[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexBlock.rawValue))
            computeEncoder.setThreadgroupMemoryLength(_threadgroupMemoryLength, index: 0) // duplicate
            computeEncoder.dispatchThreadgroups(_dispatchExecutionSize, threadsPerThreadgroup: _threadsperThreadgroup)
            
            computeEncoder.endEncoding()
            commandBuffer.popDebugGroup()
            
            if (UInt32(blockBegin) + block_size) >= _config.numBodies { // commit frame
                blockBegin = 0
                advanceIndex = true

               } else { // go to next block
                blockBegin = blockBegin + UInt(block_size)
            }

            return
            // testing only (no compute) return _positions[_oldBufferIndex]
        }
    }

    //func runAsyncWithUpdateHandler
    
   /* func simulateFrameWithCommandBuffer(commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        return MTLBuffer!
    }*/
    
}


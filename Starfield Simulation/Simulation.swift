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
    return vector_float3.random(in: min...max)
}

func generate_random_normalized_vector(min: Float, max: Float) -> vector_float3 {
    let rand = vector_float3.random(in: min...max)
    
    return rand / rand.squareRoot()
}

class StarSimulation : NSObject {
    var _device: MTLDevice!
    var _commandQueue: MTLCommandQueue!
    var _computePipeline : MTLComputePipelineState!
    
    var _updateBuffer = [MTLBuffer]()
    
    var _updateData = [NSData]()
    
    var _currentBufferIndex: Int = 0
    
    var _positions = [MTLBuffer]()
    var _velocities = [MTLBuffer]()
    
    var _dispatchExecutionSize: MTLSize!
    var _threadsperThreadgroup: MTLSize!
    var _threadgroupMemoryLength: Int = 0
    
    var _oldBufferIndex: Int = 0
    var _newBufferIndex: Int = 0
    
    var _simulationParams: MTLBuffer!
    
    var _config: SimulationConfig!
    
    var _simulationTime: CFAbsoluteTime = 0
    
    var halt: Bool = false // apparently this needs to be thread safe.
    
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
        _dispatchExecutionSize = MTLSizeMake(Int(_config.numBodies), 1, 1)
        _threadgroupMemoryLength = _computePipeline.threadExecutionWidth * MemoryLayout<vector_float4>.size
        
        let bufferSize = MemoryLayout<vector_float3>.size * Int(_config.numBodies)
        
        for i in 0..<2 {
            _positions.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
            _velocities.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
       
            _positions[i].label = "Positions" + String(i)
            _velocities[i].label = "Velocities" + String(i)
        }
 
        _simulationParams = _device.makeBuffer(length: MemoryLayout<StarSimParams>.size, options: .storageModeShared)
        _simulationParams.label = "Simulation Params"
        
        let params = _simulationParams.contents().assumingMemoryBound(to: StarSimParams.self)
        
        params[0].timestep = _config.simInterval
        params[0].damping = _config.damping
        params[0].softeningSqr = _config.softeningSqr
        params[0].numBodies = _config.numBodies
        
        let updateDataSize: Int = Int(_config.renderBodies) * MemoryLayout<vector_float3>.size
        
        for i in 0..<NumUpdateBuffersStored {
            _updateBuffer.append(_device.makeBuffer(length: updateDataSize, options: .storageModeShared)!)
            _updateBuffer[i].label = "Update Buffer" + String(i)
        }
    }
    
    func initalizeData() {
        let pscale : Float = _config.clusterScale
        let vscale : Float = _config.velocityScale * pscale
        let inner : Float = 2.5 * pscale
        let outer : Float = 4.0 * pscale
        let length : Float = outer - inner

        _oldBufferIndex = 0
        _newBufferIndex = 1
        
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = _velocities[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        
        for i in 0..<_config.numBodies {
            let nrpos = generate_random_normalized_vector(min: -1.0, max: 1.0)
            let rpos = generate_random_vector(min: 0.0, max: 1.0)
            let position = nrpos * (inner + (length * rpos))
            
            positions[Int(i)].x = position.x
            positions[Int(i)].x = position.y
            positions[Int(i)].x = position.z
            positions[Int(i)].w = 1.0
            
            var axis = vector_float3 (0.0, 0.0, 1.0)
         
            let scalar = nrpos.x * axis.x + nrpos.y * axis.y + nrpos.z * axis.z
            
            if ((1 - scalar) < 0.000001) {
                axis.x = nrpos.y
                axis.y = nrpos.x
                
                axis = axis / axis.squareRoot()
            }
            
            var velocity = vector_float4(0,0,0,0)
            
            // cross product
            velocity.x = position.y * axis.z - position.z * axis.y
            velocity.y = position.z * axis.x - position.x * axis.z
            velocity.z = position.x * axis.y - position.y * axis.x

            velocities[Int(i)] =  velocity * vscale
                
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
    
    func simulateFrameWithCommandBuffer(commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        commandBuffer.pushDebugGroup("Simulation")
        
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        computeEncoder.setComputePipelineState(_computePipeline)
        
        computeEncoder.setBuffer(_positions[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewPosition.rawValue))
        computeEncoder.setBuffer(_velocities[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewVelocity.rawValue))
        computeEncoder.setBuffer(_positions[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldPosition.rawValue))
        computeEncoder.setBuffer(_velocities[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldVelocity.rawValue))

        computeEncoder.setThreadgroupMemoryLength(_threadgroupMemoryLength, index: 0)
        
        computeEncoder.dispatchThreads(_dispatchExecutionSize, threadsPerThreadgroup: _threadsperThreadgroup)
        
        computeEncoder.endEncoding()
        
        let tmpIndex = _oldBufferIndex
        _oldBufferIndex = _newBufferIndex
        _newBufferIndex = tmpIndex
        
        commandBuffer.popDebugGroup()
        
        _simulationTime += CFAbsoluteTime(_config.simInterval)
        
        return _positions[_newBufferIndex]
    }

    //func runAsyncWithUpdateHandler
    
   /* func simulateFrameWithCommandBuffer(commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        return MTLBuffer!
    }*/
    
}


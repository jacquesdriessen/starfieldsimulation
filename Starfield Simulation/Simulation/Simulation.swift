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
    return generate_random_vector(min: 1, max: 1)
}

func length_float4(vector: vector_float4) -> Float {
    return sqrt(vector.x*vector.x + vector.y+vector.y + vector.z+vector.z)
}

class StarSimulation : NSObject {
    let block_size: UInt32 = 2048 // will get ~ 60 fps on iphone 8. max particles that we can calculate before we need to redraw, for iphone 8 / my ipad 2048 if we need 32768 bodies is a good choice, 4096 for 8192 etc. (n*n calculations, so this needs to scale as 1/n*n)
    var _blocks = [MTLBuffer]()
    
    let blockSemaphore = DispatchSemaphore(value: 1) // don't have overlapping block calculations

    var _device: MTLDevice!
    var _commandQueue: MTLCommandQueue!
    var _computePipeline : MTLComputePipelineState!
    let models: Int = 10
    var model: Int = 0
    
    var _currentBufferIndex: Int = 0
    
    var _positions = [MTLBuffer]()
    var _velocities = [MTLBuffer]()
    var spectatorMovement = [MTLBuffer]()
    
    var _dispatchExecutionSize: MTLSize!
    var _threadsperThreadgroup: MTLSize!
    var _threadgroupMemoryLength: Int = 0
    
    var _oldestBufferIndex: Int = 0
    var _oldBufferIndex: Int = 0
    var _newBufferIndex: Int = 0
    
    var _simulationParams: MTLBuffer!
    
    var _config: SimulationConfig!
 

    var blockBegin : UInt = 0
    var split: UInt32 = 0
    var collide: Bool = false
    
    var _simulationTime: CFAbsoluteTime = 0
    
    var halt: Bool = false // apparently this needs to be thread safe.
    var advanceIndex: Bool = false
    var camera : simd_float4x4 = matrix_identity_float4x4
    var interact = false
    
    var track = 0
    var speed : Float = 100 // percentage
    var gravity: Float = 100 // percentage
    var pinch: Float = 1 // pinching to "squeeze" space.

    var rotateGalaxies = 0
    var rotateParticles = 0
    var pass = 0
    
    var movement: SpecatorMovement = SpecatorMovement(position: vector_float4(0,0,0,0), velocity: vector_float4(0,0,0,0))

    init(computeDevice: MTLDevice, config: SimulationConfig) {
        super.init()
        
        _device = computeDevice
        _config = config
        
        createMetalObjectsAndMemory()
        initalizeData()
    }

    func createMetalObjectsAndMemory() {
        let defaultLibrary : MTLLibrary = _device.makeDefaultLibrary()!
        let nbodySimulation : MTLFunction = defaultLibrary.makeFunction(name: "NBodySimulation")!
        do {
            try _computePipeline = _device.makeComputePipelineState(function: nbodySimulation)
        } catch let error {
            print("Failed to create compute pipeline state, error \(error)")
        }
       
        _threadsperThreadgroup = MTLSizeMake(_computePipeline.threadExecutionWidth, 1, 1)
        _dispatchExecutionSize = MTLSizeMake((Int(min(block_size, _config.numBodies)) + _computePipeline.threadExecutionWidth - 1) / _computePipeline.threadExecutionWidth, 1, 1)
        _threadgroupMemoryLength = _computePipeline.threadExecutionWidth * MemoryLayout<vector_float4>.size
        
        
        let bufferSize = MemoryLayout<vector_float3>.size * Int( ( ( UInt32(_config.numBodies) + block_size) / block_size) * block_size) // as integer math, this should give us a buffer that holds either the exact numBodies (in case that's a multiple of block_size), or numBodies + block_size (in case it's not). Required as otherwise the GPU will try to access memory > buffer.
     
        
        for i in 0..<3 {
            _positions.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
            _velocities.append(_device.makeBuffer(length: bufferSize, options: .storageModeShared)!)
            _blocks.append(_device.makeBuffer(length: MemoryLayout<StarBlock>.size, options: .storageModeShared)!)
            spectatorMovement.append(_device.makeBuffer(length: MemoryLayout<SpecatorMovement>.size, options: .storageModeShared)!)
       
            _positions[i].label = "Positions" + String(i)
            _velocities[i].label = "Velocities" + String(i)
            _blocks[i].label = "Blocks" + String(i)
            spectatorMovement[i].label = "Tracking" + String(i)
        }
 
        _simulationParams = _device.makeBuffer(length: MemoryLayout<StarSimParams>.size, options: .storageModeShared)
        _simulationParams.label = "Simulation Params"
        
        let params = _simulationParams.contents().assumingMemoryBound(to: StarSimParams.self)
        
        params[0].timestep = _config.simInterval * (speed/100)
        params[0].damping = _config.damping
        params[0].softeningSqr = _config.softeningSqr
        params[0].numBodies = _config.numBodies
    }
    
    func cross_product (a: vector_float3, b: vector_float3) -> vector_float3 {
        var x_product = vector_float3(0,0,0)
        
        x_product.x = a.y * b.z - a.z * b.y
        x_product.y = a.z * b.x - a.x * b.z
        x_product.z = a.x * b.y - a.y * b.x
        
        return x_product
    }
    
    func addParticles(first: Int, last: Int, touch: vector_float2 = vector_float2(0,0), finger: vector_float4 = vector_float4(0,0,0,0)) {
        
        let pointer = finger - camera.columns.3
        let pointer_3 = vector_float3(pointer.x, pointer.y, pointer.z)
        
        let offset_3 = vector_float3(0,0,-1)
        
        let translation_3 = 0.5*(pointer_3 + offset_3)

        let rightInFrontOfCamera = camera * translationMatrix(translation: translation_3)
        
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = _velocities[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions2 = _positions[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities2 = _velocities[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions3 = _positions[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities3 = _velocities[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)

        let position_transformation = rightInFrontOfCamera
        
        let anchor = first == 0 ? Int(_config.numBodies - 1) : first - 1
        let position_anchor = positions[anchor]
        let position_last = position_transformation * vector_float4(0, 0, 0, 1)
        
        for index in first...last {
            let interpolation : Float = Float(index + 1 - first) / Float(last + 1 - first)
            let position = interpolation * position_last + (1 - interpolation) * position_anchor

            positions[index] = position
            positions[index].w = 1 / Float.random(in: 0.465...1) // star size, Mass is this "to the power of three", masses differ factor 10 max, sizes 1..2.15
            velocities[index] = vector_float4(0, 0, 0, 0)
            
            // in case we are "on halt", we still want it to display, e.g. copy to all buffers
            positions2[index] = positions[index]
            positions3[index] = positions[index]
            velocities2[index] = velocities[index]
            velocities3[index] = velocities[index]
        }
    }
    
    func zeroparticles(first: Int, last: Int) {
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = _velocities[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions2 = _positions[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities2 = _velocities[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions3 = _positions[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities3 = _velocities[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        
        for i in first...last {
            let zero = vector_float4(0,0,0,0)
            positions[i] = zero
            velocities[i] = zero
            positions2[i] = zero
            velocities2[i] = zero
            positions3[i] = zero
            velocities3[i] = zero
        }
    }
    
    func makegalaxy(first: Int, last: Int, positionOffset: vector_float3 = vector_float3(0,0,0), velocityOffset: vector_float3 = vector_float3(0,0,0), axis: vector_float3 = vector_float3(0,0,0), flatten: Float = 1, prescale : Float = 1, vrescale: Float = 1, vrandomness: Float = 0, squeeze: Float = 1, collision_enabled: Bool = false) {
        
        // reset simulation
        _oldBufferIndex = 0
        _newBufferIndex = 1
        _oldestBufferIndex = 2
        
        blockBegin = 0 // make sure we start calculations from the beginning.
        advanceIndex = true // make sure we start calculations from the beginning.
        
        track = 0 // stop tracking
        collide = collision_enabled
        speed = 100 // back to default speed
        gravity = 100 // back to default gravity
        pinch = 1 // no squeezing space anymore
        rotateGalaxies = 0 // for placing galaxies
        partitions += 1 // increase partitions.
        pass = 0 // start at pass one again

        makegalaxyonlyaddparticles(first: first, last: last, positionOffset: positionOffset, velocityOffset: velocityOffset, axis: axis, flatten: flatten, prescale: prescale, vrescale: vrescale, vrandomness: vrandomness, squeeze: squeeze, collision_enabled: collision_enabled)
    }
        

    func makegalaxyonlyaddparticles(first: Int, last: Int, positionOffset: vector_float3 = vector_float3(0,0,0), velocityOffset: vector_float3 = vector_float3(0,0,0), axis: vector_float3 = vector_float3(0,0,0), flatten: Float = 1, prescale : Float = 1, vrescale: Float = 1, vrandomness: Float = 0, squeeze: Float = 1, collision_enabled: Bool = false) {
        let pscale : Float = _config.clusterScale * prescale
        let vscale : Float = _config.velocityScale * pscale * vrescale
        let inner : Float = 2.5 * pscale
        let outer : Float = 4.0 * pscale
        var total_mass: Float = 0

        let rightInFrontOfCamera = simd_mul(camera, translationMatrix(translation:vector_float3(0,0,-0.5))) //0.5 meters in front of the camera, so we can see it!
        let rotation_matrix = rotationMatrix(rotation: axis)

        let position_transformation = rightInFrontOfCamera * translationMatrix(translation: positionOffset) * rotation_matrix
        let velocity_transformation = rightInFrontOfCamera * translationMatrix(translation: velocityOffset * _config.clusterScale * _config.velocityScale) * rotation_matrix
        
        split = UInt32(first) // split will always be right before the "last galaxy".
        
        let positions = _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities = _velocities[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions2 = _positions[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities2 = _velocities[_oldestBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let positions3 = _positions[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)
        let velocities3 = _velocities[_newBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)

        for i in first...last {
            if i == first { // reserve first particle to be able to interact with things.
                positions[i] = vector_float4(0,0,0,0)
                positions[i].w = 0
                velocities[i] = vector_float4(0,0,0,0)
            }
            else if i == last { // last particle is stationary supermassive black hole in the middle.
                positions[i] = vector_float4(0,0,0,0)
                positions[i].w = pow ((1/400) * total_mass, 1/3) // black hole is approximately 1/400 of the total mass, radius is cube root.
                velocities[i] = vector_float4(0,0,0,0)

            } else {

                let nrpos = generate_random_normalized_vector()
                //let position = nrpos * abs(generate_random_vector(min:inner, max: outer)) // alternate
                let rpos = abs(generate_random_normalized_vector())
                let position = nrpos * (inner + ((outer-inner) * rpos));
                
                positions[i].x = position.x
                positions[i].y = position.y
                positions[i].z = position.z
                positions[i].w = 1 / Float.random(in: 0.465...1) // star size, Mass is this "to the power of three", masses differ factor 10 max, sizes 1..2.15
                //positions[Int(i)].w = 1 // star size, Mass is this "to the power of three" - model with all equal mass.
                total_mass += positions[Int(i)].w + positions[Int(i)].w + positions[Int(i)].w
                
                var main_axis = vector_float3 (0.0, 0.0, 1.0)
                
                let scalar = nrpos.x * main_axis.x + nrpos.y * main_axis.y + nrpos.z * main_axis.z
                
                if ((1 - scalar) < 0.000001) { // not entirely sure what this is for.
                    main_axis.x = nrpos.y
                    main_axis.y = nrpos.x
                    
                    let axis_sq = main_axis.x*main_axis.x + main_axis.y*main_axis.y + main_axis.z * main_axis.z
                    
                    main_axis = main_axis / axis_sq.squareRoot()
                }

                var velocity = vector_float4(0,0,0,0)

                // flatten
                positions[i].z *= flatten // flatten galaxiy.
                
                let nposition = position / sqrt(position.x * position.x + position.y * position.y + position.z * position.z) // used normalized positions for speed, as speed is approximately independent on distance from center.
                
                velocity = vector_float4(cross_product(a: nposition, b: main_axis),0)

                velocity = velocity * (vector_float4(1,1,1,0) + vrandomness * vector_float4(generate_random_normalized_vector(), 0)) // add some randomness here
                

                velocities[i] = velocity * vscale
                
                // squeeze fakes our way into a spiral galaxy, adjust velocities + create a bar.
                velocities[i].x /= squeeze
                velocities[i].y *= squeeze

                if ((1 - scalar) < 0.5) {
                    // squeeze - create a bar in the middle to make for a better start.
                    positions[i].y /= squeeze
                }
            }
 
            
            // apply the rotation & translation + go to camera coordinates.
            let temp_radius = positions[i].w // save this value - as we use this for something else.
            positions[i].w = 1 // if we don't do this, would mess up the transformation
            velocities[i].w = 1 // otherwise this wouldn't work either.
            positions[i] = position_transformation * positions[i]
            velocities[i] = velocity_transformation * velocities[i]
            positions[i].w = temp_radius // restores .w
            
            // in case we are "on halt", we still want it to display, e.g. copy to all buffers
            positions2[i] = positions[i]
            positions3[i] = positions[i]
            velocities2[i] = velocities[i]
            velocities3[i] = velocities[i]
        }
    }
    
    func collide(semaphore: DispatchSemaphore? = nil)  { // optional semaphore, in case we for example don't want to interfere with other gpu ops
        if semaphore != nil {
            semaphore!.wait()
        }
        
        collide = true
        
        if semaphore != nil {
            semaphore!.signal()
        }
    }

    func leaveAlone(semaphore: DispatchSemaphore? = nil)  { // optional semaphore, in case we for example don't want to interfere with other gpu ops
        if semaphore != nil {
            semaphore!.wait()
        }
        
        collide = false
        
        if semaphore != nil {
            semaphore!.signal()
        }
    }
    
    func nextmodel(semaphore: DispatchSemaphore? = nil) { // optional semaphore, in case we for example don't want to interfere with other gpu ops
        model = (model + 1) % models
        
        initalizeData(model: model, semaphore: semaphore)
    }
    
    func previousmodel(semaphore: DispatchSemaphore? = nil) { // optional semaphore, in case we for example don't want to interfere with other gpu ops
        if model != 0 {
            model -= 1
        } else {
            model = models-1
        }

        initalizeData(model: model, semaphore: semaphore)
    }
    
    
    func initalizeData(model: Int = 0, semaphore: DispatchSemaphore? = nil) { // optional semaphore, in case we for example don't want to interfere with other gpu ops
        if semaphore != nil {
            semaphore!.wait()
        }
        
        // reset partitions, each galaxy creation will "up" this.
        partitions = 0
        
        // when adding things, make sure we update "models" in the var declarion, which holds the total number, e.g. the last (as we start from 0) = models-1
        switch model {
        case 0: // one flat galaxy
            makegalaxy(first:0, last: Int(_config.numBodies) - 1, flatten: 0.05, squeeze: 2)
        case 1: // one round odd galaxy
            makegalaxy(first:0, last: Int(_config.numBodies) - 1, squeeze: 2)
        case 2: // small & big galaxy
            makegalaxy(first:0, last: Int(_config.numBodies)/8 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), flatten: 0.05, prescale: 0.125, squeeze: 2)
            zeroparticles(first: Int(_config.numBodies)/8, last: Int(_config.numBodies)/2 - 1)
            makegalaxy(first: Int(_config.numBodies)/2,  last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), axis: vector_float3(0, Float.pi/2, 0), flatten: 0.05, squeeze: 2)
        case 3: // equal galaxies, parallel
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), axis: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05, squeeze: 2)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), axis: vector_float3(0,Float.pi/2,Float.pi/2), flatten: 0.05)
        case 4:// equal galaxies / parallel / opposite rotation
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), axis: vector_float3(0,-Float.pi/2,0), flatten: 0.05, squeeze: 2)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), axis: vector_float3(0,Float.pi/2,0), flatten: 0.05, squeeze: 2)
        case 5: // equal galaxies, same plane
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), flatten: 0.05, squeeze: 2)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), flatten: 0.05, squeeze: 2)
        case 6: // equal galaxies, same plane / opposite rotation
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), axis: vector_float3(0,0,Float.pi), flatten: 0.05, squeeze: 2)
            makegalaxy(first:Int(_config.numBodies)/2, last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), axis: vector_float3(0,0,0), flatten: 0.05, squeeze: 2)
        case 7: // equal galaxies / different orientations
            makegalaxy(first:0, last: Int(_config.numBodies)/2 - 1, positionOffset: vector_float3(-0.15, 0.05, 0), flatten: 0.05, squeeze: 2)
            makegalaxy(first: Int(_config.numBodies)/2,  last: Int(_config.numBodies) - 1, positionOffset: vector_float3(0.15, 0, 0), axis: vector_float3(0,Float.pi/2,0), flatten: 0.05, squeeze: 2)
        case 8: // 8 small galaxies
            for i in 0...7 {
                makegalaxy(first:i * Int(_config.numBodies)/8, last: ((i+1) * Int(_config.numBodies)/8) - 1, positionOffset: vector_float3(Float.random(in: -0.2...0.2), Float.random(in: -0.2...0.2), Float.random(in: -0.3...0)), axis: vector_float3(Float.random(in: 0...Float.pi),Float.random(in: 0...Float.pi),Float.random(in: 0...Float.pi)), flatten: Float.random(in: 0.05...1), prescale: 0.125, squeeze: Float.random(in: 1...2))
            }
        case 9: // 16 even smaller galaxies
            for i in 0...15 {
                makegalaxy(first:i * Int(_config.numBodies)/16, last: ((i+1) * Int(_config.numBodies)/16) - 1, positionOffset: vector_float3(Float.random(in: -0.2...0.2), Float.random(in: -0.2...0.2), Float.random(in: -0.3...0)), axis: vector_float3(Float.random(in: 0...Float.pi),Float.random(in: 0...Float.pi),Float.random(in: 0...Float.pi)), flatten: Float.random(in: 0.05...1), prescale: 0.0625, squeeze: Float.random(in: 1...2))
            }
        default:
            makegalaxy(first:0, last: Int(_config.numBodies) - 1, flatten: 0.25)
        }
  
        if semaphore != nil {
            semaphore!.signal()
        }
    }
    
    func move (position: vector_float4 = vector_float4(0,0,0,0), velocity :vector_float4 = vector_float4(0,0,0,0)) {
        movement = SpecatorMovement(position: position, velocity: velocity)
    }

    func squeeze(_pinch: Float) {
        pinch = max(0.9, min(1.1, _pinch))
    }
    
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

    func simulateFrameWithCommandBuffer(commandBuffer: MTLCommandBuffer, touch: vector_float2, finger: vector_float4) {
        if (halt && interact) { // need to clearn this up, this is nonsensical this way
/* anyway, this sort of works, probably can go in .  */
            let step = 8
            let previous = rotateParticles
            rotateParticles += step
            
            addParticles(first: previous, last: rotateParticles - 1, touch: touch, finger: finger)

            if rotateParticles  >= _config.numBodies  {
                rotateParticles = 0
            }
            
        }
        
        if (!halt) {
            // could be done smarter, e.g. make sure we only wait if we need to advance the frame, now it just waits advancing + pushing stuff to the gpu every compute cyle, but otherwise we get artefacts (particles not advancing, because of advancing frames before computations have finished.
            let _ = blockSemaphore.wait(timeout: DispatchTime.distantFuture)
            
            
            if advanceIndex {
                advanceIndex = false
                
              
                let tmpIndex = _oldestBufferIndex
                _oldestBufferIndex = _oldBufferIndex
                _oldBufferIndex = _newBufferIndex
                _newBufferIndex = tmpIndex
                
                _simulationTime += CFAbsoluteTime(_config.simInterval)
                pass = pass - 1 // next pass.
                
                let blocks = _blocks[_oldBufferIndex].contents().assumingMemoryBound(to: StarBlock.self) // ensure we start at the beginning with compute!
                blocks[0].split = split
                blocks[0].collide = collide
                
                let params = _simulationParams.contents().assumingMemoryBound(to: StarSimParams.self)
                params[0].timestep = _config.simInterval * (speed/100)
                params[0].gravity = (gravity/100)
                params[0].squeeze = pinch
                 
                let date = Date()
                let calendar = Calendar.current
                let seconds = calendar.component(.second, from: date)
                
                if (seconds < 30) {// alternate damping every 30 seconds, so the total energy stays the same, but it makes the results look cooler to have damping.
                    params[0].damping = _config.damping
                } else {
                    params[0].damping = 1/_config.damping
                }
                
                if (interact) {
 /* option 1
                    // THIS CREATES BLACK HOLE, need to look at this code - incorporate it somehow
                    
                    // interact with (both if we have 2) galaxies
                    var translation = matrix_identity_float4x4
                    translation.columns.3.z = -1// Create a transform with a translation of 0.01 meters behindthe camera
                    let rightInFrontOfCamera = simd_mul(camera, translation)
                    print("black hole")
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[0].x = rightInFrontOfCamera.columns.3.x
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[0].y = rightInFrontOfCamera.columns.3.y
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[0].z = rightInFrontOfCamera.columns.3.z
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[0].w = 23*3// roughly 10% of the weight of the entire rest of the simulation combined
                    
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(split)].x = rightInFrontOfCamera.columns.3.x
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(split)].y = rightInFrontOfCamera.columns.3.y
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(split)].z = rightInFrontOfCamera.columns.3.z
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(split)].w = 23*3
                } else {
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[0].w = 0
                    _positions[_oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(split)].w = 0
 
*/
                    // option 2 , place galaxy, really works neat
                    
                    /*
                    rotateGalaxies += Int(_config.numBodies)/8
                    if rotateGalaxies  > _config.numBodies  {
                        rotateGalaxies = 0
                    }

                    makegalaxyonlyaddparticles(first: rotateGalaxies, last: rotateGalaxies + Int(_config.numBodies)/8 - 1, positionOffset: vector_float3(0, 0, 0), flatten: 0.05, prescale: 0.125, squeeze: 2) 
                    */
                    
    //option 3  -- place stars
                    /* //method 1
                     rotateParticles += 1
                     if rotateParticles  > _config.numBodies  {
                     rotateParticles = 0
                     }
                     
                     addparticles(index: rotateParticles) */
                    
                    // method 2, just losts of small galaxies
                    
                    /* this didn't work too well
                    let divisor = 4096
                    rotateGalaxies += Int(_config.numBodies)/divisor
                    if rotateGalaxies  > _config.numBodies  {
                        rotateGalaxies = 0
                    }
                    
                    makegalaxyonlyaddparticles(first: rotateGalaxies, last: rotateGalaxies + Int(_config.numBodies)/divisor - 1, positionOffset: vector_float3(0, 0, 0.49), flatten: 0.05, prescale: pow(1.0 / Float(divisor), 1/2), squeeze: 2) // offset 0.4 in z direction so it's right in front of where the device is.
                    */
                    
                    //method 3 -- needs to be in main loop I guess.
            /*        let step = 8 // needs to be power of 2
                    
                    let previous = rotateParticles
                    rotateParticles += step
                    
                    if rotateParticles  > _config.numBodies  {
                        rotateParticles = 0
                    }
                    
                    
                     
                    addParticles(first: previous, last: rotateParticles - 1)
                  */
                    
                  // this to go to add particles / writing in the sky mode
                    halt = true
                }
                
 
 
                
                // all spectator movement
                
                // start with zero
                var totalMovement = SpecatorMovement(position: vector_float4(0,0,0,0), velocity: vector_float4(0,0,0,0))
                
                // add movement requested by UI
                totalMovement.position += movement.position
                totalMovement.velocity += movement.velocity

                // reset to zero, UI will ask for more in next frame if needed
                movement = SpecatorMovement(position: vector_float4(0,0,0,0), velocity: vector_float4(0,0,0,0))
                
                //
                //
                // maybe we should move below into UI - and have it call move.
                //
                
                let trackSpeed : Float = 0.1
                var trackPosition : vector_float4 = vector_float4(0,0,0,0)
                var trackVelocity : vector_float4 = vector_float4(0,0,0,0)
                                
                switch(track) {
                case 0:
                    do { // no tracking
                    }
                case 1:
                    do {
                        trackPosition = _positions[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self._config.numBodies) - 1]
                        trackVelocity = _velocities[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self._config.numBodies) - 1]
                    }
                case 2:
                    do {
                        trackPosition = _positions[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self.split) - 1]
                        trackVelocity = _velocities[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self.split) - 1]
                    }
                case 3:
                    do {
                        trackVelocity = 0.5 * (_positions[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self._config.numBodies) - 1] + _positions[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self.split) - 1])
                        trackVelocity = 0.5 * (_velocities[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self._config.numBodies) - 1] +
                                                            _velocities[self._oldBufferIndex].contents().assumingMemoryBound(to: vector_float4.self)[Int(self.split) - 1])
                    }
                default:
                    do { // no tracking
                    }
                }
                
                // add tracking velicity and position
                totalMovement.velocity += trackVelocity
                totalMovement.position += trackSpeed * trackPosition
                
                // and pass the total movement onto the simulation
                spectatorMovement[_oldBufferIndex].contents().assumingMemoryBound(to: SpecatorMovement.self)[0] = totalMovement
            }
            
            
            
            let blocks = _blocks[_oldBufferIndex].contents().assumingMemoryBound(to: StarBlock.self) // ensure we start at the beginning with compute!
            blocks[0].begin = UInt32(blockBegin) // the block we want to calculate
            
            commandBuffer.pushDebugGroup("Simulation")
            
            commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.blockSemaphore.signal()
                }
            }
            
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
            computeEncoder.setComputePipelineState(_computePipeline)
            
            computeEncoder.setBuffer(_positions[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewPosition.rawValue))
            computeEncoder.setBuffer(_velocities[_newBufferIndex], offset: 0, index: Int(starComputeBufferIndexNewVelocity.rawValue))
            computeEncoder.setBuffer(_positions[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldPosition.rawValue))
            computeEncoder.setBuffer(_velocities[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexOldVelocity.rawValue))
            computeEncoder.setBuffer(_simulationParams, offset: 0, index: Int(starComputeBufferIndexParams.rawValue))
            computeEncoder.setBuffer(_blocks[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexBlock.rawValue))
            computeEncoder.setBuffer(spectatorMovement[_oldBufferIndex], offset: 0, index: Int(starComputeBufferIndexTracking.rawValue))
            computeEncoder.setBytes(&partitions, length: MemoryLayout<UInt>.size, index: Int(starComputeBufferIndexPartitions.rawValue))
            computeEncoder.setBytes(&pass, length: MemoryLayout<UInt>.size, index: Int(starComputeBufferIndexPass.rawValue))

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
            

        }
        return
    }
}


//
//  ViewController.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

import UIKit
import Metal
import MetalKit
import ARKit

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    var _view: MTKView!
    var session: ARSession!
    var renderer: Renderer!
    var _simulation: StarSimulation!
    
    //var _metalDeviceObserver = NSObject!
    
    var _simulationTime: CFAbsoluteTime!
    
 //   var _continuationTime: CFAbsoluteTime!
    
    var _computeDevice: MTLDevice!
    
    var _commandQueue: MTLCommandQueue!

  //  var _configNum: Int = 0
    
    var _config: SimulationConfig!
    
    var _terminateAllSimulations = false
    
  //  var _restartSimulation = false
    
   // var _blinker: Timer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        session = ARSession()
        session.delegate = self
        
        // Set the view to use the default device
        _view = (self.view as! MTKView)
        
        _view.device = MTLCreateSystemDefaultDevice()
        _view.backgroundColor = UIColor.clear
        _view.delegate = self
            
        guard _view.device != nil else {
            print("Metal is not supported on this device")
            return
        }
            
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognize:)))
        view.addGestureRecognizer(tapGesture)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginSimulation()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        let serialQueue = DispatchQueue(label: "com.test.mySerialQueue")
        serialQueue.sync {
            _simulation.halt = true
            _terminateAllSimulations = true
        }
        
        // remove device observer
        

    }
    
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()

        // Run the view's session
        session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        session.pause()
    }
    
    func beginSimulation() {
        _simulationTime = 0
        _config = SimulationConfig(damping: 1, softeningSqr: 0.01, numBodies: 16384, clusterScale: 0.05, velocityScale: 25000, renderScale: 20, renderBodies: 16 /* not implemented */, simInterval: 0.0000080, simDuration: 100 /* dont think thtis was implemented */)
        
        
        // Configure the renderer to draw to the view
        renderer = Renderer(session: session, metalDevice: _view.device!, renderDestination: _view, numBodies: Int(_config.numBodies))

        renderer.setRenderScale(renderScale: _config.renderScale)
        
        _computeDevice = _view.device!
        
        renderer.drawRectResized(size: _view.bounds.size)
        
        print("Starting Simulation")
        
        _simulation = StarSimulation.init(computeDevice: _computeDevice, config: _config)

        
        _commandQueue = renderer.device.makeCommandQueue()
    }
    
    /*
    // if on other device, shouldn't be needed
    func updateWithNewPositionDate(updateData: NSData, simulationTime: CFAbsoluteTime) {
        let serialQueue = DispatchQueue(label: "com.test.mySerialQueue")
        serialQueue.sync {
            renderer.providePositionData(data: updateData)
            _simulationTime = simulationTime
        }
    }
    */
    
    @objc
    func handleTap(gestureRecognize: UITapGestureRecognizer) {
       /* // Create anchor using the camera's current position
        if let currentFrame = session.currentFrame {
            
            // Create a transform with a translation of 0.2 meters in front of the camera
            var translation = matrix_identity_float4x4
            translation.columns.3.z = -0.2
            let transform = simd_mul(currentFrame.camera.transform, translation)
            
            // Add a new anchor to the session
            let anchor = ARAnchor(transform: transform)
            session.add(anchor: anchor)
        }*/
        _simulation.initalizeData()
    }
    
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        if _simulation != nil {
            renderer.draw(positionsBuffer1: _simulation.getStablePositionBuffer1(), positionsBuffer2: _simulation.getStablePositionBuffer2(), interpolation: _simulation.getInterpolation(), numBodies: Int(_config.numBodies), inView: _view)
        }
        
        if _commandQueue != nil {
            let commandBuffer = _commandQueue.makeCommandBuffer()!
            
            commandBuffer.pushDebugGroup("Controller Frame")
            
            _simulation.simulateFrameWithCommandBuffer(commandBuffer: commandBuffer)
            
            commandBuffer.commit()
            commandBuffer.popDebugGroup()
            
            _simulationTime += Double(_config.simInterval)
        }
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        
    }
}

//
//  ViewController.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

import Metal
import MetalKit
import ARKit
import UIKit

@IBDesignable class MyButton: UIButton
{
    override func layoutSubviews() {
        super.layoutSubviews()
        
        layer.cornerRadius = frame.size.height / 5
        clipsToBounds = true
        alpha = 0.2
        backgroundColor = .darkGray
        tintColor = .white
    }
}

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    var _view: MTKView!
    var session: ARSession!
    var renderer: Renderer!
    var _simulation: StarSimulation!
    
    var _simulationTime: CFAbsoluteTime!
    
    var _computeDevice: MTLDevice!
    
    var _commandQueue: MTLCommandQueue!
    
    var _config: SimulationConfig!
    
    var _terminateAllSimulations = false
    
    var pinch : CGFloat = 0
    
    var horizontalPan = false
    var verticalPan = false
    /*
    @IBAction func actionDarken(_ sender: Any) {
        renderer.decreaseCameraExposure()
    }
    
    @IBAction func actionBrighten(_ sender: Any) {
        renderer.increaseCameraExposure()
    }
    */
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
            return
        }
        
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleDoubleTap(gestureRecognize:)))
        view.addGestureRecognizer(doubleTapGesture)
        doubleTapGesture.numberOfTapsRequired = 2

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognize:)))
        view.addGestureRecognizer(tapGesture)
        tapGesture.numberOfTapsRequired = 1
        tapGesture.require(toFail: doubleTapGesture)
   
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(ViewController.handlePinch(gestureRecognize:)))
        view.addGestureRecognizer(pinchGesture)
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(ViewController.handlePan(gestureRecognize:)))
        view.addGestureRecognizer(panGesture)
        panGesture.require(toFail: tapGesture)
   
   }

    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginSimulation()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        let serialQueue = DispatchQueue(label: "com.starfieldsimulation.mySerialQueue")
        serialQueue.sync {
            _simulation.halt = true
            _terminateAllSimulations = true
        }
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
     //   _config = SimulationConfig(damping: 1, softeningSqr: 0.01, numBodies: 16384, clusterScale: 0.05, velocityScale: 25000, renderScale: 20, renderBodies: 16 /* not implemented */, simInterval: 0.0000320, simDuration: 100 /* dont think thtis was implemented */)
     //   _config = SimulationConfig(damping: 1, softeningSqr: 0.08, numBodies: 16384, clusterScale: 0.05, velocityScale: 25000, renderScale: 20, renderBodies: 16 /* not implemented */, simInterval: 0.0000640, simDuration: 100 /* dont think thtis was implemented */) // this is fairly realistic (my opinion)
      //  _config = SimulationConfig(damping: 1, softeningSqr: 2*2*0.16, numBodies: 2*32768, clusterScale: 0.05, velocityScale: 25000, renderScale: 2*40, renderBodies: 16 /* not implemented */, simInterval: 2*2*0.0002560, simDuration: 100 /* dont think thtis was implemented */) // also fairly realistic  with these # particles
        _config = SimulationConfig(damping: 0.999, softeningSqr: 0.128, numBodies: 32768, clusterScale: 0.035, velocityScale: 4000, renderScale: 1, renderBodies: 16 /* not implemented */, simInterval: 0.0002560, simDuration: 100 /* dont think thtis was implemented */) // also fairly realistic  with these # particles
        
        // Configure the renderer to draw to the view
        renderer = Renderer(session: session, metalDevice: _view.device!, renderDestination: _view, numBodies: Int(_config.numBodies))

        renderer.setRenderScale(renderScale: _config.renderScale)
        
        _computeDevice = _view.device!
        
        renderer.drawRectResized(size: _view.bounds.size)
        
        print("Starting Simulation")
        
        _simulation = StarSimulation.init(computeDevice: _computeDevice, config: _config)

        _commandQueue = renderer.device.makeCommandQueue()
    }
    
    @objc
    func handleDoubleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
           
        if gestureRecognize.state == .began {
        }
        
        if gestureRecognize.state == .ended {
            let x = 200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width // coordinates -100...100
            let y = 200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height  // coordinates -100...100
            
            if x < -80 && y > 80 { // unambiguous bottom left corner
                renderer.decreaseStarSize()
            } else if x > 80 && y > 80 { // unambiguous bottom right corner
                renderer.increaseStarSize()
            } else if x < -80 && y < -80 { // unambiguous top left corner
                renderer.decreaseCameraExposure()
            } else if x > 80 && y < -80 { // unambiguous top right corner
                renderer.increaseCameraExposure()
            } else { // tracking mode
                 _simulation.track = (_simulation.track + 1) % 4
            }
        }
    }
    
    @objc
    func handleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        if gestureRecognize.state == .began {
        }
        
        if gestureRecognize.state == .ended {
            let x = 200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width // coordinates -100...100
            let y = 200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height  // coordinates -100...100
            
            if x < -80 && abs(y) < 50 { // unambiguous left
                // disable false colour mode as going to next simulation
                renderer.disableFalseColours()
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.previousmodel(semaphore: renderer.inFlightSemaphore)
            } else if x > 80 && abs(y) < 50 { // unambiguous right
                // disable false colour mode as going to next simulation
                renderer.disableFalseColours()
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.nextmodel(semaphore: renderer.inFlightSemaphore)
            } else if y < -80 && abs(x) < 50 { // unambigous top
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.collide(semaphore: renderer.inFlightSemaphore)
            } else if y > 80 && abs(x) < 50 { // unambigous bottom
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.leaveAlone(semaphore: renderer.inFlightSemaphore)
            } else if abs(x) < 50 && abs(y) < 50 { // unambigous middle}
                renderer.toggleFalseColours(_split: UInt(_simulation.split))
            } else if x < -80 && y > 80 { // unambiguous bottom left corner
                renderer.decreaseStarSize()
            } else if x > 80 && y > 80 { // unambiguous bottom right corner
                renderer.increaseStarSize()
            } else if x < -80 && y < -80 { // unambiguous top left corner
                renderer.decreaseCameraExposure()
            } else if x > 80 && y < -80 { // unambiguous top right corner
                renderer.increaseCameraExposure()
            }
        }
    }

    
    @objc
    func handlePinch(gestureRecognize: UIPinchGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        _simulation.squeeze(_pinch: Float(gestureRecognize.scale))
        
        if gestureRecognize.state == .began {
 
        }
        
        if gestureRecognize.state == .ended {
            _simulation.squeeze(_pinch:1)
        }
    }
    
    @objc
    func handlePan(gestureRecognize: UIPanGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        let x : Float = Float(200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width) // coordinates -100...100
        let y : Float = Float(200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height)  // coordinates -100...100
        
        if horizontalPan {
            /*_simulation.speed = min(max(Float(-200.0),_simulation.speed + 0.01*Float(gestureRecognize.translation(in: gestureRecognize.view!.superview!).x)), Float(200.0)) // keep between -200 and 200% */
            _simulation.speed = 1.5 * x // keep between -150% and + 150%
        }

        if verticalPan {
            _simulation.gravity = 2 * 0.5*(y+100) // keep between 0 and 200%
        }
        
        
        if gestureRecognize.state == .began {

            if (abs(x) < 25) { // only start if we purposely start from the middle
                verticalPan = true
            } else {
                verticalPan = false
            }

            if (abs(y) < 25) { // only start if we purposely start from the middle
                horizontalPan = true
            } else {
                horizontalPan = false
            }
        }
        
        if gestureRecognize.state == .ended {
            horizontalPan = false
            verticalPan = false
        }
    }

   
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        
        // update position 20cms in front of the camera using the camera's current position, "finger"
        if let currentFrame = session.currentFrame {
            _simulation.camera = currentFrame.camera.transform
        }
               
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
        _simulation.halt = true
        print("AR Error")
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        _simulation.halt = true
        print("AR Session interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        _simulation.halt = false
        print("AR Session resumed")
    }
}

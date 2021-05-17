# Starfield simulation

Galaxy simulator in your pocket for IOS with AR (tested on ipad 5th generation and iphone 8 so anything beyond that should work). Over the 2020 holiday season I decided it was time to do combine my love for programming & physics and see if I could make something cool.

### Instructions
- Should build with XCode 12
- Uses the AR functionality (although you can blank the screen, it still requires the camera to orient itself). Can use gestures too to navigate.
- The UI (if you can call it that) will fade out, if you tap on the screen it will become visible again, play around with it (several simulations, false colours and what not).
- If you long press the screen and then write - you can write things (your name) in "stars".
- Have fun with it.

### Acknowledgements
- Although for MACOS / SWIFT this example is what got me going https://developer.apple.com/documentation/metal/gpu_selection_in_macos/selecting_device_objects_for_compute_processing
- Apple for providing an awesome ecosystem of programming tools, the example above and amazing horsepower in their handheld devices.

## DISCLAIMERS
### The programming
- My objective was to learn some Metal programming and some SWIFT programming. As new to both and time was limited this isn't quality code and would need a rewrite from the ground up
- 3D code / navigation. I always struggle(d) more than the average person navigating, unfortunately that struggle translated into the virtual world as well so once I finally got something to work I just left it. Mathematically this might be wrong.
- The UI. This is an art in itself. I started when things were still written in machine language. Walked away from this with even more admiration of the folkes that design UIs and definetely something I would want to learn about. This works - but it ain't nice.

### The physics
- I am just hoping none of my professors see this. The more stars - the cooler it looks, but in terms of compute power that quickly gets out of hand. Acceptable shortcuts in terms of physics require code that is way more complex and likely not have sufficient "return on investment" for the amount of stars we are talking about (1 to 2 hundred thousand).
- So I broke every rule. It uses calculations - but just use subsets of stars (assuming more or less "random" distribution), to keep the framerate up, just calculate parts and then once fully done, interpolate between results.

### Battery life of your device
- The compute power of your IOS device is amazing and is orders of magnitudes larger what we used to work on with hundreds of users back in the nineties at our universities. This does allow it to do incredible things, but this particular workload just tries to use the maximum all the time which will quickly drain your battery so make sure there is a charger nearby.

[![](https://i9.ytimg.com/vi/nIjxCQpo5ok/mq3.jpg?sqp=CIjpiYUG&rs=AOn4CLCVRrKZWTkIbjeKND9hiPAvQQVwhw)](https://www.youtube.com/watch?v=nIjxCQpo5ok)

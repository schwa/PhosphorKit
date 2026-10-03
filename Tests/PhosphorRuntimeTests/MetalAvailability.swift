import Metal

let metalDeviceAvailable = MTLCreateSystemDefaultDevice() != nil

// GitHub's macOS runners have a Metal device that doesn't support Metal 4.
let metal4Available = MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) ?? false

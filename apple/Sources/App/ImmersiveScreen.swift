#if os(visionOS) && SKYRIM_NATIVE_RUNTIME
import ARKit
import CompositorServices
import Foundation
import Metal
import QuartzCore
import simd
import SwiftUI

/// The flat game image on a world-locked screen in a Full Space. Mono: both eyes see the same picture.
enum ImmersiveScreen {
    static let spaceID = "skyrim.immersive.screen"
}

struct ImmersiveScreenConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
    }
}

private struct QuadUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var halfSize: SIMD2<Float>
    var decode: UInt32
    var hasDepth: UInt32
    /// Grid columns and rows (vertices per row, rows).
    var grid: SIMD2<UInt32>
    /// Where the game camera sits behind the screen, in screen units (meters), so the screen spans its view.
    var eyeBack: Float
    /// Game near plane in game units, and game units per meter.
    var nearUnits: Float
    var unitsPerMeter: Float
    /// How far behind the screen the farthest scenery appears, as a multiple of eyeBack (0.25: 0.75 m); 0 = flat.
    var depthScale: Float
    /// Distance (meters) mapped onto the screen plane; nearer comes out in front, up to `nearestOut`.
    var screenMeters: Float
    /// 1: draw the image pushed to the farthest depth, behind the mesh, to fill where torn triangles were dropped.
    var backplate: Float
    /// A triangle whose corners' depths differ by more than this (meters) is dropped rather than stretched.
    var tear: Float
}

/// Runs on its own thread for as long as the layer lives: presents at the display's rate, showing the newest finished
/// game frame and repeating the last one when the game hasn't produced another.
final class ImmersiveCompositor: @unchecked Sendable {
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float4x4 viewProjection; float4x4 model; float2 halfSize; uint decode; uint hasDepth;
        uint2 grid; float eyeBack; float nearUnits; float unitsPerMeter; float depthScale; float screenMeters; float backplate;
        float tear;
    };
    struct Out { float4 position [[position]]; float2 uv; };
    // A grid over the game image. With depth, each vertex moves along the ray from the game's camera (eyeBack in
    // front of the screen's centre, on the viewer's side) through its point on the screen, by how far that pixel is
    // in the game: the screen
    // becomes a window into the scene and each eye sees it from its own place.
    // How far along its ray (as a multiple of the ray to the screen) the game pixel at uv is pushed.
    float ray_scale(float2 uv, constant Uniforms &u, texture2d<float> depth) {
        constexpr sampler nearest(address::clamp_to_edge, filter::nearest);
        // The nearest depth around the point (half a grid cell each way), so a thin foreground edge keeps its depth
        // instead of a vertex landing beside it in the background.
        float2 cell = 0.5 / float2(u.grid - 1);
        float d = depth.sample(nearest, uv, level(0)).r;
        d = min(d, depth.sample(nearest, uv + float2(-cell.x, 0), level(0)).r);
        d = min(d, depth.sample(nearest, uv + float2(cell.x, 0), level(0)).r);
        d = min(d, depth.sample(nearest, uv + float2(0, -cell.y), level(0)).r);
        d = min(d, depth.sample(nearest, uv + float2(0, cell.y), level(0)).r);
        // D3D depth with a far plane much farther than the near one: view distance ~ near / (1 - d).
        float meters = (u.nearUnits / max(1.0 - d, 1e-6)) / u.unitsPerMeter;
        // 0 at the screen distance, approaching 1 for scenery at infinity; nearer than the screen is negative.
        float behind = 1.0 - u.screenMeters / max(meters, 0.05);
        return 1.0 + u.depthScale * clamp(behind, -0.15, 1.0);
    }
    // Fades the push to nothing over the outer 4% so the picture's outline stays a clean rectangle. Applied after the
    // tear test, so the fade's own slope doesn't count as a depth edge.
    float edge_fade(float2 uv) {
        float2 edge = min(uv, 1.0 - uv);
        return smoothstep(0.0, 0.04, min(edge.x, edge.y));
    }
    // Two triangles per grid cell, unindexed, so each vertex knows its whole triangle. With depth, each vertex moves
    // along the ray from the viewer's starting eye through its point on the screen, by how far that pixel is in the
    // game. A triangle spanning a depth jump (an object's edge against what is behind it) is dropped instead of
    // stretched into streaks; the backplate pass, the same image pushed to the farthest depth, shows through the gap.
    vertex Out screen_vertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]],
                             texture2d<float> depth [[texture(1)]]) {
        const uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
        uint cellIndex = id / 6, corner = id % 6, first = corner < 3 ? 0 : 3;
        uint2 cell = uint2(cellIndex % (u.grid.x - 1), cellIndex / (u.grid.x - 1));
        float2 step = 1.0 / float2(u.grid - 1);
        float2 uv = float2(cell + corners[corner]) * step;
        float3 onScreen = float3((uv.x * 2 - 1) * u.halfSize.x, (1 - uv.y * 2) * u.halfSize.y, 0);
        float3 eye = float3(0, 0, u.eyeBack);
        float3 p = onScreen;
        Out out;
        out.uv = uv;
        if (u.backplate != 0) {
            p = eye + (onScreen - eye) * (1.0 + u.depthScale * edge_fade(uv));
        } else if (u.hasDepth) {
            float t0 = ray_scale(float2(cell + corners[first]) * step, u, depth);
            float t1 = ray_scale(float2(cell + corners[first + 1]) * step, u, depth);
            float t2 = ray_scale(float2(cell + corners[first + 2]) * step, u, depth);
            if ((max(t0, max(t1, t2)) - min(t0, min(t1, t2))) * u.eyeBack > u.tear) {
                out.position = float4(0, 0, 0, 1);  // same point for all three corners: no area, nothing drawn
                return out;
            }
            float t = corner == first ? t0 : (corner == first + 1 ? t1 : t2);
            p = eye + (onScreen - eye) * (1.0 + (t - 1.0) * edge_fade(uv));
        }
        out.position = u.viewProjection * u.model * float4(p, 1);
        return out;
    }
    fragment float4 screen_fragment(Out in [[stage_in]], texture2d<float> image [[texture(0)]],
                                    constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler linear_clamp(address::clamp_to_edge, filter::linear);
        float3 c = image.sample(linear_clamp, in.uv).rgb;
        if (u.decode) c = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
        return float4(c, 1);
    }
    """

    /// Distance to the screen and its width, in meters.
    private static let distance: Float = 3.0
    private static let width: Float = 2.8

    private let layer: LayerRenderer
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var pipeline: (any MTLRenderPipelineState)?
    private var depth: (any MTLDepthStencilState)?
    private let session = ARKitSession()
    private let tracking = WorldTrackingProvider()
    private var screen: simd_float4x4?
    private var lastCommands: (any MTLCommandBuffer)?
    private var checkedDevice = false
    private var presented = 0, newFrames = 0, loggedAt = CACurrentMediaTime()
    /// Grid size: one vertex every 4 game pixels.
    private static let gridColumns: UInt32 = 321, gridRows: UInt32 = 181
    private var depthSettings: (scale: Float, screen: Float, near: Float, units: Float, tear: Float, on: Bool)?
    private var loggedDepth = false

    init(layer: LayerRenderer) {
        self.layer = layer
        device = layer.device
        queue = layer.device.makeCommandQueue()!
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Skyrim immersive compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func log(_ text: String) { fputs("immersive: \(text)\n", stderr) }

    private func makePipeline() throws {
        let library = try device.makeLibrary(source: Self.shaders, options: nil)
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "screen_vertex")
        description.fragmentFunction = library.makeFunction(name: "screen_fragment")
        description.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        description.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: description)
        let stencil = MTLDepthStencilDescriptor()
        stencil.depthCompareFunction = .greater
        stencil.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: stencil)
    }

    /// Depth tuning from the launch environment (LB_ prefix, Documents/SkyrimNative/launch-env.json), read once the
    /// game is running: LB_IMMERSIVE_DEPTH=0 shows the flat screen; LB_IMMERSIVE_DEPTH_SCALE, _SCREEN_M, _NEAR,
    /// _UNITS_PER_M override the defaults.
    private func readDepthSettings() -> (scale: Float, screen: Float, near: Float, units: Float, tear: Float, on: Bool) {
        if let depthSettings { return depthSettings }
        func number(_ name: String, _ fallback: Float) -> Float {
            guard let raw = getenv(name), let value = Float(String(cString: raw)) else { return fallback }
            return value
        }
        let on = getenv("LB_IMMERSIVE_DEPTH").map { String(cString: $0) != "0" } ?? true
        let settings = (scale: number("LB_IMMERSIVE_DEPTH_SCALE", 0.25), screen: number("LB_IMMERSIVE_DEPTH_SCREEN_M", 3.0),
                        near: number("LB_IMMERSIVE_DEPTH_NEAR", 15.0), units: number("LB_IMMERSIVE_DEPTH_UNITS_PER_M", 70.0),
                        tear: number("LB_IMMERSIVE_DEPTH_TEAR_M", 0.05), on: on)
        depthSettings = settings
        log("depth \(on ? "on" : "off"): scale \(settings.scale), screen \(settings.screen) m, near \(settings.near) units, \(settings.units) units/m, tear \(settings.tear) m")
        return settings
    }

    private func run() {
        do {
            try makePipeline()
        } catch {
            log("no pipeline: \(error)")
            return
        }
        skyrim_immersive_start()
        Task { [session, tracking] in
            do { try await session.run([tracking]) } catch { fputs("immersive: no world tracking: \(error)\n", stderr) }
        }
        log("layer \(layer.configuration.colorFormat.rawValue), started")
        while true {
            switch layer.state {
            case .invalidated:
                finish()
                return
            case .paused:
                layer.waitUntilRunning()
            case .running:
                autoreleasepool { draw() }
            @unknown default:
                finish()
                return
            }
        }
    }

    private func finish() {
        lastCommands?.waitUntilCompleted()
        skyrim_immersive_stop()
        session.stop()
        log("layer ended")
    }

    /// The screen, placed once: straight ahead of where the wearer is looking, level, at eye height.
    private func place(head: simd_float4x4) -> simd_float4x4 {
        if let screen { return screen }
        var forward = -SIMD3<Float>(head.columns.2.x, 0, head.columns.2.z)
        forward = length(forward) > 0.001 ? normalize(forward) : SIMD3<Float>(0, 0, -1)
        let back = -forward, up = SIMD3<Float>(0, 1, 0), right = normalize(cross(up, back))
        let center = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z) + forward * Self.distance
        let placed = simd_float4x4(SIMD4<Float>(right, 0), SIMD4<Float>(up, 0), SIMD4<Float>(back, 0), SIMD4<Float>(center, 1))
        screen = placed
        log("screen placed \(Self.distance) m ahead")
        return placed
    }

    private func draw() {
        guard let frame = layer.queryNextFrame() else {
            usleep(1000)
            return
        }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        var game = skyrim_immersive_frame()
        let hasImage = skyrim_immersive_acquire(&game) == 1
        // An integer so the completion handler can carry it across threads.
        let retiredState = game.retired != 0 ? UInt(bitPattern: game.retired_state) : 0
        let retiredSlot = game.retired_slot
        let giveBack: @Sendable () -> Void = {
            if retiredState != 0 { skyrim_immersive_release(UnsafeMutableRawPointer(bitPattern: retiredState), retiredSlot) }
        }

        guard let commands = queue.makeCommandBuffer() else {
            giveBack()
            return
        }
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else {
            // The system cancelled this frame; it must not be touched again.
            giveBack()
            return
        }
        var texture: (any MTLTexture)?
        if hasImage, let pointer = game.texture {
            texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any MTLTexture
        }
        var depthTexture: (any MTLTexture)?
        if hasImage, let pointer = game.depth_texture {
            depthTexture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any MTLTexture
        }
        if depthTexture != nil, !loggedDepth {
            loggedDepth = true
            log("game depth \(depthTexture!.width)x\(depthTexture!.height) arriving")
        }
        if let texture, !checkedDevice {
            checkedDevice = true
            log("game texture \(texture.width)x\(texture.height), same Metal device as the layer: \(texture.device === device)")
        }

        for drawable in drawables {
            let shownAt = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime)
            let seconds = Double(shownAt.components.seconds) + Double(shownAt.components.attoseconds) * 1e-18
            let anchor = tracking.queryDeviceAnchor(atTimestamp: seconds)
            drawable.deviceAnchor = anchor
            let head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let model = anchor != nil ? place(head: head) : screen
            for (index, view) in drawable.views.enumerated() {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[view.textureMap.textureIndex]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = drawable.depthTextures[view.textureMap.textureIndex]
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
                encoder.setViewport(view.textureMap.viewport)
                if let texture, let model, let pipeline, let depth {
                    let viewMatrix = (head * view.transform).inverse
                    let aspect = game.height > 0 ? Float(game.width) / Float(game.height) : 16.0 / 9.0
                    let settings = depthTexture != nil ? readDepthSettings() : (scale: 0, screen: 3, near: 15, units: 70, tear: 0.05, on: false)
                    let useDepth = settings.on && depthTexture != nil
                    // Rays start at the viewer's starting head position, not at where the game's 75-degree camera would
                    // sit: a point moved along a ray from the viewer's own eye looks unchanged from there, so the
                    // picture stays undistorted and depth only shows as parallax between the eyes and with head
                    // movement. From a ray origin closer than the viewer (1.8 m) it bent the screen into a box.
                    let eyeBack = Self.distance
                    var uniforms = QuadUniforms(viewProjection: drawable.computeProjection(convention: .rightUpBack, viewIndex: index) * viewMatrix,
                                                model: model,
                                                halfSize: SIMD2(Self.width / 2, Self.width / 2 / aspect),
                                                decode: game.needs_srgb_decode != 0 ? 1 : 0,
                                                hasDepth: useDepth ? 1 : 0,
                                                grid: SIMD2(Self.gridColumns, Self.gridRows),
                                                eyeBack: eyeBack, nearUnits: settings.near, unitsPerMeter: settings.units,
                                                depthScale: settings.scale, screenMeters: settings.screen, backplate: 0,
                                                tear: settings.tear)
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setDepthStencilState(depth)
                    encoder.setCullMode(.none)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setVertexTexture(useDepth ? depthTexture : texture, index: 1)
                    let vertexCount = Int((Self.gridColumns - 1) * (Self.gridRows - 1) * 6)
                    if useDepth {
                        var back = uniforms
                        back.backplate = 1
                        encoder.setVertexBytes(&back, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                    }
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                }
                encoder.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commands)
        }
        commands.addCompletedHandler { _ in giveBack() }
        commands.commit()
        lastCommands = commands
        frame.endSubmission()

        presented += 1
        if game.is_new != 0 { newFrames += 1 }
        let now = CACurrentMediaTime()
        if now - loggedAt >= 5 {
            log(String(format: "%.0f Hz presented, %.0f fps from the game", Double(presented) / (now - loggedAt), Double(newFrames) / (now - loggedAt)))
            presented = 0
            newFrames = 0
            loggedAt = now
        }
    }
}
#endif

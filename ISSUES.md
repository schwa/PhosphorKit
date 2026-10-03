# ISSUES.md

---

## 1: Billboard uniforms buffer missing from per-frame residency set

+++
status: closed
priority: high
kind: bug
labels: metal4, effort:xs
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:17:04Z
closed: 2026-10-03T15:17:04Z
+++

In PhosphorRenderer.render, billboard.residentAllocations() is called before billboard.encode(). beginFrame() has already cleared uniformsBuffers and encode() creates this frame's buffer afterward, so the buffer the draw reads is never in the residency set. Works today likely only because shared buffers happen to be resident.

- `2026-10-03T15:17:04Z`: Billboard uniforms buffer now allocated in beginFrame(), before residency is built.

---

## 2: Per-frame GPU resources released while frames are still in flight

+++
status: open
priority: high
kind: bug
labels: metal4, effort:m
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:16:04Z
+++

MTL4 command buffers do not retain resources. With up to 3 frames in flight, these are dropped before the GPU is done: BillboardPipeline.uniformsBuffers (cleared in beginFrame), pass uniforms buffers (rebuilt in writePassUniforms), userUniformsBuffer (replaced in writeUserUniforms every frame), and textures freed by ensureTextures on resize. residencyRing keeps residency sets alive but not their allocations.

---

## 3: Audio buffers overwritten by CPU while in-flight frames read them

+++
status: open
priority: medium
kind: bug
labels: metal4, effort:s
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:16:04Z
+++

waveformBuffer and spectrumBuffer are single shared buffers. writeAudioBuffers() rewrites them every frame while up to 2 earlier frames may still be reading them on the GPU, so a frame can see torn or later audio data.

---

## 4: No ordering between consecutive frames on the MTL4 queue

+++
status: closed
priority: high
kind: bug
labels: metal4, effort:s
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:17:27Z
closed: 2026-10-03T15:17:27Z
+++

Barriers in PhosphorRenderer only order work inside one frame. Frame N+1's compute passes write ping-pong textures that frame N's compute or billboard may still read. MTL4 does not serialize command buffers by commit order, so feedback shaders can read stale or partly written data. No queue barrier exists at frame start.

- `2026-10-03T15:17:27Z`: Added queue barrier at start of each frame's compute encoder (after dispatch/vertex/fragment, before dispatch). No regression test: the race is GPU-timing dependent and not reproducible deterministically in a unit test.

---

## 5: Residency set rebuilt every frame instead of a persistent queue set

+++
status: open
priority: low
kind: enhancement
labels: metal4, effort:m
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:16:04Z
+++

applyResidency creates and commits a new MTLResidencySet every frame. This costs CPU each frame and is not the recommended pattern (a long-lived set on the queue, changed only when allocations change). The drawable texture is added per frame; CAMetalLayer.residencySet is not used. residencyRingDepth (4) is not tied to the view's slotCount (3).

---

## 6: zeroTexture creates a queue and blocks on every texture

+++
status: open
priority: low
kind: enhancement
labels: metal4, effort:s
created: 2026-10-02T21:23:47Z
updated: 2026-10-03T15:16:04Z
+++

PhosphorRuntime.zeroTexture makes a new MTL4CommandQueue, allocator, and residency set for each texture and waits synchronously for the GPU. Clearing many ping-pong textures does this once per texture. The residency set stays attached to the throwaway queue.

---

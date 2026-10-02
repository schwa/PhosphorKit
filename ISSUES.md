# ISSUES.md

---

## 1: Billboard uniforms buffer missing from per-frame residency set

+++
status: new
priority: high
kind: bug
labels: metal4
created: 2026-10-02T21:23:47Z
+++

In PhosphorRenderer.render, billboard.residentAllocations() is called before billboard.encode(). beginFrame() has already cleared uniformsBuffers and encode() creates this frame's buffer afterward, so the buffer the draw reads is never in the residency set. Works today likely only because shared buffers happen to be resident.

---

## 2: Per-frame GPU resources released while frames are still in flight

+++
status: new
priority: high
kind: bug
labels: metal4
created: 2026-10-02T21:23:47Z
+++

MTL4 command buffers do not retain resources. With up to 3 frames in flight, these are dropped before the GPU is done: BillboardPipeline.uniformsBuffers (cleared in beginFrame), pass uniforms buffers (rebuilt in writePassUniforms), userUniformsBuffer (replaced in writeUserUniforms every frame), and textures freed by ensureTextures on resize. residencyRing keeps residency sets alive but not their allocations.

---

## 3: Audio buffers overwritten by CPU while in-flight frames read them

+++
status: new
priority: medium
kind: bug
labels: metal4
created: 2026-10-02T21:23:47Z
+++

waveformBuffer and spectrumBuffer are single shared buffers. writeAudioBuffers() rewrites them every frame while up to 2 earlier frames may still be reading them on the GPU, so a frame can see torn or later audio data.

---

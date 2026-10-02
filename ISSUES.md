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

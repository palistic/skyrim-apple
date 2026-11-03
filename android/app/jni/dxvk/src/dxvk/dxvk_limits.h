#pragma once

#include "dxvk_include.h"

namespace dxvk {
  
  enum DxvkLimits : size_t {
    MaxNumRenderTargets         =     8,
    MaxNumVertexAttributes      =    32,
    MaxNumVertexBindings        =    32,
    MaxNumXfbBuffers            =     4,
    MaxNumXfbStreams            =     4,
    MaxNumViewports             =    16,
    MaxNumResourceSlots         =  1216,
    MaxNumActiveBindings        =   384,
    MaxNumQueuedCommandBuffers  =    18,
    MaxNumQueryCountPerPool     =   128,
#ifdef __APPLE__
    // + D3D9SpecConstantId::SamplerDepthFilter (in-shader depth compare).
    MaxNumSpecConstants         =    13,
#else
    MaxNumSpecConstants         =    12,
#endif
    MaxUniformBufferSize        = 65536,
    MaxVertexBindingStride      =  2048,
    MaxPushConstantSize         =   128,
  };
  
}
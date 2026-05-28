/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "MetalPresent.h"
#include <vector>
#include <cstdint>
#include <cstring>

// Written to be MRC-safe (no ARC assumptions): long-lived objects come from
// +new/Create (owned, +1) and are intentionally kept for process lifetime;
// per-frame objects are autoreleased.

static id<MTLDevice>        g_device  = nil;
static id<MTLCommandQueue>  g_queue   = nil;
static CAMetalLayer*        g_layer   = nil;
static id<MTLTexture>       g_staging = nil;
static int                  g_w = 0;
static int                  g_h = 0;
static std::vector<uint8_t> g_flipBuf;

bool MacMetalPresent_Init(void* caMetalLayer)
{
	if (g_device != nil)
		return true;
	if (caMetalLayer == nullptr)
		return false;

	g_layer  = (CAMetalLayer*)caMetalLayer;
	g_device = MTLCreateSystemDefaultDevice();
	if (g_device == nil)
		return false;

	g_queue = [g_device newCommandQueue];
	if (g_queue == nil)
		return false;

	g_layer.device          = g_device;
	g_layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
	g_layer.framebufferOnly  = NO; // allow the drawable to be a blit destination
	return true;
}

void MacMetalPresent_PresentBGRA(int w, int h, const void* pixels, bool flipY)
{
	if (g_device == nil || g_queue == nil || g_layer == nil)
		return;
	if (w <= 0 || h <= 0 || pixels == nullptr)
		return;

	const uint8_t* src = (const uint8_t*)pixels;
	const size_t rowBytes = (size_t)w * 4;

	// OpenGL readback is bottom-up; Metal/CoreAnimation is top-down.
	if (flipY) {
		g_flipBuf.resize(rowBytes * (size_t)h);
		for (int y = 0; y < h; ++y)
			std::memcpy(&g_flipBuf[(size_t)y * rowBytes], src + (size_t)(h - 1 - y) * rowBytes, rowBytes);
		src = g_flipBuf.data();
	}

	if (g_staging == nil || g_w != w || g_h != h) {
		MTLTextureDescriptor* d =
			[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
															   width:(NSUInteger)w
															  height:(NSUInteger)h
														   mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead;
		g_staging = [g_device newTextureWithDescriptor:d];
		g_w = w;
		g_h = h;
		g_layer.drawableSize = CGSizeMake((CGFloat)w, (CGFloat)h);
	}

	[g_staging replaceRegion:MTLRegionMake2D(0, 0, w, h)
				 mipmapLevel:0
				   withBytes:src
				 bytesPerRow:rowBytes];

	id<CAMetalDrawable> drawable = [g_layer nextDrawable];
	if (drawable == nil) {
		fprintf(stderr, "[MetalPresent] nextDrawable returned nil — frame not presented\n");
		return;
	}

	id<MTLCommandBuffer> cb = [g_queue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	[blit copyFromTexture:g_staging
			  sourceSlice:0
			  sourceLevel:0
			 sourceOrigin:MTLOriginMake(0, 0, 0)
			   sourceSize:MTLSizeMake(w, h, 1)
				toTexture:drawable.texture
		 destinationSlice:0
		 destinationLevel:0
		destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding];
	[cb presentDrawable:drawable];
	[cb commit];
}

#include "System/Platform/CpuTopology.h"
#include <sys/sysctl.h>
#include <thread>

namespace cpu_topology {

ThreadPinPolicy GetThreadPinPolicy() {
	// macOS does not support thread pinning
	return THREAD_PIN_POLICY_NONE;
}

ProcessorMasks GetProcessorMasks() {
	ProcessorMasks masks;

	unsigned int numCores = std::thread::hardware_concurrency();
	if (numCores == 0) numCores = 4;

	// Set all cores as performance cores (no E/P distinction exposed via public API)
	masks.performanceCoreMask = (numCores >= 32) ? 0xFFFFFFFF : ((1u << numCores) - 1);
	masks.efficiencyCoreMask = masks.performanceCoreMask;
	masks.hyperThreadLowMask = masks.performanceCoreMask;
	masks.hyperThreadHighMask = 0;

	return masks;
}

ProcessorCaches GetProcessorCache() {
	ProcessorCaches caches;

	ProcessorGroupCaches group;
	unsigned int numCores = std::thread::hardware_concurrency();
	if (numCores == 0) numCores = 4;
	group.groupMask = (numCores >= 32) ? 0xFFFFFFFF : ((1u << numCores) - 1);

	// Try to get cache sizes via sysctl
	size_t size = sizeof(uint64_t);
	uint64_t cacheSize = 0;

	if (sysctlbyname("hw.l1dcachesize", &cacheSize, &size, nullptr, 0) == 0)
		group.cacheSizes[0] = static_cast<uint32_t>(cacheSize);

	if (sysctlbyname("hw.l2cachesize", &cacheSize, &size, nullptr, 0) == 0)
		group.cacheSizes[1] = static_cast<uint32_t>(cacheSize);

	if (sysctlbyname("hw.l3cachesize", &cacheSize, &size, nullptr, 0) == 0)
		group.cacheSizes[2] = static_cast<uint32_t>(cacheSize);

	caches.groupCaches.push_back(group);
	return caches;
}

} // namespace cpu_topology

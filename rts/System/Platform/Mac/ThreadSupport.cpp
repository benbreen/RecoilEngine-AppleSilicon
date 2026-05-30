#include "System/Platform/Threading.h"
#include <memory>

namespace Threading {

void SetupCurrentThreadControls(std::shared_ptr<ThreadControls>& threadCtls)
{
    threadCtls.reset(new Threading::ThreadControls());
    threadCtls->handle = pthread_self();
}

void ThreadStart(
    std::function<void()> taskFunc,
    std::shared_ptr<ThreadControls>* threadCtls,
    ThreadControls* tempCtls)
{
    if (threadCtls != nullptr) {
        SetupCurrentThreadControls(*threadCtls);
    }

    // notify the caller that this thread is running
    {
        std::lock_guard<spring::mutex> lock(tempCtls->mutSuspend);
        tempCtls->condInitialized.notify_one();
    }

    taskFunc();
}

SuspendResult ThreadControls::Suspend()
{
    return Threading::THREADERR_NOT_RUNNING;
}

SuspendResult ThreadControls::Resume()
{
    return Threading::THREADERR_NONE;
}

} // namespace Threading

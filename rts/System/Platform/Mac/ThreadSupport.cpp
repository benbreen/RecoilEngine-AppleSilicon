/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "System/Platform/Threading.h"
#include <memory>
#include <pthread/qos.h>

namespace Threading {

void SetupCurrentThreadControls(std::shared_ptr<ThreadControls>& threadCtls)
{
    threadCtls.reset(new Threading::ThreadControls());
    threadCtls->handle = pthread_self();

    // macOS has no pthread_setaffinity_np equivalent, so we cannot pin sim
    // worker threads to performance cores the way the Linux path does. Hint
    // the scheduler instead: USER_INTERACTIVE is the highest QOS tier and
    // strongly prefers the performance (P) cluster on Apple Silicon. We
    // apply it only to threads that pass through ThreadStart with a
    // ThreadControls handle (the sim workers), not every thread in the
    // process, so background I/O / helper threads remain free to land on
    // the efficiency cluster.
    const qos_class_t prev = qos_class_self();
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    // observability (OF-class rule: no silent QoS state) — taskinfo needs
    // root, so the process logs its own promotions
    fprintf(stderr, "[mac-threads] QoS 0x%x -> USER_INTERACTIVE (thread %p)\n",
            (unsigned)prev, (void*)pthread_self());
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
